defmodule Tracy.Repo.Migrations.SwitchEmbeddingDimToNomic do
  use Ecto.Migration

  @moduledoc """
  Switch the `embedding` columns on episodes / facts / procedures from
  1024-dim (Voyage-3 / Arctic-L sized) to 768-dim (Nomic-Embed-v2 size).

  Tracy's v2 memory stack runs the embedder LOCALLY via Bumblebee + Nomic
  — no cloud, no API key, no per-call cost. Nomic-Embed-text-v1.5 / v2
  natively output 768-dim vectors (with Matryoshka truncation available
  for smaller sizes).

  Existing embeddings are dropped (Stub adapter produced deterministic
  non-meaningful vectors anyway) and HNSW indexes recreated against the
  new column type.
  """

  @new_dim 768

  def up do
    # Drop HNSW indexes first — they're typed against the old column dim.
    execute "DROP INDEX IF EXISTS episodes_embedding_hnsw_idx"
    execute "DROP INDEX IF EXISTS facts_embedding_hnsw_idx"
    execute "DROP INDEX IF EXISTS procedures_embedding_hnsw_idx"

    # Clear + resize the columns. ALTER TYPE doesn't work for vector dim
    # changes; drop + add is the supported path.
    alter table(:episodes) do
      remove :embedding
    end

    alter table(:facts) do
      remove :embedding
    end

    alter table(:procedures) do
      remove :embedding
    end

    alter table(:episodes) do
      add :embedding, :vector, size: @new_dim
    end

    alter table(:facts) do
      add :embedding, :vector, size: @new_dim
    end

    alter table(:procedures) do
      add :embedding, :vector, size: @new_dim
    end

    # Recreate HNSW indexes with the new dim. Cosine ops match L2-normalised
    # embeddings (Nomic's embedding_processor: :l2_norm gives us that).
    execute """
    CREATE INDEX episodes_embedding_hnsw_idx
      ON episodes USING hnsw (embedding vector_cosine_ops)
    """

    execute """
    CREATE INDEX facts_embedding_hnsw_idx
      ON facts USING hnsw (embedding vector_cosine_ops)
    """

    execute """
    CREATE INDEX procedures_embedding_hnsw_idx
      ON procedures USING hnsw (embedding vector_cosine_ops)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS episodes_embedding_hnsw_idx"
    execute "DROP INDEX IF EXISTS facts_embedding_hnsw_idx"
    execute "DROP INDEX IF EXISTS procedures_embedding_hnsw_idx"

    alter table(:episodes), do: remove(:embedding)
    alter table(:facts), do: remove(:embedding)
    alter table(:procedures), do: remove(:embedding)

    alter table(:episodes) do
      add :embedding, :vector, size: 1024
    end

    alter table(:facts) do
      add :embedding, :vector, size: 1024
    end

    alter table(:procedures) do
      add :embedding, :vector, size: 1024
    end

    execute "CREATE INDEX episodes_embedding_hnsw_idx ON episodes USING hnsw (embedding vector_cosine_ops)"
    execute "CREATE INDEX facts_embedding_hnsw_idx ON facts USING hnsw (embedding vector_cosine_ops)"
    execute "CREATE INDEX procedures_embedding_hnsw_idx ON procedures USING hnsw (embedding vector_cosine_ops)"
  end
end
