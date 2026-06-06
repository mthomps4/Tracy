defmodule Tracy.Repo.Migrations.AddTaskChainColumns do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      # Task dependency graph: each entry is another task's UUID. The task
      # is "ready" once all blockers have status="done". UUIDs (not refs)
      # because we want flexibility across plans + cheap array ops.
      add :blocked_by, {:array, :binary_id}, default: [], null: false

      # When the blocker(s) complete, should Tracy auto-dispatch this task,
      # or wait for an explicit user click? Default false preserves the
      # current manual-dispatch behavior.
      add :auto_dispatch, :boolean, default: false, null: false
    end

    # GIN index so "find tasks blocked by X" stays cheap at scale.
    create index(:tasks, [:blocked_by], using: "gin")
  end
end
