defmodule Tracy.Memory.Extractor.Heuristic do
  @moduledoc """
  Pattern-match extractor — catches durable claims in the user's own words.

  This is the deterministic, no-LLM-call provider. It looks for explicit
  cues a human would also recognize as "Matt is telling me something to
  remember":

    * Preference verbs — "I prefer / always / never / use / hate ..."
    * Memory hooks — "remember that ...", "for the record ...", "FYI ..."
    * Project declarations — "we use ...", "this project uses ...",
                             "<X> uses ..."

  Each match becomes a candidate Fact. The matcher only catches the
  high-confidence cases; subtler implicit knowledge (decisions
  expressed obliquely, drift over time, contradiction patterns) needs
  the LLM-driven provider that lands later.

  ## Tuning

  Patterns are intentionally conservative. False positives are worse
  than false negatives — a wrong Fact pollutes Tracy's prompt forever
  (until manually superseded). A missed Fact just means Matt has to
  type `/remember` for that one.

  When in doubt: don't extract. Let the LLM provider catch the harder
  cases when it's wired.
  """

  alias Tracy.LLM

  # Each pattern: regex with one capture group (the durable claim) + a
  # function that builds the candidate fact map from the captured text.
  # Order matters slightly — more specific patterns first so they win.
  @patterns [
    # "Remember that X" / "remember X is Y"
    {
      ~r/\bremember(?:\s+that)?\s+(.{6,200}?)(?:[.!?]|$)/i,
      &__MODULE__.build/2,
      ["explicit"]
    },
    # "For the record X" / "FYI X"
    {
      ~r/\b(?:for the record|fyi),?\s+(.{6,200}?)(?:[.!?]|$)/i,
      &__MODULE__.build/2,
      ["explicit"]
    },
    # "I prefer X" / "I always X" / "I never X" / "I use X" / "I love X" / "I hate X"
    {
      ~r/\bI\s+(?:prefer|always|never|use|love|hate|dislike|like|don't|don't like)\s+(.{4,200}?)(?:[.!?]|$)/i,
      &__MODULE__.build_preference/2,
      ["preference"]
    },
    # "we use X" / "we don't X" / "we always X"
    {
      ~r/\bwe\s+(?:use|don't|always|never|prefer|standardize on)\s+(.{4,200}?)(?:[.!?]|$)/i,
      &__MODULE__.build_team/2,
      ["team"]
    },
    # "<Project>/this project/our X uses Y"  — declarations of stack/tool
    {
      ~r/\b(?:this project|our codebase|our stack)\s+(?:uses|runs on|is built with|is)\s+(.{4,200}?)(?:[.!?]|$)/i,
      &__MODULE__.build_project_stack/2,
      ["stack"]
    }
  ]

  @doc """
  Run the patterns over the most recent user message. Returns a list of
  candidate-fact maps in the shape `Tracy.Memory.record_fact/1` expects.
  """
  @spec extract([LLM.Message.t()], keyword()) :: [map()]
  def extract(messages, _opts \\ []) when is_list(messages) do
    case last_user_text(messages) do
      nil ->
        []

      text ->
        @patterns
        |> Enum.flat_map(fn {regex, builder, tags} ->
          Regex.scan(regex, text)
          |> Enum.flat_map(fn
            [_full, capture] ->
              statement = clean_capture(capture)

              if String.length(statement) >= 4 do
                candidate = builder.(statement, text) |> Map.put_new(:tags, tags)
                [candidate]
              else
                []
              end

            _ ->
              []
          end)
        end)
    end
  end

  # ---- builders ----

  @doc false
  def build(statement, _full_text) do
    %{
      statement: String.trim(statement),
      subject: "user:matt",
      confidence: 0.85
    }
  end

  @doc false
  def build_preference(statement, _full_text) do
    %{
      statement: "Matt prefers: " <> String.trim(statement),
      subject: "user:matt:preferences",
      confidence: 0.85
    }
  end

  @doc false
  def build_team(statement, _full_text) do
    %{
      statement: "Team: " <> String.trim(statement),
      subject: "team",
      confidence: 0.7
    }
  end

  @doc false
  def build_project_stack(statement, _full_text) do
    %{
      statement: "Stack: " <> String.trim(statement),
      subject: "stack",
      confidence: 0.9
    }
  end

  # ---- helpers ----

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %LLM.Message{role: :user, content: c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  # Strip trailing punctuation + whitespace + dangling conjunctions.
  defp clean_capture(text) do
    text
    |> String.trim()
    |> String.replace(~r/[,.;:!?]+$/, "")
    |> String.replace(~r/\s+(and|but|or)$/i, "")
    |> String.trim()
  end
end
