defmodule Tracy.Workers.Claude do
  @moduledoc """
  Real worker that spawns Claude via `claude_agent_sdk` to do actual work.

  This is the closing-of-the-loop adapter — the moment Tracy stops being a
  chat UI and becomes an actual orchestrator. A task gets dispatched →
  `claude -p` runs under the hood with the task brief as its prompt →
  Claude investigates with tools → the SDK returns a structured response →
  we synthesise it into a `Tracy.Workers.Adapter.report`.

  ## Auth + billing

  Same as `Tracy.LLM.Claude` — picks up OAuth from `~/.claude/.credentials.json`,
  lands all spend on the SDK credit pool. `ANTHROPIC_API_KEY` must not be
  set in env or it'll bypass the Max plan.

  ## Tool surface

  Workers get a **wider tool surface than the boardroom**. They're meant to
  actually do work, including modifying files. By default:

      Read, Grep, Glob, WebSearch, WebFetch, Bash, Edit, Write

  Per-role allowlists can override via `:allowed_tools` adapter opt.

  ## v1 scope

    * Single-pass execution. Run claude -p once; parse the final result.
      Multi-step worker conversations or human-in-the-loop come later.
    * No worktree isolation yet. Workers run against the same project
      directory. Worktree-per-task lands in Phase 3 when we need parallel
      Engineer workers on different branches.
    * Reports are extracted from the assistant message text + the SDK's
      result message (cost, tokens). Structured JSON output schemas are
      a follow-up.

  Behaviour: `Tracy.Workers.Adapter`.
  """
  @behaviour Tracy.Workers.Adapter

  require Logger

  alias ClaudeAgentSDK.Options
  alias Tracy.Plans.Task

  @default_allowed_tools ~w(Read Grep Glob WebSearch WebFetch Bash Edit Write)
  @default_max_turns 30

  @impl true
  def execute(%Task{} = task, opts) do
    prompt = build_prompt(task)
    sdk_opts = build_options(task, opts)

    started_at = DateTime.utc_now()

    try do
      sdk_messages = ClaudeAgentSDK.query(prompt, sdk_opts) |> Enum.to_list()
      completed_at = DateTime.utc_now()

      {:ok, build_report(task, sdk_messages, started_at, completed_at)}
    rescue
      exception ->
        Logger.warning(
          "Tracy.Workers.Claude.execute failed for task #{task.id}: " <>
            Exception.message(exception)
        )

        {:error, {:claude_sdk_error, exception}}
    end
  end

  # ---- prompt construction ----

  defp build_prompt(%Task{} = task) do
    """
    Role: #{task.role}
    Plan task: #{task.title}

    #{if task.brief && task.brief != "", do: "Brief:\n#{task.brief}", else: "(No brief provided — interpret the task title.)"}

    Do the work. Investigate with tools as needed. Modify files where the task
    calls for it. When you're finished, end your message with a short summary
    block in this exact shape:

        ## Summary
        - <one-line outcome>
        - files touched: <comma-separated list, or "none">
        - next steps: <one to three bullets, or "none">

    Keep your output focused — the C-Suite will read the summary; don't dump
    raw tool traces.
    """
    |> String.trim()
  end

  defp build_options(task, opts) do
    allowed = Keyword.get(opts, :allowed_tools, @default_allowed_tools)
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    model = Keyword.get(opts, :model) || worker_model(task.role)

    %Options{
      model: model,
      max_turns: max_turns,
      output_format: :json,
      allowed_tools: allowed,
      permission_mode: :bypass_permissions,
      append_system_prompt: """
      You are a Tracy worker — role: #{task.role}. The boardroom has delegated
      this task to you. Work autonomously. Don't ask clarifying questions
      unless absolutely blocked; in that case, end with `## Needs Input`
      and a one-line question.
      """
    }
  rescue
    _ ->
      # Older SDK versions may not support all fields. Fall back to a leaner
      # config that's guaranteed to compile.
      %Options{model: worker_model(task.role), max_turns: @default_max_turns}
  end

  # Per-role model defaults (locked in TRACY_CSUITE.md roster table).
  defp worker_model("engineer"), do: "sonnet"
  defp worker_model("designer"), do: "sonnet"
  defp worker_model("reviewer"), do: "sonnet"
  defp worker_model("operator"), do: "sonnet"
  defp worker_model(_other), do: "haiku"

  # ---- report extraction ----

  defp build_report(_task, sdk_messages, started_at, completed_at) do
    text = extract_assistant_text(sdk_messages)
    result = find_result_message(sdk_messages)

    cost_usd = result && Map.get(result.data, :total_cost_usd, 0.0)
    cost_micros = round((cost_usd || 0.0) * 1_000_000)

    duration_ms = DateTime.diff(completed_at, started_at, :millisecond)

    %{
      summary: extract_summary(text),
      files_changed: extract_files_changed(text),
      proposed_next_steps: extract_next_steps(text),
      cost_micros: cost_micros,
      metadata: %{
        "provider" => "claude",
        "model" => result && get_in(result.data, [:model]) |> to_string(),
        "duration_ms" => duration_ms,
        "full_text" => text
      }
    }
  end

  defp extract_assistant_text(sdk_messages) do
    sdk_messages
    |> Enum.filter(&match?(%ClaudeAgentSDK.Message{type: :assistant}, &1))
    |> Enum.map(&extract_text_blocks/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp extract_text_blocks(%ClaudeAgentSDK.Message{data: %{message: %{"content" => content}}})
       when is_list(content) do
    content
    |> Enum.filter(fn
      %{"type" => "text"} -> true
      _ -> false
    end)
    |> Enum.map(fn %{"text" => t} -> t end)
    |> Enum.join("")
    |> String.trim()
  end

  defp extract_text_blocks(%ClaudeAgentSDK.Message{data: %{message: %{"content" => content}}})
       when is_binary(content),
       do: String.trim(content)

  defp extract_text_blocks(_), do: ""

  defp find_result_message(sdk_messages) do
    Enum.find(sdk_messages, &match?(%ClaudeAgentSDK.Message{type: :result}, &1))
  end

  # Pull the first non-empty line under "## Summary", else the first line of
  # the response, else the whole thing capped.
  defp extract_summary(text) do
    cond do
      match = Regex.run(~r/##\s*Summary\s*\n+\s*-?\s*([^\n]+)/i, text) ->
        Enum.at(match, 1) |> String.trim()

      true ->
        text
        |> String.split("\n", trim: true)
        |> Enum.find(&(&1 != ""))
        |> case do
          nil -> "Task completed."
          first -> String.slice(first, 0, 240)
        end
    end
  end

  defp extract_files_changed(text) do
    case Regex.run(~r/files\s+touched:\s*([^\n]+)/i, text) do
      [_, list] when is_binary(list) ->
        if String.trim(list) == "none" do
          []
        else
          list
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
        end

      _ ->
        []
    end
  end

  defp extract_next_steps(text) do
    case Regex.run(~r/next\s+steps:\s*([^\n]+(?:\n\s*-\s*[^\n]+)*)/i, text) do
      [_, raw] ->
        raw
        |> String.split(~r/\n\s*-\s*/)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.downcase(&1) == "none"))

      _ ->
        []
    end
  end
end
