defmodule Tracy.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  @moduledoc """
  Asset table — deliverables attached to a Plan (and optionally a Task).

  Workers produce assets (designer mockups, draft docs, code snippets, links
  out), Matt uploads assets (briefs, reference images), and the Plan detail
  view lists them all in a "Google Drive of folders" style.

  v1 stores binary content directly in Postgres `bytea`. This is fine at
  Matt's single-user scale; S3 / object-store offload is a Phase 3 swap
  through a `Tracy.Assets.Storage` behaviour. Keeping the column NULLABLE
  so a future schema can store data elsewhere (e.g., S3 key in metadata)
  without a destructive migration.
  """

  def change do
    create table(:assets, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :plan_id,
          references(:plans, type: :binary_id, on_delete: :delete_all),
          null: false
      add :task_id, references(:tasks, type: :binary_id, on_delete: :nilify_all),
        comment: "the specific task that produced this asset, if any"

      add :filename, :string, null: false
      add :content_type, :string, null: false, default: "application/octet-stream"
      add :size_bytes, :bigint, null: false, default: 0
      add :kind, :string, null: false, default: "file",
        comment: "file | image | link | note — drives UI rendering"

      add :data, :binary, comment: "binary content; nullable for link/note kinds"
      add :body, :text, comment: "for kind in (link, note); markdown/url"

      add :source, :string, null: false, default: "upload",
        comment: "upload | worker | boardroom"
      add :uploaded_by_id, references(:users, on_delete: :nilify_all)

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:assets, [:plan_id])
    create index(:assets, [:task_id])
    create index(:assets, [:kind])
    create index(:assets, [:inserted_at])
  end
end
