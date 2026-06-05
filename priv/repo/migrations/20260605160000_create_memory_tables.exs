defmodule Tracy.Repo.Migrations.CreateMemoryTables do
  use Ecto.Migration

  @moduledoc """
  Three-layer memory per TRACY_CSUITE.md / TRACY_V1_SCOPE.md:

    * episodes   — raw timestamped interactions (append-only)
    * facts      — extracted semantic knowledge (editable, with valid_from/valid_to provenance)
    * procedures — how-to / system prompts / skills (versioned, slow-moving)

  Embedding columns use pgvector with 1024 dims (Voyage-3 + Nomic-embed-text-v1.5
  both default to 1024). Adjust here if we ever standardise on a different dim.
  """

  @embedding_dim 1024

  def change do
    # --- episodes: append-only raw events ---
    create table(:episodes, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :occurred_at, :utc_datetime_usec, null: false
      add :source, :string, null: false, comment: "where it came from: 'session' | 'webhook' | 'worker' | 'system'"
      add :project, :string, comment: "optional project tag for scoped retrieval"
      add :body, :text, null: false, comment: "raw content as observed"
      add :metadata, :map, null: false, default: %{}
      add :embedding, :vector, size: @embedding_dim
      timestamps(type: :utc_datetime_usec)
    end

    create index(:episodes, [:occurred_at])
    create index(:episodes, [:source])
    create index(:episodes, [:project])

    # HNSW index for semantic recall — cosine distance is the standard for normalised embeddings
    execute(
      "CREATE INDEX episodes_embedding_hnsw_idx ON episodes USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS episodes_embedding_hnsw_idx"
    )

    # Full-text on body for hybrid retrieval (RRF fuses pgvector + FTS)
    execute(
      "CREATE INDEX episodes_body_fts_idx ON episodes USING gin (to_tsvector('english', body))",
      "DROP INDEX IF EXISTS episodes_body_fts_idx"
    )

    # --- facts: extracted semantic knowledge w/ temporal provenance ---
    create table(:facts, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :statement, :text, null: false, comment: "natural-language claim, e.g. 'Matt prefers standard Phoenix apps'"
      add :subject, :string, null: false, comment: "what the fact is about: 'matt' | 'tracy' | project name | etc."
      add :tags, {:array, :string}, null: false, default: []
      add :confidence, :float, null: false, default: 1.0
      add :valid_from, :utc_datetime_usec, null: false
      add :valid_to, :utc_datetime_usec, comment: "NULL = currently valid; set when superseded"
      add :superseded_by_id, references(:facts, type: :uuid, on_delete: :nilify_all)
      add :source_episode_id, references(:episodes, type: :uuid, on_delete: :nilify_all)
      add :metadata, :map, null: false, default: %{}
      add :embedding, :vector, size: @embedding_dim
      timestamps(type: :utc_datetime_usec)
    end

    create index(:facts, [:subject])
    create index(:facts, [:valid_from])
    create index(:facts, [:valid_to])
    create index(:facts, [:superseded_by_id])
    create index(:facts, [:source_episode_id])
    create index(:facts, [:tags], using: :gin)

    execute(
      "CREATE INDEX facts_embedding_hnsw_idx ON facts USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS facts_embedding_hnsw_idx"
    )

    execute(
      "CREATE INDEX facts_statement_fts_idx ON facts USING gin (to_tsvector('english', statement))",
      "DROP INDEX IF EXISTS facts_statement_fts_idx"
    )

    # --- procedures: how-to / system prompts / skills, versioned ---
    create table(:procedures, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false, default: fragment("gen_random_uuid()")
      add :name, :string, null: false, comment: "stable slug: 'commit-style' | 'phoenix-conventions' | etc."
      add :version, :integer, null: false, default: 1
      add :body, :text, null: false, comment: "markdown content"
      add :description, :string, comment: "one-liner for system-prompt selection"
      add :is_current, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}
      add :embedding, :vector, size: @embedding_dim
      timestamps(type: :utc_datetime_usec)
    end

    # Only one current version per name — partial unique index.
    create unique_index(:procedures, [:name],
             where: "is_current = TRUE",
             name: :procedures_name_current_idx
           )

    create unique_index(:procedures, [:name, :version], name: :procedures_name_version_idx)
    create index(:procedures, [:is_current])

    execute(
      "CREATE INDEX procedures_embedding_hnsw_idx ON procedures USING hnsw (embedding vector_cosine_ops)",
      "DROP INDEX IF EXISTS procedures_embedding_hnsw_idx"
    )

    execute(
      "CREATE INDEX procedures_body_fts_idx ON procedures USING gin (to_tsvector('english', body))",
      "DROP INDEX IF EXISTS procedures_body_fts_idx"
    )
  end
end
