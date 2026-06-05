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
        new_tasks = insert_spawned_tasks(completed.plan_id, spawned, completed.position)

        broadcast(state.task_id, {:worker_completed, completed, report})

        if new_tasks != [] do
          broadcast(state.task_id, {:worker_spawned_tasks, new_tasks})
        end

        broadcast_plans()

        %{state | task: completed, status: :completed, report: report}

      {:error, _cs} ->
        fail(state, :complete_failed)
    end
  end

  defp insert_spawned_tasks(_plan_id, [], _start_position), do: []

  defp insert_spawned_tasks(plan_id, spawned, start_position) do
    spawned
    |> Enum.with_index(start_position + 1)
    |> Enum.map(fn {task_attrs, position} ->
      attrs =
        task_attrs
        |> normalize_task_attrs()
        |> Map.put(:plan_id, plan_id)
        |> Map.put(:position, position)
        |> Map.put(:status, "backlog")

      case Plans.create_task(attrs) do
        {:ok, t} ->
          t

        {:error, cs} ->
          require Logger
          Logger.warning(
            "Tracy.Workers.Server: failed to insert spawned task — #{inspect(cs.errors)} attrs=#{inspect(Map.take(attrs, [:title, :role]))}"
          )
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

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
    {:ok, blocked} = Plans.update_plan_task_with_failure(state.task, reason)

    broadcast(state.task_id, {:worker_failed, blocked, reason})
    broadcast_plans()

    %{state | task: blocked, status: :failed, error: reason}
  end

  defp broadcast(task_id, event) do
    PubSub.broadcast(Tracy.PubSub, topic(task_id), {:worker_event, task_id, event})
  end

  defp broadcast_plans, do: PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other
end
