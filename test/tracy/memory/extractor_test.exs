defmodule Tracy.Memory.ExtractorTest do
  use Tracy.DataCase, async: false

  alias Tracy.LLM.Message
  alias Tracy.Memory
  alias Tracy.Memory.Extractor

  defp user_msg(text), do: %Message{role: :user, content: text, metadata: %{}}

  describe "Heuristic provider patterns" do
    test "captures explicit `remember that …` cues" do
      msgs = [user_msg("Hey — remember that I prefer Phoenix without umbrellas.")]

      {:ok, facts} = Extractor.extract(msgs)

      assert Enum.any?(facts, &(&1.statement =~ "Phoenix without umbrellas"))
    end

    test "captures `I prefer X` preference cues" do
      msgs = [user_msg("I prefer Conventional Commits with imperative subject lines.")]

      {:ok, facts} = Extractor.extract(msgs)

      assert Enum.any?(facts, fn f ->
               f.statement =~ "Matt prefers" and f.statement =~ "Conventional Commits"
             end)

      assert Enum.any?(facts, &(&1.subject == "user:matt:preferences"))
    end

    test "captures team-scoped `we use X` cues" do
      msgs = [user_msg("we use Tailwind 4 and daisyUI 5 for the design system.")]

      {:ok, facts} = Extractor.extract(msgs)

      assert Enum.any?(facts, &(&1.statement =~ "Tailwind 4"))
      assert Enum.any?(facts, &(&1.subject == "team"))
    end

    test "captures `this project uses X` stack cues" do
      msgs = [user_msg("This project uses Phoenix LiveView and Postgres with AGE.")]

      {:ok, facts} = Extractor.extract(msgs)

      assert Enum.any?(facts, &(&1.statement =~ "Phoenix LiveView"))
      assert Enum.any?(facts, &(&1.subject == "stack"))
    end

    test "tags facts as `from_chat` so they're distinguishable from manual entries" do
      msgs = [user_msg("I always commit with the Tracy-Task trailer.")]
      {:ok, facts} = Extractor.extract(msgs)
      assert Enum.all?(facts, fn f -> "from_chat" in f.tags end)
    end

    test "passes the pinned project through into tags" do
      msgs = [user_msg("I prefer mobile-first list views.")]
      {:ok, facts} = Extractor.extract(msgs, project: "Tracy")

      assert Enum.any?(facts, fn f -> "Tracy" in f.tags end)
    end
  end

  describe "deduplication" do
    test "skips facts whose normalized statement already lives in current_facts" do
      msgs = [user_msg("I prefer Phoenix without umbrellas.")]

      # First extraction lands the fact
      {:ok, first} = Extractor.extract(msgs)
      refute first == []

      # Second extraction with the same statement should find it already known
      {:ok, second} = Extractor.extract(msgs)
      assert second == []
    end

    test "dedupes within a single batch when patterns overlap" do
      # The same line matches both the `I prefer` AND a future fallback —
      # the candidate normaliser collapses them.
      msgs = [user_msg("I prefer Phoenix. I prefer Phoenix.")]

      {:ok, facts} = Extractor.extract(msgs)
      # Two matches but same normalized statement => one fact
      assert length(facts) == 1
    end
  end

  describe "messages without durable cues" do
    test "returns empty when nothing matches" do
      msgs = [user_msg("How's it going?")]
      assert {:ok, []} = Extractor.extract(msgs)
    end

    test "ignores assistant turns — only the user's own claims count" do
      msgs = [
        %Message{role: :assistant, content: "I prefer dark themes.", metadata: %{}}
      ]

      assert {:ok, []} = Extractor.extract(msgs)
    end
  end

  describe "max_per_turn" do
    test "caps the number of facts persisted per call" do
      msgs = [user_msg("""
      I prefer A. I prefer B. I prefer C. I prefer D. I prefer E. I prefer F.
      """)]

      {:ok, facts} = Extractor.extract(msgs, max_per_turn: 3)
      assert length(facts) <= 3
    end
  end

  describe "robustness" do
    test "doesn't crash if a provider raises" do
      defmodule BrokenProvider do
        def extract(_messages, _opts), do: raise("boom")
      end

      msgs = [user_msg("I prefer reliable extractors.")]

      # Should still extract via Heuristic (still in default list); Broken
      # provider's crash is rescued and logged.
      {:ok, facts} =
        Extractor.extract(msgs, providers: [BrokenProvider, Tracy.Memory.Extractor.Heuristic])

      assert Enum.any?(facts, &(&1.statement =~ "reliable"))
    end
  end

  describe "from_worker/3 — extracting from worker reports" do
    setup do
      {:ok, plan} = Tracy.Plans.create_plan(%{title: "favicon work"})

      {:ok, task} =
        Tracy.Plans.create_task(%{
          plan_id: plan.id,
          title: "Add the new favicon static paths",
          role: "engineer"
        })

      %{task: task}
    end

    test "pulls durable claims from the report summary", %{task: task} do
      report = %{
        summary: "I prefer Conventional Commits with imperative subject lines.",
        files_changed: [],
        proposed_next_steps: [],
        metadata: %{}
      }

      {:ok, facts} = Extractor.from_worker(task, report)

      assert Enum.any?(facts, &(&1.statement =~ "Conventional Commits"))
      # Tagged from_worker:<role>, not from_chat
      assert Enum.any?(facts, &("from_worker:engineer" in &1.tags))
    end

    test "synthesizes summary + next steps + files into one search corpus", %{task: task} do
      report = %{
        summary: "Done.",
        files_changed: ["lib/tracy_web.ex"],
        proposed_next_steps: ["Remember that we use Tailscale Funnel for webhook ingress."],
        metadata: %{}
      }

      {:ok, facts} = Extractor.from_worker(task, report)

      assert Enum.any?(facts, &(&1.statement =~ "Tailscale Funnel"))
    end

    test "empty / no-cue report extracts nothing without crashing", %{task: task} do
      report = %{
        summary: "Worker finished.",
        files_changed: [],
        proposed_next_steps: [],
        metadata: %{}
      }

      {:ok, facts} = Extractor.from_worker(task, report)
      assert facts == []
    end

    test "honors max_per_turn cap", %{task: task} do
      report = %{
        summary: "I prefer A. I prefer B. I prefer C. I prefer D. I prefer E.",
        files_changed: [],
        proposed_next_steps: [],
        metadata: %{}
      }

      {:ok, facts} = Extractor.from_worker(task, report, max_per_turn: 2)
      assert length(facts) <= 2
    end
  end

  defp _silence_unused_alias, do: {Memory, Extractor}
end
