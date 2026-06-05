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
  actually do work, including modifying files. The default surface is:

      Read, Grep, Glob, WebSearch, WebFetch, Bash, Edit, Write

  Per-role defaults trim that down where it makes sense — designers drop
  `Edit` (their job is producing new artifacts, not editing code);
  researchers and reviewers drop write capability entirely. See
  `role_allowed_tools/1`. Callers can still override with the
  `:allowed_tools` adapter opt for one-off dispatches.

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
  alias Tracy.Plans
  alias Tracy.Plans.Task

  @default_allowed_tools ~w(Read Grep Glob WebSearch WebFetch Bash Edit Write)
  @default_max_turns 30

  # Per-role tool defaults. A role can override via the `:allowed_tools`
  # adapter opt — these are just the sensible "if you didn't say otherwise"
  # surface for each role.
  @designer_tools ~w(Read Grep Glob WebSearch WebFetch Bash Write)
  @researcher_tools ~w(Read Grep Glob WebSearch WebFetch)
  @reviewer_tools ~w(Read Grep Glob WebSearch WebFetch)
  @note_taker_tools ~w(Read Grep Glob Write)

  @impl true
  def execute(%Task{} = task, opts) do
    workspace = Plans.workspace_path(task.plan_id)
    prompt = build_prompt(task, workspace)
    sdk_opts = build_options(task, opts, workspace)
    progress = Keyword.get(opts, :progress_callback, fn _ -> :ok end)

    started_at = DateTime.utc_now()

    try do
      sdk_messages =
        ClaudeAgentSDK.query(prompt, sdk_opts)
        |> Stream.each(fn msg -> emit_progress(msg, progress) end)
        |> Enum.to_list()

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

  # ---- progress emission ----

  # Translate SDK message into one-or-more transcript events for the UI.
  # Assistant text → :assistant_text; tool_use blocks → :tool_use;
  # user messages carrying tool_result blocks → :tool_result. System +
  # final result messages are skipped (they're noise for the live view).
  defp emit_progress(%ClaudeAgentSDK.Message{type: :assistant, data: %{message: %{"content" => content}}}, progress)
       when is_list(content) do
    Enum.each(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        text = String.trim(text)
        if text != "", do: progress.(%{kind: :assistant_text, text: text})

      %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
        progress.(%{kind: :tool_use, tool_name: name, tool_input: input, tool_id: id})

      _ ->
        :ok
    end)
  end

  defp emit_progress(%ClaudeAgentSDK.Message{type: :user, data: %{message: %{"content" => content}}}, progress)
       when is_list(content) do
    Enum.each(content, fn
      %{"type" => "tool_result", "tool_use_id" => id} = block ->
        progress.(%{
          kind: :tool_result,
          tool_id: id,
          text: tool_result_text(block),
          is_error: Map.get(block, "is_error", false)
        })

      _ ->
        :ok
    end)
  end

  defp emit_progress(_msg, _progress), do: :ok

  defp tool_result_text(%{"content" => content}) when is_binary(content), do: content

  defp tool_result_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      other -> inspect(other)
    end)
    |> Enum.join("\n")
  end

  defp tool_result_text(_), do: ""

  # ---- prompt construction ----

  defp build_prompt(%Task{} = task, workspace) do
    """
    Role: #{task.role}
    Plan task: #{task.title}

    #{if task.brief && task.brief != "", do: "Brief:\n#{task.brief}", else: "(No brief provided — interpret the task title.)"}

    Workspace: your current working directory (`pwd`) is this plan's
    persistent workspace — #{workspace}. Files you create or edit here
    persist across dispatches and are visible to other workers on the
    same plan. `ls` to see what previous workers left behind; organise
    with `mkdir` as needed.

    Do the work. Investigate with tools as needed. Modify files where the task
    calls for it. When you're finished, end your message with a short summary
    block in this exact shape:

        ## Summary
        - <one-line outcome>
        - files touched: <comma-separated list, or "none">
        - next steps: <one to three bullets, or "none">

    If your task involves **breaking work down, planning, or proposing
    follow-ups for other roles** (especially as a PM / Note-taker), also
    include a Proposed Tasks block. Tracy will auto-create these as real
    tasks on the plan:

        ## Proposed Tasks
        - [designer] Title of the task — short brief explaining what to do
        - [engineer] Another task title — short brief
        - [researcher] etc

    Use roles from this set:
    engineer, designer, researcher, pm, reviewer, note_taker, operator, scout.

    Keep your output focused — the C-Suite will read the summary; don't dump
    raw tool traces.
    """
    |> String.trim()
  end

  defp build_options(task, opts, workspace) do
    allowed = Keyword.get(opts, :allowed_tools, role_allowed_tools(task.role))
    max_turns = Keyword.get(opts, :max_turns, @default_max_turns)
    model = Keyword.get(opts, :model) || worker_model(task.role)

    %Options{
      model: model,
      max_turns: max_turns,
      output_format: :json,
      allowed_tools: allowed,
      permission_mode: :bypass_permissions,
      cwd: workspace,
      append_system_prompt: role_system_prompt(task.role)
    }
  rescue
    _ ->
      # Older SDK versions may not support all fields. Fall back to a leaner
      # config that's guaranteed to compile.
      %Options{model: worker_model(task.role), max_turns: @default_max_turns, cwd: workspace}
  end

  @doc """
  Tool allowlist for a role's default dispatch. Caller can override with
  the `:allowed_tools` adapter opt; this is the "no opinion expressed"
  fallback per role.

  Designer drops `Edit` — the role produces *new artifacts*, not
  modifications to existing code. Researcher / reviewer drop write
  capability entirely so they can't accidentally mutate the repo.
  """
  @spec role_allowed_tools(String.t()) :: [String.t()]
  def role_allowed_tools("designer"), do: @designer_tools
  def role_allowed_tools("researcher"), do: @researcher_tools
  def role_allowed_tools("reviewer"), do: @reviewer_tools
  def role_allowed_tools("note_taker"), do: @note_taker_tools
  def role_allowed_tools(_other), do: @default_allowed_tools

  # Per-role model defaults (locked in TRACY_CSUITE.md roster table).
  defp worker_model("engineer"), do: "sonnet"
  defp worker_model("designer"), do: "sonnet"
  defp worker_model("reviewer"), do: "sonnet"
  defp worker_model("operator"), do: "sonnet"
  defp worker_model(_other), do: "haiku"

  @doc """
  Role-specific system prompt appended after the SDK's built-in. Covers
  base worker etiquette plus role-tailored guidance (e.g. designer's
  artifact-output discipline + SVG→PNG conversion tips).
  """
  @spec role_system_prompt(String.t()) :: String.t()
  def role_system_prompt(role) do
    base = """
    You are a Tracy worker — role: #{role}. The boardroom has delegated
    this task to you. Work autonomously. Don't ask clarifying questions
    unless absolutely blocked; in that case, end with `## Needs Input`
    and a one-line question.
    """

    case role_specific_guidance(role) do
      "" -> base
      extra -> base <> "\n" <> extra
    end
  end

  defp role_specific_guidance("designer") do
    """
    Your output is **artifacts**, not code modifications. Treat this like
    a design studio: you have a project folder, you manage it, you hand
    finished files to engineering.

    ### Your workspace

    The current working directory IS your project folder for this plan.
    It persists across dispatches and is shared with other designer
    workers on the same plan. Treat it like a real designer's project
    directory:

    - `ls` first to see existing work (other workers' SVGs, mockups,
      brand assets). Build on them when iterating; don't start from
      zero unless the brief calls for a fresh take.
    - `mkdir` freely to organise — `brand/`, `logos/`, `mockups/`,
      `palette/`, `iterations/v1`, etc. Use whatever structure makes
      the project readable.
    - Edit existing files in place when iterating (e.g. tweaking an
      earlier logo SVG). Save versions in `iterations/` if the brief
      wants distinct alternatives.
    - Delete or move stale junk if it's cluttering things — `rm` and
      `mv` are fair game on your own outputs.

    ### What to produce

    - **Logos, icons, illustrations, infographics** → write SVG directly
      with `Write`. SVG is the source of truth; PNG/JPEG are renders.
    - **Marketing / UI mockups** → standalone HTML files with Tailwind via
      CDN (`<script src="https://cdn.tailwindcss.com"></script>`) so they
      render in any browser without a build step. daisyUI is fine too.
    - **Design system specs** → markdown — color tokens, typography scale,
      spacing, component states. The engineer reads this when implementing.
    - **Copy / microcopy / brand voice** → markdown with section headers.

    ### SVG → PNG / JPEG when you need raster

    Default tool: `rsvg-convert` (librsvg).
        rsvg-convert input.svg -o output.png -w 1024

    Fallback: ImageMagick.
        magick svg:input.svg output.png

    For HTML mockup screenshots (only if Playwright is installed):
        npx playwright screenshot --full-page mockup.html mockup.png

    If neither rsvg-convert nor magick is on the system, leave the SVG and
    note it in `## Summary`. Don't waste turns installing system packages.

    ### Project README

    Keep a `README.md` at the workspace root summarising what's in the
    folder — one line per top-level artifact. Update it as you add or
    reorganise. It's the project handoff doc.

    List every file you created or modified in the `files touched:`
    line of `## Summary` so Tracy's UI can surface them on the plan.

    ### What you should NOT do

    - Don't modify the Tracy app source files. You don't have `Edit` for
      a reason — your job is producing new artifacts in the workspace,
      not editing the app that runs you.
    - Don't generate raster images from scratch (you can't). If the brief
      asks for a photo, end with `## Needs Input` flagging that image
      generation isn't in your toolset yet.
    """
  end

  defp role_specific_guidance("researcher") do
    """
    You're a researcher — gather, synthesise, cite. Don't modify any files.
    Lean on `WebSearch` + `WebFetch` for external sources and `Read` +
    `Grep` for in-repo context. End with a structured summary the C-Suite
    can act on.
    """
  end

  defp role_specific_guidance("reviewer") do
    """
    You're a reviewer — read carefully and report. Don't modify files;
    use `Read` + `Grep` to inspect, `WebFetch` to check external references.
    Be specific: file:line citations beat generic praise or criticism.
    """
  end

  defp role_specific_guidance(_other), do: ""

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
      spawned_tasks: extract_spawned_tasks(text),
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

  # Parse a `## Proposed Tasks` block of the form:
  #   - [role] Title — brief
  # Returns a list of %{role, title, brief}.
  defp extract_spawned_tasks(text) do
    case Regex.run(~r/##\s*Proposed\s+Tasks\s*\n((?:\s*[-*]\s*\[[^\]]+\][^\n]*\n?)+)/i, text) do
      [_, block] ->
        block
        |> String.split("\n")
        |> Enum.map(&parse_proposed_line/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_proposed_line(line) do
    case Regex.run(~r/^\s*[-*]\s*\[([^\]]+)\]\s*(.+)$/, line) do
      [_, role, rest] ->
        # Split title from brief on the first ' — ' (em dash), ' – ' (en dash),
        # or ' - ' (hyphen). Using String.split with a separator list because
        # Elixir's PCRE character class for em-dash is unreliable.
        {title, brief} =
          case String.split(rest, [" — ", " – ", " - "], parts: 2) do
            [t, b] -> {clean_title(t), String.trim(b)}
            [t] -> {clean_title(t), ""}
          end

        role = role |> String.downcase() |> String.trim()

        if role in Tracy.Plans.Task.roles() and title != "" do
          %{role: role, title: title, brief: brief}
        else
          nil
        end

      _ ->
        nil
    end
  end

  # Strip surrounding markdown bold (** ... **) and trim. Keeps titles
  # readable as list-row entries instead of '**D-1.1a Foo**'.
  defp clean_title(text) do
    text
    |> String.trim()
    |> String.replace(~r/^\*\*(.+)\*\*$/, "\\1")
    |> String.trim()
  end
end
