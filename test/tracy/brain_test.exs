defmodule Tracy.BrainTest do
  use Tracy.DataCase

  alias Tracy.{Brain, LLM, Memory}

  defp user_msg(text), do: %LLM.Message{role: :user, content: text, metadata: %{}}

  describe "build_system_prompt/2" do
    test "returns just the persona block when there's no user text" do
      prompt = Brain.build_system_prompt([])
      assert prompt =~ "You are Tracy"
      # No "## Relevant memory" section without a query
      refute prompt =~ "## Relevant memory"
      # Surface context still attached for boardroom default
      assert prompt =~ "Boardroom"
    end

    test "includes surface context for :boardroom" do
      prompt = Brain.build_system_prompt([user_msg("hi")], surface: :boardroom)
      assert prompt =~ "Surface context"
      assert prompt =~ "Read, Grep, Glob, WebSearch, WebFetch"
    end

    test "skips surface context for :worker" do
      prompt = Brain.build_system_prompt([user_msg("hi")], surface: :worker)
      refute prompt =~ "Surface context"
      # Persona itself still present
      assert prompt =~ "You are Tracy"
    end

    test "stamps pinned project into the persona context block" do
      prompt = Brain.build_system_prompt([user_msg("hi")], project: "Tracy")
      assert prompt =~ "Pinned project"
      assert prompt =~ "Tracy"
    end
  end

  describe "memory retrieval" do
    test "pulls facts that semantically match the last user message" do
      # Record a fact, then ask about it.
      {:ok, _} =
        Memory.record_fact(%{
          statement: "Matt prefers Phoenix without umbrella projects.",
          subject: "matt:preferences",
          tags: ["preferences", "phoenix"]
        })

      prompt =
        Brain.build_system_prompt(
          [user_msg("should we use an umbrella project for the next service?")],
          max_facts: 5,
          max_episodes: 0
        )

      assert prompt =~ "Relevant memory"
      assert prompt =~ "umbrella"
    end

    test "renders empty memory block (no header) when nothing matches" do
      prompt =
        Brain.build_system_prompt(
          [user_msg("totally fresh topic with no prior context")],
          max_facts: 5,
          max_episodes: 5
        )

      # No relevant-memory section emitted because no results.
      refute prompt =~ "## Relevant memory"
    end

    test "respects max_memory_chars and discloses truncation" do
      # Seed a fat fact AND a fat episode so retrieval has stuff to trim.
      Enum.each(1..6, fn n ->
        Memory.record_fact(%{
          statement: "Fact #{n}: " <> String.duplicate("padding ", 60),
          subject: "test:bulk"
        })
      end)

      Enum.each(1..6, fn n ->
        Memory.record_episode(%{
          source: "test",
          body: "Episode #{n} text " <> String.duplicate("more padding ", 60),
          metadata: %{"role" => "user"}
        })
      end)

      prompt =
        Brain.build_system_prompt(
          [user_msg("padding")],
          max_facts: 6,
          max_episodes: 6,
          max_memory_chars: 800
        )

      # Truncation disclosure lands when we hit the budget
      assert prompt =~ "exceeded the budget"
      # And the prompt is genuinely smaller — not unboundedly inflated
      # by however many results matched.
      assert byte_size(prompt) < 9_000
    end

    test "gracefully degrades if memory throws" do
      # Even a query that breaks something at the Memory layer shouldn't
      # blow up the LLM call. Brain catches and returns persona-only.
      prompt = Brain.build_system_prompt([user_msg(:not_a_string)], max_facts: 0, max_episodes: 0)

      assert prompt =~ "You are Tracy"
    end
  end

  describe "in-flight workers in the persona context" do
    test "lists running worker labels in the context block" do
      # Hard to start a real worker here without crossing into the
      # DB-sandbox testing rabbit hole; rely on the integration test
      # in Tracy.WorkersTest for the wired-up version. Pure-unit here
      # checks the empty case.
      prompt = Brain.build_system_prompt([user_msg("hi")])

      # No "Workers in flight" line when no children running
      refute prompt =~ "Workers in flight"
    end
  end
end
