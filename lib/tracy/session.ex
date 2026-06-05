defmodule Tracy.Session do
  @moduledoc """
  Public API for the boardroom session.

  Per `TRACY_V1_SCOPE.md`'s "one session for the world" decision, Tracy
  defaults to a single persistent session keyed by a stable UUID. Callers
  can start/stop/switch-project/send messages without thinking about
  process lifecycle — the DynamicSupervisor handles that.

  ## Persistence

  - **Conversation history** lives in the GenServer's memory and the
    `episodes` table. On idle timeout (30 min) the GenServer exits;
    history reconstitutes from episodes on next `start/1` (Phase 2).
  - **Cost ledger** entries land in `agent_runs` via the LLM adapter.
  - **PubSub broadcasts** on topic `"session:<id>"` carry streaming
    chunks and done/error events; the boardroom LiveView subscribes.

  ## Usage

      iex> {:ok, id} = Tracy.Session.start()
      iex> Tracy.Session.subscribe(id)
      iex> {:ok, response} = Tracy.Session.send_message(id, "hi")
      iex> Tracy.Session.messages(id)
      [%Tracy.LLM.Message{role: :user, ...}, %Tracy.LLM.Message{role: :assistant, ...}]
  """
  alias Phoenix.PubSub
  alias Tracy.Session.{Server, Supervisor}

  @type id :: String.t()

  @doc """
  Start a session. Returns the session id (creates one if not given).

  Options:
    * `:id` — externally-supplied UUID (defaults to a fresh one)
    * `:project` — initial project scope (optional)
    * `:messages` — preloaded message history (optional)
  """
  @spec start(keyword()) :: {:ok, id()} | {:error, term()}
  def start(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :id, &Ecto.UUID.generate/0)

    case Supervisor.start_child(opts) do
      {:ok, _pid} -> {:ok, Keyword.fetch!(opts, :id)}
      {:error, {:already_started, _pid}} -> {:ok, Keyword.fetch!(opts, :id)}
      {:error, _} = err -> err
    end
  end

  @doc "Return whether a session is currently alive."
  def alive?(id), do: Registry.lookup(Tracy.Session.Registry, id) != []

  @doc "Send a message and wait for the full response."
  defdelegate send_message(id, content), to: Server

  @doc """
  Send a message and stream chunks via PubSub. Returns `:ok` immediately;
  subscribe with `subscribe/1` to receive `{:session_event, id, event}`
  messages where event is one of `{:chunk, binary}`, `{:done, response}`,
  `{:error, term}`.
  """
  defdelegate stream_message(id, content), to: Server

  @doc "Return all messages in the conversation."
  defdelegate messages(id), to: Server

  @doc "Switch the session's current project scope."
  defdelegate switch_project(id, project), to: Server

  @doc "The PubSub topic name for a session id."
  defdelegate topic(id), to: Server

  @doc "Subscribe the calling process to a session's PubSub topic."
  def subscribe(id), do: PubSub.subscribe(Tracy.PubSub, topic(id))
end
