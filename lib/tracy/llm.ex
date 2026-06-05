defmodule Tracy.LLM do
  @moduledoc """
  Public API for chatting with whatever LLM is wired up.

  ## The seam

  Tracy is **Claude-only by design**. Per
  `~/.claude/projects/-home-matt-Code/memory/feedback_claude_sdk_only_not_anthropix.md`,
  all real Claude calls must route through `claude -p` via `claude_code_sdk`
  to land on the Max plan's SDK credit pool. Raw `anthropix` HTTP bypasses
  the credit pool and bills at console rates — explicitly NOT used here.

  This module exists to:

    1. Keep the chat call site stable across the eventual swap from Stub to
       Claude impl.
    2. Make tests and dev work without a real OAuth token configured.
    3. Leave a thin seam open for a `local` impl when on-device models
       catch up (per the local-models exit ramp in TRACY_FUTURE.md).

  ## Behaviour

  Implementations: `Tracy.LLM.Stub`, future `Tracy.LLM.Claude`.

  ## Config

      config :tracy, Tracy.LLM,
        adapter: Tracy.LLM.Stub,
        default_model: "stub"

  ## Usage

      iex> Tracy.LLM.chat([Tracy.LLM.Message.user("hi")])
      {:ok, %{
        message: %Tracy.LLM.Message{role: :assistant, content: "..."},
        usage: %{input_tokens: 2, output_tokens: 9, ...},
        model: "stub"
      }}
  """
  alias Tracy.LLM.Message

  @type chat_response :: %{
          message: Message.t(),
          usage: %{
            input_tokens: non_neg_integer(),
            output_tokens: non_neg_integer(),
            cache_read_tokens: non_neg_integer(),
            cache_creation_tokens: non_neg_integer()
          },
          model: String.t(),
          cost_micros: non_neg_integer(),
          bucket: :interactive | :sdk_pool
        }

  @type stream_event ::
          {:chunk, String.t()}
          | {:done, chat_response()}
          | {:error, term()}

  @callback chat([Message.t()], keyword()) :: {:ok, chat_response()} | {:error, term()}
  @callback stream_chat([Message.t()], keyword(), (stream_event() -> any())) ::
              {:ok, chat_response()} | {:error, term()}

  @optional_callbacks [stream_chat: 3]

  @doc """
  Send a list of messages, get back a single completion.

  Options:

    * `:model`    — override the configured default
    * `:role`     — Tracy worker role to attribute the cost to (default `"main"`)
    * `:session_id` — Tracy.Session id, threaded into the cost ledger
    * `:bucket`   — `:interactive` (default for main session) or `:sdk_pool` (workers)
  """
  @spec chat([Message.t()], keyword()) :: {:ok, chat_response()} | {:error, term()}
  def chat(messages, opts \\ []) when is_list(messages) do
    adapter().chat(messages, with_defaults(opts))
  end

  @doc """
  Stream chunks back via the callback. Returns the final response when done.

  Adapters that don't support streaming fall back to a single `:done` event.
  """
  @spec stream_chat([Message.t()], keyword(), (stream_event() -> any())) ::
          {:ok, chat_response()} | {:error, term()}
  def stream_chat(messages, opts, callback) when is_list(messages) and is_function(callback, 1) do
    adapter = adapter()

    if function_exported?(adapter, :stream_chat, 3) do
      adapter.stream_chat(messages, with_defaults(opts), callback)
    else
      with {:ok, response} <- adapter.chat(messages, with_defaults(opts)) do
        callback.({:chunk, response.message.content})
        callback.({:done, response})
        {:ok, response}
      end
    end
  end

  @doc "The currently configured adapter module."
  def adapter do
    config() |> Keyword.get(:adapter, Tracy.LLM.Stub)
  end

  @doc "The default model name for the configured adapter."
  def default_model do
    config() |> Keyword.get(:default_model, "stub")
  end

  defp config, do: Application.get_env(:tracy, __MODULE__, [])

  defp with_defaults(opts) do
    opts
    |> Keyword.put_new(:model, default_model())
    |> Keyword.put_new(:role, "main")
    |> Keyword.put_new(:bucket, :interactive)
  end
end
