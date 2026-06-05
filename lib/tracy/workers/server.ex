defmodule Tracy.Workers.Server do
  @moduledoc """
  GenServer that runs one worker against one Task.

  Lifecycle:

      :starting → marks task in_progress (assigned_at stamped) → broadcasts
      :running  → calls adapter.execute/2 (synchronous inside the GenServer)
      :completed → records report via Plans.complete_task/3 (status → done)
      :failed   → marks task blocked with the failure reason in metadata

  Broadcasts state changes on PubSub topic `worker:<task_id>` so the plan
  detail view can update live. Also broadcasts on `plans` so the list view
  reflects status transitions.
  """
  use GenServer, restart: :transient

  alias Phoenix.PubSub
  alias Tracy.Plans

  defstruct [:task_id, :task, :adapter, :adapter_opts, :status, :report, :error]

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
    state = execute_adapter(state)
    {:stop, :normal, state}
  end

  # ---- helpers ----

  defp mark_in_progress(state) do
    task = Tracy.Repo.get!(Tracy.Plans.Task, state.task_id)

    {:ok, started_task} = Plans.transition_task(task, "in_progress")

    broadcast(state.task_id, {:worker_started, started_task})
    broadcast_plans()

    %{state | task: started_task, status: :running}
  end

  defp execute_adapter(state) do
    case state.adapter.execute(state.task, state.adapter_opts) do
      {:ok, report} ->
        complete(state, report)

      {:error, reason} ->
        fail(state, reason)
    end
  rescue
    exception ->
      fail(state, {:exception, exception})
  catch
    kind, value ->
      fail(state, {kind, value})
  end

  defp complete(state, report) do
    cost = Map.get(report, :cost_micros, 0)
    report_for_db = report |> Map.drop([:cost_micros]) |> stringify_keys()

    case Plans.complete_task(state.task, report_for_db, cost_micros: cost) do
      {:ok, completed} ->
        broadcast(state.task_id, {:worker_completed, completed, report})
        broadcast_plans()
        %{state | task: completed, status: :completed, report: report}

      {:error, _cs} ->
        fail(state, :complete_failed)
    end
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
