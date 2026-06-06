defmodule Tracy.Brain do
  @moduledoc """
  The thinking layer — wraps Persona + Memory retrieval + runtime
  context into a single "build the system prompt for this call" entry
  point.

  Before every Claude call from the Boardroom, the adapter calls
  `Tracy.Brain.build_system_prompt/1` with the current message list.
  Brain pulls the last user message, searches memory for relevant
  facts and recent episodes, and returns a fully-baked system prompt:

      [persona]
        +
      [runtime context — pinned project, SDK pool zone, workers in flight]
        +
      [relevant memory — top N facts + top N episodes by hybrid retrieval]
        +
      [surface context — "you're in the chat, here's your tool surface"]

  ## Why a separate module

  Persona is the *who*. Brain is the *what's in context right now*. They
  evolve at different rates: persona is stable across years; context
  retrieval gets tuned per conversation pattern. Keeping them apart
  means tuning retrieval doesn't churn the identity tests.

  ## Knobs

      Tracy.Brain.build_system_prompt(messages,
        max_facts: 5,
        max_episodes: 5,
        memory_query: nil,  # defaults to last user message
        project: nil,        # pinned project filter
        surface: :boardroom  # :boardroom | :worker
      )

  Retrieval gracefully degrades — if Memory.search returns an empty
  list or raises, Brain returns just the persona + runtime context.
  Tracy still works without memory; she's just less informed.
  """

  alias Tracy.{Memory, Persona}

  @doc """
  Build a complete system prompt for one LLM call.

  Pulls the last user message, retrieves relevant facts + episodes, and
  layers them onto the Persona base. Returns a string ready to drop
  into the SDK's `append_system_prompt` field.
  """
  @spec build_system_prompt([Tracy.LLM.Message.t()], keyword()) :: String.t()
  def build_system_prompt(messages, opts \\ []) do
    project = Keyword.get(opts, :project)
    cost_state = Keyword.get(opts, :cost_state) || safe_cost_state()
    surface = Keyword.get(opts, :surface, :boardroom)
    max_facts = Keyword.get(opts, :max_facts, 5)
    max_episodes = Keyword.get(opts, :max_episodes, 5)
    query = Keyword.get(opts, :memory_query) || last_user_text(messages)

    persona =
      Persona.system_prompt(
        project: project,
        cost_state: cost_state,
        in_flight_workers: in_flight_workers()
      )

    memory_block = build_memory_block(query, max_facts, max_episodes)
    surface_block = build_surface_block(surface)

    [persona, memory_block, surface_block]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # ---- memory retrieval ----

  defp build_memory_block(nil, _, _), do: ""
  defp build_memory_block("", _, _), do: ""

  defp build_memory_block(query, max_facts, max_episodes) when is_binary(query) do
    try do
      # Memory.search returns %{episodes: [{ep, score}], facts: [{f, score}], …}
      results = Memory.search(query, limit: max(max_facts, max_episodes))

      facts =
        results
        |> Map.get(:facts, [])
        |> Enum.take(max_facts)
        |> Enum.map(&unwrap/1)

      episodes =
        results
        |> Map.get(:episodes, [])
        |> Enum.take(max_episodes)
        |> Enum.map(&unwrap/1)

      case {facts, episodes} do
        {[], []} ->
          ""

        _ ->
          render_memory_block(facts, episodes)
      end
    rescue
      e ->
        require Logger
        Logger.warning("Tracy.Brain: memory retrieval failed — #{Exception.message(e)}")
        ""
    end
  end

  defp build_memory_block(_, _, _), do: ""

  defp unwrap({record, _score}), do: record
  defp unwrap(record), do: record

  defp render_memory_block(facts, episodes) do
    fact_lines =
      case facts do
        [] -> []
        _ -> ["### Facts I know that may be relevant", ""] ++ Enum.map(facts, &fact_line/1) ++ [""]
      end

    episode_lines =
      case episodes do
        [] -> []
        _ -> ["### Past conversation that may be relevant", ""] ++ Enum.map(episodes, &episode_line/1) ++ [""]
      end

    """
    ---

    ## Relevant memory

    Use these when they're relevant — don't reach for "training data" when
    you have a real observation in front of you. Cite the source episode
    or fact when you act on it ("based on what we said on Jun 5: …").

    #{Enum.join(fact_lines ++ episode_lines, "\n")}
    """
    |> String.trim_trailing()
  end

  defp fact_line(%{snippet: text}) when is_binary(text), do: "- #{text}"
  defp fact_line(%{statement: stmt}) when is_binary(stmt), do: "- #{stmt}"
  defp fact_line(other), do: "- " <> inspect(other, limit: 200)

  defp episode_line(%{snippet: text}) when is_binary(text), do: "- " <> String.slice(text, 0, 200)
  defp episode_line(%{body: text}) when is_binary(text), do: "- " <> String.slice(text, 0, 200)
  defp episode_line(other), do: "- " <> inspect(other, limit: 200)

  # ---- surface ----

  defp build_surface_block(:boardroom) do
    """
    ---

    ## Surface context

    You're in the Boardroom — a Phoenix LiveView chat docked everywhere
    via the persistent ChatDock. Not a terminal.

    Read-only tool surface here: Read, Grep, Glob, WebSearch, WebFetch.
    Bash, Edit, and Write are NOT in this surface — for mutations either
    propose them and Matt will run them, or spawn a specialist worker
    via `Tracy.Workers.dispatch` which has the full tool surface and
    the per-plan workspace.

    Keep replies appropriate for a chat surface: complete thoughts, not
    raw tool dumps. Summarise rather than narrate. End with a
    recommendation or next step.
    """
    |> String.trim_trailing()
  end

  defp build_surface_block(:worker), do: ""
  defp build_surface_block(_), do: ""

  # ---- runtime helpers ----

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Tracy.LLM.Message{role: :user, content: c} -> c
      _ -> nil
    end)
  end

  defp safe_cost_state do
    Tracy.Billing.sdk_pool_status()
  rescue
    _ -> nil
  end

  # In-flight worker labels for the persona context block. Cheap query —
  # at most a handful of children running at once on a single-user system.
  defp in_flight_workers do
    Tracy.Workers.Supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {_, pid, _, _} when is_pid(pid) ->
        try do
          state = :sys.get_state(pid)

          if state.task do
            ["#{state.task.role}:#{String.slice(state.task.title, 0, 32)}"]
          else
            []
          end
        catch
          _, _ -> []
        end

      _ ->
        []
    end)
  rescue
    _ -> []
  end
end
