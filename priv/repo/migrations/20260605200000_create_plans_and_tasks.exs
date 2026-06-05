defmodule Tracy.Repo.Migrations.CreatePlansAndTasks do
  use Ecto.Migration

  @moduledoc """
  Plan + Task tables — the C-Suite's "what we're delegating" surface.

  Plans live as approved, scoped, time-bounded commitments. Tasks are the
  individual worker-runnable units within a plan. Status taxonomy from
  feedback_mobile_first_list_view.md: triage / backlog / in_progress /
  in_review / needs_input / blocked / done / canceled.

  Costs stored in micros (millionths of USD) for floating-point safety.
  """

  def change do
    create table(:plans, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :title, :string, null: false
      add :brief, :text, comment: "what we're trying to do; expanded narrative"
      add :project, :string, comment: "free-form tag (falcon, tracy, dayjob, etc.)"
      add :status, :string, null: false, default: "triage"

      add :approved_at, :utc_datetime_usec
      add :approved_by_id,
          references(:users, on_delete: :nilify_all),
          comment: "the user who approved (Matt, for now)"
      add :expires_at, :utc_datetime_usec, comment: "optional time-box"

      add :budget_cap_micros, :bigint,
        comment: "max total SDK-pool spend across all tasks under this plan"

      add :scope, :map, null: false, default: %{},
        comment: "JSONB: files_in_scope, worker_dispatches_allowed, etc."

      add :metadata, :map, null: false, default: %{}

      add :source_session_id, :uuid,
        comment: "boardroom session this plan was created from, if any"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plans, [:status])
    create index(:plans, [:project])
    create index(:plans, [:approved_at])
    create index(:plans, [:source_session_id])

    create table(:tasks, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :plan_id,
          references(:plans, type: :binary_id, on_delete: :delete_all),
          null: false
      add :title, :string, null: false
      add :brief, :text, comment: "what the worker should do"
      add :role, :string, null: false, default: "engineer",
        comment: "engineer | researcher | pm | reviewer | note_taker | operator | scout"
      add :status, :string, null: false, default: "backlog"
      add :position, :integer, null: false, default: 0,
        comment: "order within the plan; 0-indexed"

      add :assigned_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :cost_micros, :bigint, null: false, default: 0

      add :report, :map, comment: "JSONB: worker's structured report on completion"
      add :metadata, :map, null: false, default: %{}

      # Foreign key to the AgentRun this task spawned (null until dispatched).
      add :agent_run_id, references(:agent_runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:plan_id])
    create index(:tasks, [:status])
    create index(:tasks, [:role])
    create index(:tasks, [:plan_id, :position])
  end
end
