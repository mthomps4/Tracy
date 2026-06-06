defmodule Tracy.Repo.Migrations.RetireAutoDispatchForApprovedStatus do
  use Ecto.Migration

  @moduledoc """
  The `auto_dispatch :: bool` toggle introduced in the previous migration
  is replaced by the `approved` status. CEO-stamped tasks auto-dispatch
  when their deps clear; backlog tasks stay manual. One signal instead
  of two; "approved-ness" is also more legible in the list view.

  Spawn inheritance lives in app code (Workers.Server.insert_spawned_tasks)
  — no schema change for that.
  """

  def change do
    alter table(:tasks) do
      remove :auto_dispatch, :boolean, default: false, null: false
    end
  end
end
