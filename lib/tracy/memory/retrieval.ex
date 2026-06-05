defmodule Tracy.Memory.Retrieval do
  @moduledoc """
  Hybrid retrieval over Tracy's memory tables.

  Combines:

    * **pgvector cosine similarity** on the `embedding` column
    * **Postgres full-text search** on the body/statement
    * **Reciprocal Rank Fusion** (RRF) to merge the two ranked lists

  RRF formula: `score(d) = sum over rankers r of 1 / (k + rank_r(d))`.
  We use `k = 60` (the original paper's default). Documents that appear in
  both rankers naturally score higher; those in only one still contribute.

  This module is functional — it takes a Repo as its first arg so it stays
  test-friendly with `Ecto.Adapters.SQL.Sandbox`.
  """
  import Ecto.Query

  alias Tracy.Memory.{Episode, Fact, Procedure}

  @rrf_k 60

  @type opts :: [
          limit: pos_integer(),
          vector: [float()] | nil,
          query_text: String.t() | nil,
          project: String.t() | nil
        ]

  @doc """
  Hybrid search over episodes. Returns a list of `{Episode, score}` tuples
  sorted by RRF score descending.

  Either `:vector` or `:query_text` must be given (both is best).
  """
  @spec search_episodes(module(), opts) :: [{Episode.t(), float()}]
  def search_episodes(repo, opts), do: hybrid(repo, Episode, :body, opts)

  @doc "Hybrid search over facts (only currently-valid by default)."
  @spec search_facts(module(), opts) :: [{Fact.t(), float()}]
  def search_facts(repo, opts) do
    scope = from(f in Fact, where: is_nil(f.valid_to))
    hybrid(repo, scope, :statement, opts)
  end

  @doc "Hybrid search over procedures (current versions only)."
  @spec search_procedures(module(), opts) :: [{Procedure.t(), float()}]
  def search_procedures(repo, opts) do
    scope = from(p in Procedure, where: p.is_current == true)
    hybrid(repo, scope, :body, opts)
  end

  # ---- internals --------------------------------------------------------

  defp hybrid(repo, schema_or_query, text_field, opts) do
    limit = Keyword.get(opts, :limit, 10)
    vector = Keyword.get(opts, :vector)
    query_text = Keyword.get(opts, :query_text)
    project = Keyword.get(opts, :project)

    vector_hits = vector_rank(repo, schema_or_query, vector, limit, project)
    fts_hits = fts_rank(repo, schema_or_query, text_field, query_text, limit, project)

    fuse([vector_hits, fts_hits])
    |> Enum.take(limit)
  end

  defp vector_rank(_repo, _q, nil, _limit, _project), do: []

  defp vector_rank(repo, queryable, vector, limit, project) do
    base = scoped(queryable, project)

    base
    |> where([x], not is_nil(x.embedding))
    |> order_by([x], asc: fragment("? <=> ?", x.embedding, ^vector))
    |> limit(^limit)
    |> repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> {row.id, row, rank} end)
  end

  defp fts_rank(_repo, _q, _field, nil, _limit, _project), do: []
  defp fts_rank(_repo, _q, _field, "", _limit, _project), do: []

  defp fts_rank(repo, queryable, field, query_text, limit, project) do
    base = scoped(queryable, project)

    # `plainto_tsquery` parses user text safely (no need for tsquery operators).
    base
    |> where([x], fragment("to_tsvector('english', ?) @@ plainto_tsquery('english', ?)", field(x, ^field), ^query_text))
    |> order_by([x], desc: fragment("ts_rank(to_tsvector('english', ?), plainto_tsquery('english', ?))", field(x, ^field), ^query_text))
    |> limit(^limit)
    |> repo.all()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, rank} -> {row.id, row, rank} end)
  end

  defp scoped(queryable, nil), do: queryable

  defp scoped(queryable, project) when is_binary(project) do
    case queryable do
      %Ecto.Query{} = q -> from(x in q, where: x.project == ^project or is_nil(x.project))
      schema -> from(x in schema, where: x.project == ^project or is_nil(x.project))
    end
  end

  defp fuse(ranked_lists) do
    ranked_lists
    |> List.flatten()
    |> Enum.reduce(%{}, fn {id, row, rank}, acc ->
      contrib = 1.0 / (@rrf_k + rank)

      Map.update(acc, id, {row, contrib}, fn {existing_row, score} ->
        {existing_row, score + contrib}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(fn {_row, score} -> score end, :desc)
  end
end
