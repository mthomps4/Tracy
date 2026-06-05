defmodule Tracy.Session.Server do
  @moduledoc """
  GenServer holding one persistent boardroom session.

  Per `TRACY_V1_SCOPE.md`'s "one session for the world" decision, Tracy runs
  a single long-lived session that shifts project context on command. The
  Server keeps:

    * `id` — UUID assigned by `Tracy.Session.start/1`
    * `messages` — in-memory conversation history (latest last)
    * `current_project` — optional project scope for memory retrieval
    * `subscribers` — PubSub topic name (callers subscribe via Phoenix.PubSub)

  ## Lifecycle

  Sessions start on demand via `Tracy.Session.start/1` (which delegates to
  the DynamicSupervisor). They idle-timeout after 30 minutes of no activity
  and write a handoff Episode before exiting, so the next session can pick
  up where this one left off (via the consolidator and retrieval).

  ## Streaming

  When `send_message/2` is called, the Server spawns a Task that drives
  `Tracy.LLM.stream_chat/3`. Each `:chunk` event is broadcast via
  `Phoenix.PubSub` on topic `"session:<id>"`. The final `:done` event
  appends the assistant message to history and broadcasts a `:done` event
  carrying the full response (and the recorded AgentRun cost).
  """
  use GenServer, restart: :transient

  alias Phoenix.PubSub
  alias Tracy.LLM
  alias Tracy.LLM.Message
  alias Tracy.Memory
  alias Tracy.Session.Registry, as: SessionRegistry

  @idle_timeout :timer.minutes(30)

  defstruct [:id, :current_project, messages: [], stream_task: nil]

  # ---- client API (delegated to from Tracy.Session) ----

  def child_spec(opts) do
    %{
      id: {__MODULE__, opts[:id]},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def send_message(id, content) when is_binary(content) do
    GenServer.call(via(id), {:send_message, content})
  end

  def stream_message(id, content) when is_binary(content) do
    GenServer.call(via(id), {:stream_message, content})
  end

  def messages(id), do: GenServer.call(via(id), :messages)

  def switch_project(id, project), do: GenServer.call(via(id), {:switch_project, project})

  def topic(id), do: "session:#{id}"

  def via(id), do: {:via, Registry, {SessionRegistry, id}}

  # ---- callbacks ----

  @impl true
  def init(opts) do
    messages =
      case Keyword.get(opts, :messages) do
        nil -> rehydrate_messages(opts)
        explicit -> explicit
      end

    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      current_project: Keyword.get(opts, :project),
      messages: messages
    }

    {:ok, state, @idle_timeout}
  end

  # Rebuild conversation history from past session Episodes so a restart of
  # the BEAM (or the GenServer's 30-min idle timeout) doesn't wipe the chat.
  # Caller can opt out by passing `rehydrate: false`.
  defp rehydrate_messages(opts) do
    if Keyword.get(opts, :rehydrate, true) do
      limit = Keyword.get(opts, :rehydrate_limit, 50)

      try do
        Tracy.Memory.session_history(limit: limit)
      rescue
        _ -> []
      end
    else
      []
    end
  end

  @impl true
  def handle_call({:send_message, content}, _from, state) do
    user_msg = Message.user(content)
    new_state = %{state | messages: state.messages ++ [user_msg]}

    record_episode(:user, content, new_state.current_project)

    case LLM.chat(new_state.messages,
           session_id: new_state.id,
           role: "main",
           bucket: :interactive
         ) do
      {:ok, response} ->
        final_state = %{
          new_state
          | messages: new_state.messages ++ [response.message]
        }

        record_episode(:assistant, response.message.content, final_state.current_project)
        broadcast(state.id, {:done, response})
        {:reply, {:ok, response}, final_state, @idle_timeout}

      {:error, _} = err ->
        {:reply, err, new_state, @idle_timeout}
    end
  end

  def handle_call({:stream_message, content}, _from, state) do
    user_msg = Message.user(content)
    new_state = %{state | messages: state.messages ++ [user_msg]}

    record_episode(:user, content, new_state.current_project)

    parent = self()
    id = state.id

    task =
      Task.async(fn ->
        callback = fn event ->
          PubSub.broadcast(Tracy.PubSub, topic(id), {:session_event, id, event})

          case event do
            {:done, response} -> send(parent, {:stream_done, response})
            _ -> :ok
          end
        end

        try do
          case LLM.stream_chat(new_state.messages,
                 [session_id: id, role: "main", bucket: :interactive],
                 callback
               ) do
            {:ok, _response} ->
              :ok

            {:error, reason} ->
              callback.({:error, reason})
          end
        rescue
          exception ->
            callback.({:error, {:exception, exception}})
        catch
          kind, value ->
            callback.({:error, {kind, value}})
        end
      end)

    {:reply, :ok, %{new_state | stream_task: task}, @idle_timeout}
  end

  def handle_call(:messages, _from, state) do
    {:reply, state.messages, state, @idle_timeout}
  end

  def handle_call({:switch_project, project}, _from, state) do
    {:reply, :ok, %{state | current_project: project}, @idle_timeout}
  end

  @impl true
  def handle_info({:stream_done, response}, state) do
    final_state = %{
      state
      | messages: state.messages ++ [response.message],
        stream_task: nil
    }

    record_episode(:assistant, response.message.content, final_state.current_project)
    {:noreply, final_state, @idle_timeout}
  end

  # Task completion / DOWN — ignore (cleanup done in :stream_done)
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state, @idle_timeout}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state, @idle_timeout}

  def handle_info(:timeout, state) do
    # Graceful idle stop — Phase 2+ will write a handoff Episode here.
    {:stop, :normal, state}
  end

  # ---- helpers ----

  defp broadcast(id, event), do: PubSub.broadcast(Tracy.PubSub, topic(id), {:session_event, id, event})

  defp record_episode(role, content, project) do
    Memory.record_episode(%{
      source: "session",
      project: project,
      body: content,
      metadata: %{"role" => Atom.to_string(role)}
    })
  rescue
    _ -> :ok
  end
end
