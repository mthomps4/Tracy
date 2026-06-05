defmodule Tracy.Workers do
  @moduledoc """
  Public API for worker dispatch.

  Each call to `dispatch/2` spawns a `Tracy.Workers.Server` GenServer under
  `Tracy.Workers.Supervisor`. The server picks the configured adapter for
  the task's role, runs it, and reports back via PubSub + the database
  (`Plans.complete_task/3` or failure → `blocked`).

  ## Config

      config :tracy, Tracy.Workers,
        default_adapter: Tracy.Workers.Stub,
        per_role: %{
          # "engineer" => Tracy.Workers.Claude
        }

  Per-role overrides let us mix Stub + real Claude across roles.

  ## Subscribe to a worker

      Tracy.Workers.subscribe(task_id)
      receive do
        {:worker_event, ^task_id, {:worker_started, task}} -> ...
        {:worker_event, ^task_id, {:worker_completed, task, report}} -> ...
        {:worker_event, ^task_id, {:worker_failed, task, reason}} -> ...
      end
  """
  alias Phoenix.PubSub
  alias Tracy.Plans
  alias Tracy.Plans.Task
  alias Tracy.Workers.{Server, Supervisor}

  @type opts :: [adapter: module(), adapter_opts: keyword()]

  @doc """
  Dispatch a worker against a task.

  Returns `{:ok, pid}` if the worker started, or `{:error, reason}`.
  The pid is for observability — the worker drives itself to completion
  and broadcasts events along the way.
  """
  @spec dispatch(String.t() | Task.t(), opts()) ::
          {:ok, pid()} | {:error, term()}
  def dispatch(task_or_id, opts \\ [])

  def dispatch(%Task{id: id, role: role}, opts) do
    do_dispatch(id, role, opts)
  end

  def dispatch(task_id, opts) when is_binary(task_id) do
    case Tracy.Repo.get(Task, task_id) do
      nil -> {:error, :not_found}
      task -> do_dispatch(task.id, task.role, opts)
    end
  end

  defp do_dispatch(task_id, role, opts) do
    adapter = Keyword.get(opts, :adapter) || adapter_for_role(role)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    case Supervisor.start_child(
           task_id: task_id,
           adapter: adapter,
           adapter_opts: adapter_opts
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  @doc "PubSub topic for a worker's events."
  def topic(task_id), do: Server.topic(task_id)

  @doc "Subscribe the calling process to a worker's events."
  def subscribe(task_id), do: PubSub.subscribe(Tracy.PubSub, topic(task_id))

  @doc """
  Get the active adapter for a role from config, falling back to the
  default adapter.
  """
  def adapter_for_role(role) when is_binary(role) do
    config = Application.get_env(:tracy, __MODULE__, [])
    per_role = Keyword.get(config, :per_role, %{})
    default = Keyword.get(config, :default_adapter, Tracy.Workers.Stub)
    Map.get(per_role, role, default)
  end

  # Convenience for the UI layer.
  defdelegate complete_task(task, report, opts), to: Plans
end
