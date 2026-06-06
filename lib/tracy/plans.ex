defmodule Tracy.Plans do
  @moduledoc """
  Public API for the Plan + Task surface — what the C-Suite delegates.

  ## Lifecycle

  Boardroom Claude (or Matt directly) creates a Plan in `triage`. Matt
  reviews; transition to `backlog` or `in_progress` flips it from "proposed"
  to "approved" (sets `approved_at`/`approved_by_id`). Tasks underneath the
  plan get assigned to roles; when workers land (Phase 2B), they pick up
  tasks in `backlog`, set them to `in_progress`, work, and either complete
  (`done`) or block (`needs_input` / `blocked`).

  For v0 of the plan surface (this file), workers don't exist yet — Matt
  transitions statuses manually. Workers come next.
  """
  import Ecto.Query

  alias Tracy.Plans.{Plan, Task}
  alias Tracy.Repo

  # ---- Plans ----

  @doc "Create a plan. Defaults to status='triage' if not given."
  @spec create_plan(map()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(attrs) do
    %Plan{}
    |> Plan.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch a plan (raises if not found)."
  def get_plan!(id), do: Repo.get!(Plan, id) |> Repo.preload(:tasks)

  @doc """
  Filesystem workspace path for a plan. A persistent per-plan directory
  where workers (especially designers) can read, write, and organise
  files — the working folder analogue to "this plan's project assets."

  The directory is created if missing. Path is rooted under the
  configured `:tracy, :workspace_root` (defaults to `"workspaces"` at
  the repo root). Override with `config :tracy, workspace_root: "/abs/path"`
  for prod / cross-host deploys.

  Returns an absolute path string.
  """
  @spec workspace_path(Plan.t() | String.t()) :: String.t()
  def workspace_path(%Plan{id: id}), do: workspace_path(id)

  def workspace_path(plan_id) when is_binary(plan_id) do
    root = Application.get_env(:tracy, :workspace_root, "workspaces")
    abs_root = Path.expand(root)
    path = Path.join([abs_root, "plans", plan_id])
    File.mkdir_p!(path)
    path
  end

  def get_plan(id) do
    case Repo.get(Plan, id) do
      nil -> nil
      plan -> Repo.preload(plan, :tasks)
    end
  end

  @doc """
  Update a plan (general-purpose changeset application).
  Use `transition_plan/3` for status changes — it sets approved_at correctly.
  """
  def update_plan(%Plan{} = plan, attrs) do
    plan
    |> Plan.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Transition a plan to a new status. Approval timestamps land automatically
  when leaving triage.
  """
  def transition_plan(%Plan{} = plan, new_status, opts \\ []) do
    plan
    |> Plan.transition_changeset(new_status, opts)
    |> Repo.update()
  end

  @doc """
  All plans, grouped by status as a map: `%{ "triage" => [plan, ...], ... }`.
  Ordered within each group by most-recently-updated first.
  Drives the /plans list view.
  """
  @spec list_plans_by_status(keyword()) :: %{String.t() => [Plan.t()]}
  def list_plans_by_status(opts \\ []) do
    project = Keyword.get(opts, :project)
    include_terminal = Keyword.get(opts, :include_terminal, true)

    plans =
      Plan
      |> maybe_filter_project(project)
      |> maybe_filter_terminal(include_terminal)
      |> order_by([p], desc: p.updated_at)
      |> Repo.all()
      |> Repo.preload(tasks: from(t in Task, order_by: t.position))

    grouped = Enum.group_by(plans, & &1.status)

    # Ensure every status key exists in the result (even empty), so the UI
    # can render section headers consistently.
    Enum.into(Plan.statuses(), %{}, fn status ->
      {status, Map.get(grouped, status, [])}
    end)
  end

  @doc "Count of plans in each status (cheap query for header chips)."
  def status_counts(opts \\ []) do
    project = Keyword.get(opts, :project)

    Plan
    |> maybe_filter_project(project)
    |> group_by([p], p.status)
    |> select([p], {p.status, count(p.id)})
    |> Repo.all()
    |> Enum.into(%{})
  end

  # ---- Tasks ----

  @doc "Fetch a task (with its plan preloaded), or nil."
  def get_task(id) do
    case Repo.get(Task, id) do
      nil -> nil
      task -> Repo.preload(task, :plan)
    end
  end

  @doc "Fetch a task with its plan preloaded; raises if not found."
  def get_task!(id), do: Repo.get!(Task, id) |> Repo.preload(:plan)

  @doc "Create a task under a plan."
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  # ---- Task chain helpers ----

  @doc """
  Is the task's dep graph satisfied? True if every `blocked_by` task is
  currently `status="done"`. Empty `blocked_by` (no deps) → trivially true.
  """
  @spec task_ready?(Task.t()) :: boolean()
  def task_ready?(%Task{blocked_by: []}), do: true

  def task_ready?(%Task{blocked_by: ids}) when is_list(ids) do
    case Repo.all(from t in Task, where: t.id in ^ids, select: t.status) do
      statuses when length(statuses) == length(ids) ->
        Enum.all?(statuses, &(&1 == "done"))

      _ ->
        # Missing blockers shouldn't happen, but treat as "blocked" rather
        # than crash. Surfaces as a stuck chain that we can debug.
        false
    end
  end

  def task_ready?(_), do: false

  @doc """
  Tasks that listed `task_id` as a blocker AND are now fully ready (all
  their other blockers are also `done`). Used by the worker completion
  hook to fan out auto-dispatches.

  Returns tasks in `backlog`/`triage` only — already-running, paused,
  failed, or terminal tasks are skipped.
  """
  @spec tasks_ready_after(String.t()) :: [Task.t()]
  def tasks_ready_after(task_id) when is_binary(task_id) do
    downstream =
      from(t in Task,
        where: fragment("? = ANY(?)", type(^task_id, :binary_id), t.blocked_by),
        where: t.status in ["backlog", "triage"]
      )
      |> Repo.all()

    Enum.filter(downstream, &task_ready?/1)
  end

  @doc "Fetch many tasks by id, preserving order. Used by chain UIs."
  def list_tasks(ids) when is_list(ids) do
    from(t in Task, where: t.id in ^ids) |> Repo.all()
  end

  @doc "Transition a task's status."
  def transition_task(%Task{} = task, new_status) do
    task
    |> Task.transition_changeset(new_status)
    |> Repo.update()
  end

  @doc "Record a worker report onto a task and mark it done."
  def complete_task(%Task{} = task, report, opts \\ []) do
    cost_micros = Keyword.get(opts, :cost_micros, 0)
    agent_run_id = Keyword.get(opts, :agent_run_id)

    attrs = %{
      report: report,
      cost_micros: cost_micros,
      agent_run_id: agent_run_id
    }

    task
    |> Task.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} -> transition_task(updated, "done")
      err -> err
    end
  end

  @doc """
  Mark a task as blocked with a failure reason recorded in metadata.
  Used by `Tracy.Workers.Server` when an adapter raises or returns
  `{:error, _}`.
  """
  def update_plan_task_with_failure(%Task{} = task, reason) do
    metadata =
      Map.merge(task.metadata || %{}, %{
        "last_failure" => %{
          "reason" => inspect(reason, limit: 500),
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })

    task
    |> Task.changeset(%{metadata: metadata})
    |> Repo.update()
    |> case do
      {:ok, updated} -> transition_task(updated, "blocked")
      err -> err
    end
  end

  # ---- helpers ----

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project), do: where(query, [p], p.project == ^project)

  defp maybe_filter_terminal(query, true), do: query

  defp maybe_filter_terminal(query, false) do
    where(query, [p], p.status not in ["done", "canceled"])
  end
end
