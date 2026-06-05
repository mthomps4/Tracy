defmodule Tracy.LLM.Claude do
  @moduledoc """
  Real Claude adapter — routes through `ClaudeAgentSDK.query/2`, which under
  the hood invokes `claude -p` and lands on the Max plan's SDK credit pool.

  ## Auth

  Authentication is picked up from `~/.claude/.credentials.json` (created by
  `claude setup-token`). The SDK's auth priority is:

    1. `CLAUDE_AGENT_OAUTH_TOKEN` env var
    2. `ANTHROPIC_API_KEY` env var (DO NOT SET — would bill at console rates)
    3. CLI login session (~/.claude/.credentials.json)

  Tracy explicitly relies on (3). If `ANTHROPIC_API_KEY` is set in env when
  Tracy runs, Claude Code prefers it over OAuth and bills at API rates against
  the console balance — bypassing the Max plan benefit entirely.

  See `feedback_claude_sdk_only_not_anthropix.md` in memory.

  ## Billing

  Every call lands on the SDK pool bucket (`:sdk_pool`). The `interactive`
  bucket only receives spend from your own terminal Claude Code usage, never
  from Tracy.

  ## v1 scope

  - **No conversation continuity yet** — each `chat/2` call sends the latest
    user message as a single-turn query. The CLAUDE.md at the project root
    provides standing context. Multi-turn via `ClaudeAgentSDK.resume/3` or
    Streaming sessions can come later if Matt needs it.
  - **Streaming falls back to chat + single chunk** for now. Real per-token
    streaming via `ClaudeAgentSDK.Streaming` is a follow-up.

  Behaviour: `Tracy.LLM`.
  """
  @behaviour Tracy.LLM

  require Logger

  alias ClaudeAgentSDK.{ContentExtractor, Options}
  alias Tracy.Billing
  alias Tracy.LLM.Message

  @impl true
  def chat(messages, opts) do
    prompt = last_user_text(messages) || ""
    started_at = DateTime.utc_now()
    sdk_opts = build_options(opts)

    try do
      sdk_messages = ClaudeAgentSDK.query(prompt, sdk_opts) |> Enum.to_list()
      completed_at = DateTime.utc_now()

      response =
        sdk_messages
        |> build_response(opts, started_at, completed_at)
        |> record_run(opts, started_at, completed_at)

      {:ok, response}
    rescue
      exception ->
        Logger.warning("Tracy.LLM.Claude.chat failed: #{Exception.message(exception)}")
        {:error, {:claude_sdk_error, exception}}
    end
  end

  @impl true
  def stream_chat(messages, opts, callback) do
    with {:ok, response} <- chat(messages, opts) do
      callback.({:chunk, response.message.content})
      callback.({:done, response})
      {:ok, response}
    end
  end

  # ---- helpers ----

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :user, content: c} -> c
      _ -> nil
    end)
  end

  defp build_options(opts) do
    model = Keyword.get(opts, :model) || Tracy.LLM.default_model()

    %Options{
      model: model,
      max_turns: 1,
      output_format: :json
    }
  rescue
    # Options struct fields can vary by SDK version; fall back to defaults.
    _ -> %Options{}
  end

  defp build_response(sdk_messages, opts, _started_at, _completed_at) do
    assistant_text = extract_assistant_text(sdk_messages)
    result = find_result_message(sdk_messages)

    usage = usage_from_result(result)
    cost_usd = result && result.data && Map.get(result.data, :total_cost_usd, 0.0)
    cost_micros = round((cost_usd || 0.0) * 1_000_000)

    model =
      result
      |> get_in_safe([:data, :model])
      |> Kernel.||(Keyword.get(opts, :model))
      |> Kernel.||(Tracy.LLM.default_model())

    %{
      message: Message.assistant(assistant_text),
      usage: usage,
      model: model,
      cost_micros: cost_micros,
      bucket: :sdk_pool
    }
  end

  defp extract_assistant_text(sdk_messages) do
    sdk_messages
    |> Enum.filter(&match?(%ClaudeAgentSDK.Message{type: :assistant}, &1))
    |> Enum.map(&(ContentExtractor.extract_text(&1) || ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp find_result_message(sdk_messages) do
    Enum.find(sdk_messages, &match?(%ClaudeAgentSDK.Message{type: :result}, &1))
  end

  defp usage_from_result(nil) do
    %{input_tokens: 0, output_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0}
  end

  defp usage_from_result(%ClaudeAgentSDK.Message{data: data}) do
    usage = Map.get(data, :usage, %{}) || %{}

    %{
      input_tokens: Map.get(usage, "input_tokens", 0) || 0,
      output_tokens: Map.get(usage, "output_tokens", 0) || 0,
      cache_read_tokens: Map.get(usage, "cache_read_input_tokens", 0) || 0,
      cache_creation_tokens: Map.get(usage, "cache_creation_input_tokens", 0) || 0
    }
  end

  defp get_in_safe(nil, _path), do: nil
  defp get_in_safe(map, []), do: map
  defp get_in_safe(map, [key | rest]) when is_map(map), do: get_in_safe(Map.get(map, key), rest)
  defp get_in_safe(_, _), do: nil

  defp record_run(response, opts, started_at, completed_at) do
    Billing.record_run(%{
      session_id: opts[:session_id],
      role: opts[:role] || "main",
      provider: "claude",
      model: response.model,
      bucket: Atom.to_string(response.bucket),
      input_tokens: response.usage.input_tokens,
      output_tokens: response.usage.output_tokens,
      cache_read_tokens: response.usage.cache_read_tokens,
      cache_creation_tokens: response.usage.cache_creation_tokens,
      cost_micros: response.cost_micros,
      started_at: started_at,
      completed_at: completed_at,
      metadata: %{"reply_preview" => String.slice(response.message.content, 0, 80)}
    })

    response
  rescue
    _ -> response
  end
end
