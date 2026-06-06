defmodule Tracy.Workers.Server do
  @moduledoc """
  GenServer that runs one worker against one Task.

  Lifecycle:

      :starting → marks task in_progress (assigned_at stamped) → broadcasts
      :running  → spawns a Task that calls `adapter.execute/2`; while it
                  runs, the adapter's `:progress_callback` opt streams
                  events back here for transcript buffering + PubSub
      :completed → records report via Plans.complete_task/3 (status → done)
      :failed   → marks task blocked with the failure reason in metadata
      :canceled → external `Workers.cancel/1` — Task.shutdown brutal-kills
                  the in-flight adapter; task transitions to canceled

  Broadcasts on PubSub topic `worker:<task_id>`:

      {:worker_started, task}
      {:worker_progress, %{kind, text, tool_name, tool_input, tool_id, at}}
      {:worker_completed, task, report}
      {:worker_failed, task, reason}
      {:worker_canceled, task}
      {:worker_spawned_tasks, [new_task, ...]}

  Also broadcasts `:plans_changed` on the `plans` topic for the list view.
  """
  use GenServer, restart: :transient

  alias Phoenix.PubSub
  alias Tracy.Plans

  # Bound the in-memory transcript so a chatty worker doesn't grow forever.
  @transcript_cap 500

  defstruct [
    :task_id,
    :task,
    :adapter,
    :adapter_opts,
    :status,
    :report,
    :error,
    :sdk_task,
    transcript: []
  ]

  # ---- client API ----

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:task_id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def topic(task_id), do: "worker:#{task_id}"

  # ---- callbacks ----

  @impl true
  def init(opts) do
    state = %__MODULE__{
      task_id: Keyword.fetch!(opts, :task_id),
      adapter: Keyword.fetch!(opts, :adapter),
      adapter_opts: Keyword.get(opts, :adapter_opts, []),
      status: :starting
    }

    # Kick off after init so we don't block the supervisor's start_child.
    send(self(), :run)
    {:ok, state}
  end

  @impl true
  def handle_info(:run, state) do
    state = mark_in_progress(state)
    {:noreply, spawn_adapter(state)}
  end

  # Progress event streamed from the adapter's callback.
  def handle_info({:transcript, event}, state) do
    event = Map.put_new(event, :at, DateTime.utc_now())
    broadcast(state.task_id, {:worker_progress, event})

    new_transcript =
      [event | state.transcript]
      |> Enum.take(@transcript_cap)

    {:noreply, %{state | transcript: new_transcript}}
  end

  # Task.async result — adapter returned a value.
  def handle_info({ref, result}, %{sdk_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:ok, report} -> complete(state, report)
        {:error, reason} -> fail(state, reason)
        other -> fail(state, {:bad_adapter_return, other})
      end

    {:stop, :normal, %{state | sdk_task: nil}}
  end

  # Task crashed before sending a result.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{sdk_task: %Task{ref: ref}} = state)
      when reason != :normal do
    state = fail(state, {:adapter_crashed, reason})
    {:stop, :normal, %{state | sdk_task: nil}}
  end

  # Stale messages (e.g. from a Task already shut down via cancel).
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, ref, _, _, _}, state) when is_reference(ref), do: {:noreply, state}

  @impl true
  def handle_call(:transcript, _from, state) do
    {:reply, Enum.reverse(state.transcript), state}
  end

  @impl true
  def handle_cast(:cancel, %{sdk_task: %Task{} = sdk_task} = state) do
    # Brutal-kill the adapter Task and any subprocess (Port) it owns.
    Task.shutdown(sdk_task, :brutal_kill)

    state =
      case Tracy.Repo.get(Tracy.Plans.Task, state.task_id) do
        nil ->
          state

        task ->
          {:ok, canceled} = Plans.transition_task(task, "canceled")
          broadcast(state.task_id, {:worker_canceled, canceled})
          broadcast_plans()
          %{state | task: canceled, status: :canceled}
      end

    {:stop, :normal, %{state | sdk_task: nil}}
  end

  def handle_cast(:cancel, state), do: {:stop, :normal, state}

  # ---- helpers ----

  defp mark_in_progress(state) do
    task = Tracy.Repo.get!(Tracy.Plans.Task, state.task_id)

    {:ok, started_task} = Plans.transition_task(task, "in_progress")

    broadcast(state.task_id, {:worker_started, started_task})
    broadcast_plans()

    %{state | task: started_task, status: :running}
  end

  defp spawn_adapter(state) do
    parent = self()

    callback = fn event ->
      send(parent, {:transcript, event})
    end

    adapter = state.adapter
    task = state.task
    opts = Keyword.put(state.adapter_opts, :progress_callback, callback)

    sdk_task =
      Task.async(fn ->
        try do
          adapter.execute(task, opts)
        rescue
          exception -> {:error, {:exception, exception}}
        catch
          kind, value -> {:error, {kind, value}}
        end
      end)

    %{state | sdk_task: sdk_task}
  end

  defp complete(state, report) do
    cost = Map.get(report, :cost_micros, 0)
    spawned = Map.get(report, :spawned_tasks, []) || []
    report_for_db = report |> Map.drop([:cost_micros]) |> stringify_keys()

    case Plans.complete_task(state.task, report_for_db, cost_micros: cost) do
      {:ok, completed} ->
        # Insert any proposed tasks AFTER marking this one done so the UI
        # shows the completion and the new tasks together.
        new_tasks =
          insert_spawned_tasks(completed.plan_id, spawned, completed.position, completed)

        broadcast(state.task_id, {:worker_completed, completed, report})

        # Global chat notification — the ChatDock subscribes to this so
        # Matt sees a system bubble when a backgrounded worker finishes,
        # no matter which page he's on or which task he was watching.
        Phoenix.PubSub.broadcast(
          Tracy.PubSub,
          "chat:notifications",
          {:worker_completed_notice, completed, report}
        )

        # Worker output → fact extraction. Same Extractor module Brain
        # uses for chat turns, just fed the report text instead of a
        # user message. Fire-and-forget Task; a crashing extractor
        # doesn't disrupt the completion broadcast.
        learn_from_worker(completed, report)

        # Worker output → Tracy.Assets auto-register. Files the worker
        # wrote into the per-plan workspace become Assets visible on
        # the plan page. Fire-and-forget for the same reason — Asset
        # import is cosmetic, shouldn't block the worker's completion.
        import_worker_artifacts(completed.plan_id)

        if new_tasks != [] do
          broadcast(state.task_id, {:worker_spawned_tasks, new_tasks})
        end

        # Fan out auto-dispatches to newly-ready downstream tasks. Do this
        # AFTER broadcasting completion so the UI shows the chain progression
        # in the right order.
        fan_out_auto_dispatches(completed.id)

        broadcast_plans()

        %{state | task: completed, status: :completed, report: report}

      {:error, _cs} ->
        fail(state, :complete_failed)
    end
  end

  # Find tasks whose blocked_by just cleared (this task was their last
  # outstanding blocker) AND that carry the CEO stamp (status="approved").
  # Fire each via Workers.dispatch — they spawn their own Server processes
  # under the same supervisor, independent of this one.
  #
  # Wrapped in try/rescue so a DB error here (e.g. sandbox shutdown in
  # tests, or a transient connection issue in prod) doesn't crash the
  # completing worker — its report is already persisted and broadcast.
  defp fan_out_auto_dispatches(completed_task_id) do
    Plans.tasks_ready_after(completed_task_id)
    |> Enum.filter(&(&1.status == "approved"))
    |> Enum.each(fn task ->
      case Tracy.Workers.dispatch(task, initiated_by: :auto) do
        {:ok, _pid} ->
          broadcast(completed_task_id, {:worker_chain_dispatched, task})

        {:error, {:budget_paused, budget_state}} ->
          # Chain stopped at the budget gate. Downstream stays blocked_by
          # this paused task — exactly the failure-breaks-chain semantics.
          broadcast(completed_task_id, {:worker_chain_paused, task, budget_state})

        {:error, reason} ->
          require Logger

          Logger.warning(
            "Tracy.Workers.Server: auto-dispatch failed for chained task #{task.id} — #{inspect(reason)}"
          )
      end
    end)
  rescue
    exception ->
      require Logger

      Logger.warning(
        "Tracy.Workers.Server: fan-out scan crashed for #{completed_task_id} — #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, value ->
      # DB sandbox EXITs in tests, or any other non-Exception flavor of
      # crash, also lands here. The worker's report is already broadcast.
      require Logger

      Logger.warning(
        "Tracy.Workers.Server: fan-out scan exited for #{completed_task_id} — #{inspect({kind, value}, limit: 200)}"
      )

      :ok
  end

  defp insert_spawned_tasks(_plan_id, [], _start_position, _parent_task), do: []

  defp insert_spawned_tasks(plan_id, spawned, start_position, parent_task) do
    inherit_approval? = parent_task && Plans.task_ever_approved?(parent_task)

    # First pass: create all spawned tasks with no blocked_by yet. Carry
    # the original spec alongside the inserted record so we can resolve
    # `depends-on` references in pass two.
    inserted_pairs =
      spawned
      |> Enum.with_index(start_position + 1)
      |> Enum.map(fn {task_attrs, position} ->
        attrs = build_spawn_attrs(task_attrs, plan_id, position, inherit_approval?, parent_task)
        spec = normalize_spec(task_attrs)

        case Plans.create_task(attrs) do
          {:ok, t} ->
            {spec, t}

          {:error, cs} ->
            require Logger
            Logger.warning(
              "Tracy.Workers.Server: failed to insert spawned task — #{inspect(cs.errors)} attrs=#{inspect(Map.take(attrs, [:title, :role]))}"
            )
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Second pass: resolve `depends-on` references into blocked_by.
    # `this` → parent task id; a string → exact title match against the
    # newly-spawned siblings first, then existing plan tasks.
    resolved =
      Enum.map(inserted_pairs, fn {spec, task} ->
        case resolve_depends_on(spec, parent_task, inserted_pairs, plan_id) do
          nil ->
            task

          blocker_id ->
            case task |> Plans.Task.changeset(%{blocked_by: [blocker_id]}) |> Tracy.Repo.update() do
              {:ok, updated} -> updated
              _ -> task
            end
        end
      end)

    resolved
  end

  defp build_spawn_attrs(task_attrs, plan_id, position, inherit_approval?, parent_task) do
    base =
      task_attrs
      |> normalize_task_attrs()
      |> Map.put(:plan_id, plan_id)
      |> Map.put(:position, position)

    if inherit_approval? do
      parent_stamp = get_in(parent_task.metadata || %{}, ["approved_at"])

      base
      |> Map.put(:status, "approved")
      |> Map.put(:metadata, %{"approved_at" => parent_stamp, "inherited_from" => parent_task.id})
    else
      Map.put(base, :status, "backlog")
    end
  end

  # Normalize the raw spec to a map with stringified depends_on (the
  # worker's report may come back JSON-encoded with string keys, so the
  # parser's atom-keyed map needs defensive treatment).
  defp normalize_spec(attrs) do
    %{
      title: attrs[:title] || attrs["title"],
      depends_on: attrs[:depends_on] || attrs["depends_on"]
    }
  end

  defp resolve_depends_on(%{depends_on: nil}, _parent, _inserted, _plan_id), do: nil
  defp resolve_depends_on(%{depends_on: ""}, _parent, _inserted, _plan_id), do: nil

  defp resolve_depends_on(%{depends_on: "this"}, %Tracy.Plans.Task{id: parent_id}, _inserted, _plan_id),
    do: parent_id

  defp resolve_depends_on(%{depends_on: "this"}, _no_parent, _inserted, _plan_id), do: nil

  defp resolve_depends_on(%{depends_on: title}, _parent, inserted_pairs, plan_id) when is_binary(title) do
    needle = title |> String.trim() |> String.downcase()

    # Match a sibling spawned in the same batch first
    sibling_match =
      Enum.find_value(inserted_pairs, fn {_spec, t} ->
        if String.downcase(t.title) == needle, do: t.id
      end)

    cond do
      sibling_match ->
        sibling_match

      true ->
        # Fall back to existing tasks on the same plan
        case Tracy.Repo.get_by(Tracy.Plans.Task, plan_id: plan_id, title: title) do
          %Tracy.Plans.Task{id: id} -> id
          _ -> nil
        end
    end
  end

  defp resolve_depends_on(_, _, _, _), do: nil

  # Defensive: when the worker's report came back through JSON (stored on the
  # task) the keys are strings. Atomise so Plans.create_task gets the shape
  # its changeset expects. Also truncate the title if a worker over-shares.
  defp normalize_task_attrs(attrs) do
    title =
      (attrs[:title] || attrs["title"] || "")
      |> to_string()
      |> String.slice(0, 200)

    %{
      role: attrs[:role] || attrs["role"],
      title: title,
      brief: attrs[:brief] || attrs["brief"] || ""
    }
  end

  defp fail(state, reason) do
    {:ok, failed} = Plans.mark_task_failed(state.task, reason)

    broadcast(state.task_id, {:worker_failed, failed, reason})

    Phoenix.PubSub.broadcast(
      Tracy.PubSub,
      "chat:notifications",
      {:worker_failed_notice, failed, reason}
    )

    broadcast_plans()

    %{state | task: failed, status: :failed, error: reason}
  end

  defp broadcast(task_id, event) do
    PubSub.broadcast(Tracy.PubSub, topic(task_id), {:worker_event, task_id, event})
  end

  defp broadcast_plans, do: PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

  # Fire-and-forget extraction. Reads the report's summary + next steps +
  # full text and runs Tracy.Memory.Extractor.from_worker over it. Each
  # learned fact gets broadcast on chat:notifications so the dock can
  # show "🧠 Noted: ..." just like with chat-extracted facts.
  defp learn_from_worker(task, report) do
    if Application.get_env(:tracy, :extract_facts_inline, true) do
      Task.start(fn ->
        case Tracy.Memory.Extractor.from_worker(task, report) do
          {:ok, []} ->
            :ok

          {:ok, facts} ->
            require Logger
            Logger.info("Tracy.Memory.Extractor: learned #{length(facts)} fact(s) from worker #{task.role}:#{task.id}")

            Enum.each(facts, fn fact ->
              PubSub.broadcast(Tracy.PubSub, "chat:notifications", {:fact_learned, fact})
            end)

          _ ->
            :ok
        end
      end)
    end
  end

  defp import_worker_artifacts(plan_id) do
    Task.start(fn ->
      case Tracy.Assets.import_workspace(plan_id, source: "worker") do
        {:ok, []} ->
          :ok

        {:ok, assets} ->
          require Logger
          Logger.info("Tracy.Assets.import_workspace: registered #{length(assets)} artifact(s) for plan #{plan_id}")

          # Bump the plan's assets:<plan_id> topic so any open PlanLive
          # refreshes immediately.
          PubSub.broadcast(Tracy.PubSub, "assets:#{plan_id}", :assets_changed)

        _ ->
          :ok
      end
    end)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
