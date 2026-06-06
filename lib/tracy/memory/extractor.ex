defmodule Tracy.Memory.Extractor do
  @moduledoc """
  Pulls candidate Facts out of recent conversation.

  ## How Tracy "learns" — the design choice

  Three architectures were on the table for this:

  ### A. Nightly Haiku consolidator (deferred)

  Schedule a daily Oban job that scans the last 24h of Episodes, calls
  Haiku to extract structured candidate facts, deduplicates against
  existing Facts, supersedes contradictions. Best long-term — Haiku
  catches implicit knowledge (decisions, preferences expressed
  obliquely, project context drift).

  Why deferred: needs Oban (or similar) in the dep tree + a scheduler +
  prompt engineering iteration on the extraction LLM call. Lots of
  moving parts before any value lands.

  ### B. Per-turn LLM extractor (also deferred)

  Hook the LLM call right after each turn. Send the user message +
  assistant response to Claude (cheap model) with an "extract durable
  facts" prompt. Persist what comes back.

  Why deferred: doubles the LLM-call rate (one for chat reply, one for
  extraction). Real cost. Real latency. The extraction quality is
  better than heuristic, but the value-per-token isn't proven yet on
  Matt's actual conversation patterns.

  ### C. Heuristic extractor (CHOSEN, this module)

  Pattern-match user messages for explicit cues — "I prefer X", "I
  always X", "remember that X", "we use Y". Each match becomes a
  candidate Fact. Zero new LLM calls. Deterministic. Visible: Matt
  types "I prefer no umbrella projects" and a Fact appears in
  `/memory` within a turn.

  Why CHOSEN: zero infra to add. Foundation for A or B later — those
  can run as additional providers behind the same `Tracy.Memory.Extractor`
  facade. Heuristic catches the high-confidence cases (~30-40% of
  durable knowledge by my estimate); the LLM provider catches the
  remaining nuance when it lands.

  ## Composability

  The module structure is provider-shaped:

      Tracy.Memory.Extractor.extract(messages, opts)
        |> Enum.uniq_by(&dedupe_key/1)
        |> Enum.each(&Memory.record_fact/1)

  Adding a Claude provider later means another module + plug-in to the
  provider list; callers don't change. The behaviour seam is the same
  pattern as `Tracy.LLM` and `Tracy.Memory.Embeddings.Provider`.
  """

  alias Tracy.Memory

  @doc """
  Extract candidate facts from a list of recent messages (newest last).
  Returns the list of facts that were actually persisted.

  Options:
    * `:project` — tag the extracted facts with this project name.
    * `:providers` — list of extractor modules to consult. Default is
      `[Tracy.Memory.Extractor.Heuristic]`. When the Claude-based
      extractor lands, prepend it here.
    * `:max_per_turn` — cap on facts extracted per call (default 5).
  """
  @spec extract([Tracy.LLM.Message.t()], keyword()) :: {:ok, [Tracy.Memory.Fact.t()]}
  def extract(messages, opts \\ []) when is_list(messages) do
    providers = Keyword.get(opts, :providers, [Tracy.Memory.Extractor.Heuristic])
    project = Keyword.get(opts, :project)
    max_per_turn = Keyword.get(opts, :max_per_turn, 5)

    candidates =
      providers
      |> Enum.flat_map(fn provider -> safe_extract(provider, messages, opts) end)
      |> Enum.uniq_by(&dedupe_key/1)
      |> Enum.take(max_per_turn)
      |> Enum.reject(&already_known?/1)

    persisted =
      Enum.flat_map(candidates, fn candidate ->
        attrs = Map.merge(candidate, %{
          tags: build_tags(candidate, project),
          subject: candidate[:subject] || default_subject(project)
        })

        case Memory.record_fact(attrs) do
          {:ok, fact} -> [fact]
          {:error, _cs} -> []
        end
      end)

    {:ok, persisted}
  end

  defp safe_extract(provider, messages, opts) do
    provider.extract(messages, opts)
  rescue
    e ->
      require Logger
      Logger.warning("Tracy.Memory.Extractor: provider #{inspect(provider)} crashed — #{Exception.message(e)}")
      []
  end

  # Two candidates are "the same" when their normalized statement matches.
  # The heuristic produces statements like "I prefer Phoenix" verbatim from
  # the user's phrasing; downcase + strip punctuation gives stable keys.
  defp dedupe_key(%{statement: stmt}), do: normalize(stmt)
  defp dedupe_key(other), do: inspect(other)

  defp normalize(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, "")
    |> String.trim()
  end

  # Skip facts whose normalized form already lives in `current_facts`.
  # Cheap O(N×M) over recent facts; acceptable at single-user volume.
  defp already_known?(%{statement: stmt}) do
    key = normalize(stmt)

    Memory.current_facts(limit: 200)
    |> Enum.any?(fn fact -> normalize(fact.statement) == key end)
  rescue
    _ -> false
  end

  defp already_known?(_), do: false

  defp build_tags(candidate, nil), do: Enum.uniq(default_origin_tag(candidate) ++ (candidate[:tags] || []))
  defp build_tags(candidate, project), do: Enum.uniq([project | default_origin_tag(candidate)] ++ (candidate[:tags] || []))

  # Workers tag their candidates with from_worker:<role>; chat-extracted
  # facts default to from_chat. The opts-passed `:origin_tag` overrides.
  defp default_origin_tag(%{origin: tag}) when is_binary(tag), do: [tag]
  defp default_origin_tag(_), do: ["from_chat"]

  defp default_subject(nil), do: "user:matt"
  defp default_subject(project), do: "project:#{project}"

  # ---- worker report path ----

  @doc """
  Extract durable claims from a completed worker's report. The report's
  summary + next-step bullets + full-text get folded into a synthetic
  user message and run through the standard provider chain.

  Facts are tagged `from_worker:<role>` so they're distinguishable from
  facts Matt typed himself.

  Returns `{:ok, [Fact]}`.
  """
  @spec from_worker(Tracy.Plans.Task.t(), map(), keyword()) ::
          {:ok, [Tracy.Memory.Fact.t()]}
  def from_worker(%Tracy.Plans.Task{} = task, report, opts \\ []) when is_map(report) do
    body = synthesize_report_body(report)

    if String.trim(body) == "" do
      {:ok, []}
    else
      synthetic = [%Tracy.LLM.Message{role: :user, content: body, metadata: %{}}]

      providers = Keyword.get(opts, :providers, [Tracy.Memory.Extractor.Heuristic])
      project = Keyword.get(opts, :project) || task.role
      origin = "from_worker:#{task.role}"
      max_per_turn = Keyword.get(opts, :max_per_turn, 5)

      candidates =
        providers
        |> Enum.flat_map(fn provider -> safe_extract(provider, synthetic, opts) end)
        |> Enum.uniq_by(&dedupe_key/1)
        |> Enum.take(max_per_turn)
        |> Enum.map(&Map.put(&1, :origin, origin))
        |> Enum.reject(&already_known?/1)

      persisted =
        Enum.flat_map(candidates, fn candidate ->
          attrs = Map.merge(candidate, %{
            tags: build_tags(candidate, project),
            subject: candidate[:subject] || "worker:#{task.role}",
            confidence: Map.get(candidate, :confidence, 0.7)
          })

          case Memory.record_fact(attrs) do
            {:ok, fact} -> [fact]
            {:error, _cs} -> []
          end
        end)

      {:ok, persisted}
    end
  end

  defp synthesize_report_body(report) do
    summary = Map.get(report, :summary, "") |> to_string()
    files = Map.get(report, :files_changed, []) |> List.wrap()
    next_steps = Map.get(report, :proposed_next_steps, []) |> List.wrap()
    full = get_in(report, [:metadata, "full_text"]) || ""

    [
      summary,
      if(next_steps != [], do: "Next steps: " <> Enum.join(next_steps, "; "), else: ""),
      if(files != [], do: "Files touched: " <> Enum.join(files, ", "), else: ""),
      full
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end
end
