defmodule Tracy.Memory do
  @moduledoc """
  Public API for Tracy's three-layer memory.

  ## Layers

    * **Episode** — raw timestamped observations. Append-only.
    * **Fact** — extracted semantic claims with temporal provenance
      (`valid_from`/`valid_to`/`superseded_by`).
    * **Procedure** — how-to / system prompts / skills, versioned.

  ## Embedding

  All three schemas have an `embedding` column. The `embed: true` option on
  the `record_*` helpers below auto-generates the vector via the configured
  `Tracy.Memory.Embeddings` provider. For dev/test the Stub provider returns
  deterministic vectors — see `Tracy.Memory.Embeddings.Stub`.

  ## Retrieval

  Hybrid pgvector + FTS via `Tracy.Memory.Retrieval`. See `search/3` below
  for the convenience wrapper.
  """
  import Ecto.Query

  alias Tracy.Memory.{Embeddings, Episode, Fact, Procedure, Retrieval}
  alias Tracy.Repo

  # ---- episodes ---------------------------------------------------------

  @doc """
  Record a new episode.

  Options:

    * `:embed` — when `true`, compute the embedding via `Tracy.Memory.Embeddings`
      and persist it. Defaults to `true`.
  """
  @spec record_episode(map(), keyword()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def record_episode(attrs, opts \\ []) do
    attrs = maybe_embed(attrs, attrs[:body] || attrs["body"], opts)

    %Episode{}
    |> Episode.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetch an episode by id (raises if not found)."
  def get_episode!(id), do: Repo.get!(Episode, id)

  @doc "Most-recent episodes, optionally scoped to a project."
  def recent_episodes(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    project = Keyword.get(opts, :project)

    Episode
    |> maybe_filter_project(project)
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Rehydrate a boardroom session's conversation history from recorded episodes.

  Returns a list of `Tracy.LLM.Message` structs in chronological order, ready
  to seed a fresh `Tracy.Session.Server`. Filters to episodes with
  `source: "session"` and a `role` metadata key (user or assistant).

  Until the Episode schema gains a `session_id` column, this returns the
  N most recent session episodes globally — fine for single-user v1.
  """
  def session_history(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Episode
    |> where([e], e.source == "session")
    |> where([e], fragment("? \\? 'role'", e.metadata))
    |> order_by([e], desc: e.occurred_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&episode_to_message/1)
  end

  defp episode_to_message(%Episode{body: body, metadata: %{"role" => role_str}}) do
    role =
      case role_str do
        "assistant" -> :assistant
        "system" -> :system
        _ -> :user
      end

    %Tracy.LLM.Message{role: role, content: body, metadata: %{}}
  end

  # ---- facts ------------------------------------------------------------

  @doc """
  Record a new semantic fact.

  Options:

    * `:embed` — compute and persist the embedding (default `true`).
  """
  @spec record_fact(map(), keyword()) :: {:ok, Fact.t()} | {:error, Ecto.Changeset.t()}
  def record_fact(attrs, opts \\ []) do
    attrs = maybe_embed(attrs, attrs[:statement] || attrs["statement"], opts)

    %Fact{}
    |> Fact.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Supersede an old fact with a new one. Inserts the new fact and marks the old
  as superseded in a single transaction.

  Returns `{:ok, %{new: new_fact, old: old_fact}}`.
  """
  def supersede_fact(%Fact{} = old, new_attrs, opts \\ []) do
    Repo.transaction(fn ->
      with {:ok, new_fact} <- record_fact(new_attrs, opts),
           {:ok, updated_old} <-
             old |> Fact.supersede_changeset(new_fact) |> Repo.update() do
        %{new: new_fact, old: updated_old}
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc "All currently-valid facts (valid_to IS NULL), optionally by subject."
  def current_facts(opts \\ []) do
    subject = Keyword.get(opts, :subject)

    Fact
    |> where([f], is_nil(f.valid_to))
    |> maybe_filter_subject(subject)
    |> order_by([f], desc: f.valid_from)
    |> Repo.all()
  end

  @doc "Fetch a fact (any temporal state) by id."
  def get_fact!(id), do: Repo.get!(Fact, id)

  # ---- procedures -------------------------------------------------------

  @doc """
  Create or update a procedure by name. If a current version exists with a
  different body, marks it not-current and inserts a new version with the
  body bumped by 1. Always returns the now-current row.
  """
  @spec upsert_procedure(map(), keyword()) ::
          {:ok, Procedure.t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert_procedure(attrs, opts \\ []) do
    name = attrs[:name] || attrs["name"]
    new_body = attrs[:body] || attrs["body"]

    Repo.transaction(fn ->
      case current_procedure(name) do
        nil ->
          insert_procedure(attrs, opts)

        %Procedure{body: ^new_body} = existing ->
          existing

        %Procedure{version: v} = old ->
          old |> Ecto.Changeset.change(is_current: false) |> Repo.update!()

          attrs
          |> Map.put(:version, v + 1)
          |> Map.put(:is_current, true)
          |> insert_procedure(opts)
      end
    end)
  end

  defp insert_procedure(attrs, opts) do
    attrs = maybe_embed(attrs, attrs[:body] || attrs["body"], opts)

    case %Procedure{} |> Procedure.changeset(attrs) |> Repo.insert() do
      {:ok, p} -> p
      {:error, cs} -> Repo.rollback(cs)
    end
  end

  @doc "Fetch the current version of a procedure by name, or nil."
  def current_procedure(nil), do: nil

  def current_procedure(name) when is_binary(name) do
    Repo.one(from(p in Procedure, where: p.name == ^name and p.is_current == true))
  end

  # ---- retrieval --------------------------------------------------------

  @doc """
  Hybrid search across one or more memory layers.

  Options:

    * `:layers`     — list of `:episodes | :facts | :procedures` (default all three)
    * `:query_text` — free-text query (used for FTS)
    * `:vector`     — pre-computed embedding (skips internal embed call)
    * `:limit`      — per-layer cap (default 5)
    * `:project`    — scope to one project (and global-scope rows)

  Returns a map keyed by layer atom, each value a list of `{record, score}`.
  """
  def search(query_text, opts \\ []) when is_binary(query_text) do
    layers = Keyword.get(opts, :layers, [:episodes, :facts, :procedures])
    limit = Keyword.get(opts, :limit, 5)
    project = Keyword.get(opts, :project)

    vector =
      case Keyword.get(opts, :vector) do
        nil ->
          case Embeddings.embed(query_text) do
            {:ok, v} -> v
            _ -> nil
          end

        v ->
          v
      end

    common = [query_text: query_text, vector: vector, limit: limit, project: project]

    Enum.into(layers, %{}, fn
      :episodes -> {:episodes, Retrieval.search_episodes(Repo, common)}
      :facts -> {:facts, Retrieval.search_facts(Repo, common)}
      :procedures -> {:procedures, Retrieval.search_procedures(Repo, common)}
    end)
  end

  # ---- helpers ----------------------------------------------------------

  defp maybe_embed(attrs, _text, opts) do
    cond do
      not Keyword.get(opts, :embed, true) -> attrs
      has_embedding?(attrs) -> attrs
      true ->
        case embeddable_text(attrs) do
          nil ->
            attrs

          text ->
            case Embeddings.embed(text) do
              {:ok, vec} -> Map.put(attrs, :embedding, vec)
              _ -> attrs
            end
        end
    end
  end

  defp embeddable_text(attrs) do
    attrs[:body] || attrs["body"] || attrs[:statement] || attrs["statement"]
  end

  defp has_embedding?(attrs) do
    not is_nil(attrs[:embedding] || attrs["embedding"])
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, project), do: where(query, [e], e.project == ^project)

  defp maybe_filter_subject(query, nil), do: query
  defp maybe_filter_subject(query, subject), do: where(query, [f], f.subject == ^subject)
end
