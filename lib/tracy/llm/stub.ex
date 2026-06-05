defmodule Tracy.LLM.Stub do
  @moduledoc """
  Deterministic LLM adapter for dev and tests.

  Echoes the last user message in a templated reply, simulates token counts,
  and records spend against the cost ledger so the full call → ledger →
  cost meter pipeline can be exercised end-to-end without a real Claude token.

  Streaming chunks the reply by sentence so the LiveView UI can verify the
  streaming display path before the real adapter is wired.

  Behaviour: `Tracy.LLM`.
  """
  @behaviour Tracy.LLM

  alias Tracy.Billing
  alias Tracy.LLM.Message

  @stub_input_micros_per_token 0
  @stub_output_micros_per_token 0

  @impl true
  def chat(messages, opts) do
    last_user = last_user_text(messages) || ""
    reply = stub_reply(last_user)

    response = build_response(reply, last_user, opts)

    log_run(response, messages, opts)

    {:ok, response}
  end

  @impl true
  def stream_chat(messages, opts, callback) do
    last_user = last_user_text(messages) || ""
    reply = stub_reply(last_user)

    # Emit chunks sentence-by-sentence so the UI's streaming display can be
    # verified without a real model.
    reply
    |> chunk_by_sentence()
    |> Enum.each(fn chunk -> callback.({:chunk, chunk}) end)

    response = build_response(reply, last_user, opts)
    log_run(response, messages, opts)
    callback.({:done, response})

    {:ok, response}
  end

  # ---- internals ----

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :user, content: c} -> c
      _ -> nil
    end)
  end

  defp stub_reply(user_text) when user_text in [nil, ""] do
    "(stub) the boardroom is open — what's the play?"
  end

  defp stub_reply(user_text) do
    """
    (stub) heard you on: "#{String.trim(user_text)}". \
    once the real Claude adapter is wired, this is where the boardroom would actually respond. \
    in the meantime, your message is in the loop and the ledger is recording.
    """
    |> String.trim()
  end

  defp chunk_by_sentence(text) do
    # Split on ". " keeping the period; one chunk per sentence.
    text
    |> String.split(~r/(?<=\.)\s+/)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&(&1 <> ""))
  end

  defp build_response(reply, last_user, opts) do
    input_tokens = approximate_tokens(last_user)
    output_tokens = approximate_tokens(reply)
    cost_micros = input_tokens * @stub_input_micros_per_token + output_tokens * @stub_output_micros_per_token

    %{
      message: Message.assistant(reply),
      usage: %{
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        cache_read_tokens: 0,
        cache_creation_tokens: 0
      },
      model: Keyword.get(opts, :model, "stub"),
      cost_micros: cost_micros,
      bucket: Keyword.get(opts, :bucket, :interactive)
    }
  end

  # Crude token approximation: roughly 4 chars per token, English-leaning.
  defp approximate_tokens(text) when is_binary(text), do: max(1, div(byte_size(text), 4))
  defp approximate_tokens(_), do: 1

  defp log_run(response, _messages, opts) do
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    completed_at = DateTime.utc_now()

    Billing.record_run(%{
      session_id: opts[:session_id],
      role: opts[:role] || "main",
      provider: "stub",
      model: response.model,
      bucket: Atom.to_string(response.bucket),
      input_tokens: response.usage.input_tokens,
      output_tokens: response.usage.output_tokens,
      cost_micros: response.cost_micros,
      started_at: started_at,
      completed_at: completed_at,
      metadata: %{"reply_preview" => String.slice(response.message.content, 0, 60)}
    })
  end
end
