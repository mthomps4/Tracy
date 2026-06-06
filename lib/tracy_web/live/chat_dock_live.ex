defmodule TracyWeb.ChatDockLive do
  @moduledoc """
  The Boardroom, but everywhere.

  Sticky LiveView mounted from the app layout via
  `live_render(@socket, __MODULE__, sticky: true, ...)`. Survives
  `live_redirect` / `push_navigate` across the rest of the app — Matt
  can talk to Tracy from any page without losing the conversation.

  ### Three render shells, one brain

  - **peek** (default) — small tab pinned to the bottom-right (desktop) /
    bottom (mobile). Tap to open. Shows a count badge when there's
    backgrounded work awaiting review.
  - **open** (desktop) — right-rail panel, ~380px, glassmorphic.
    Cmd+J toggles. Esc closes.
  - **sheet** (mobile) — bottom sheet at three snap points (peek / half /
    full). Drag handle controls snap. Swipe down to dismiss.

  ### Same session as BoardroomLive

  Both surfaces derive the session id from `user.id` — typing in the
  dock and opening the standalone `/boardroom` page show the same
  conversation. Stream chunks broadcast on `session:<id>` are picked up
  by every subscriber.

  ### Voice input

  Mic button uses the browser's `SpeechRecognition` API (Chrome /
  Safari / Edge). Interim transcripts stream into the composer; final
  result auto-submits if Matt held the mic open. Zero install — works
  on phone Safari today.
  """
  use TracyWeb, :live_view

  alias Tracy.{Billing, Session}

  @impl true
  def mount(_params, %{"user_id" => user_id}, socket) do
    session_id = derive_session_id(user_id)
    {:ok, _} = Session.start(id: session_id)

    if connected?(socket) do
      :ok = Session.subscribe(session_id)
      Phoenix.PubSub.subscribe(Tracy.PubSub, "chat:context:#{user_id}")
      Phoenix.PubSub.subscribe(Tracy.PubSub, "chat:notifications")
    end

    messages =
      session_id
      |> Session.messages()
      |> Enum.with_index(1)
      |> Enum.map(&to_view_message/1)

    next_index = length(messages) + 1

    socket =
      socket
      |> assign(:user_id, user_id)
      |> assign(:session_id, session_id)
      |> assign(:open?, false)
      |> assign(:snap, "peek")
      |> assign(:composer, "")
      |> assign(:streaming?, false)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, nil)
      |> assign(:next_index, next_index)
      |> assign(:pinned_project, nil)
      |> assign(:listening?, false)
      |> assign(:cost, Billing.sdk_pool_status())
      |> assign(:warm?, embedder_warm?())
      |> stream(:messages, messages, dom_id: &"dock-msg-#{&1.index}")

    # Poll embedder warm status every 2s until it flips, so the dock
    # can show "still loading the brain" if Matt is faster than the
    # prewarm task.
    if connected?(socket) and not socket.assigns.warm? do
      Process.send_after(self(), :poll_warm, 2_000)
    end

    {:ok, socket, layout: false}
  end

  defp embedder_warm? do
    try do
      Tracy.Memory.Embeddings.Nomic.warm?()
    rescue
      _ -> true   # If the embedder isn't running (Stub provider), pretend warm
    catch
      :exit, _ -> true
    end
  end

  # ---- events ----

  @impl true
  def handle_event("toggle", _, socket) do
    {:noreply,
     socket
     |> assign(:open?, !socket.assigns.open?)
     |> assign(:snap, if(socket.assigns.open?, do: "peek", else: "half"))}
  end

  def handle_event("close", _, socket) do
    {:noreply, assign(socket, :open?, false) |> assign(:snap, "peek")}
  end

  def handle_event("snap", %{"to" => snap}, socket) when snap in ["peek", "half", "full"] do
    {:noreply, assign(socket, :snap, snap)}
  end

  def handle_event("compose", %{"composer" => text}, socket) do
    {:noreply, assign(socket, :composer, text)}
  end

  # Voice transcript arrives as a phx-hook event — replace or append
  # to the composer depending on whether it's interim or final.
  def handle_event("voice:transcript", %{"text" => text, "final" => final}, socket) do
    socket =
      socket
      |> assign(:composer, text)
      |> assign(:listening?, !final)

    if final and String.trim(text) != "" do
      dispatch_message(text, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("voice:start", _, socket), do: {:noreply, assign(socket, :listening?, true)}
  def handle_event("voice:stop", _, socket), do: {:noreply, assign(socket, :listening?, false)}

  def handle_event("send", %{"composer" => text}, socket) when byte_size(text) > 0 do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      String.starts_with?(text, "/") ->
        handle_slash_command(text, socket)

      true ->
        dispatch_message(text, socket)
    end
  end

  def handle_event("send", _, socket), do: {:noreply, socket}

  # ---- slash commands ----

  defp handle_slash_command(text, socket) do
    case parse_command(text) do
      {:pin, name} -> cmd_pin(name, socket)
      {:switch, name} -> cmd_pin(name, socket)
      :unpin -> cmd_unpin(socket)
      :memo -> cmd_memo(socket)
      :help -> cmd_help(socket)
      {:unknown, name} -> push_system("Unknown command `#{name}`. Try `/help`.", socket)
    end
  end

  defp parse_command(text) do
    case String.split(text, " ", parts: 2) do
      ["/pin"] -> :unpin
      ["/pin", rest] -> {:pin, String.trim(rest)}
      ["/switch", rest] -> {:switch, String.trim(rest)}
      ["/switch"] -> {:unknown, "switch (needs a project name)"}
      ["/unpin"] -> :unpin
      ["/memo"] -> :memo
      ["/memo", _] -> :memo
      ["/help"] -> :help
      ["/help", _] -> :help
      ["/" <> name | _] -> {:unknown, name}
    end
  end

  defp cmd_pin("", socket), do: cmd_unpin(socket)

  defp cmd_pin(name, socket) do
    Phoenix.PubSub.broadcast(
      Tracy.PubSub,
      "chat:context:#{socket.assigns.user_id}",
      {:context, %{project: name}}
    )

    socket
    |> assign(:pinned_project, name)
    |> assign(:composer, "")
    |> push_system("Pinned project: **#{name}**. Subsequent messages route to this context until you `/unpin` or `/switch <other>`.")
  end

  defp cmd_unpin(socket) do
    Phoenix.PubSub.broadcast(
      Tracy.PubSub,
      "chat:context:#{socket.assigns.user_id}",
      {:context, %{project: nil}}
    )

    socket
    |> assign(:pinned_project, nil)
    |> assign(:composer, "")
    |> push_system("Unpinned. I'll route context implicitly from your messages now.")
  end

  defp cmd_memo(socket) do
    messages =
      socket.assigns.session_id
      |> Tracy.Session.messages()
      |> Enum.take(-10)

    summary = build_memo(messages, socket.assigns.pinned_project)

    socket
    |> assign(:composer, "")
    |> push_system(summary)
  end

  defp cmd_help(socket) do
    socket
    |> assign(:composer, "")
    |> push_system("""
    Slash commands:

    `/pin <project>`     Pin a project context — subsequent messages
                         route there. The pin shows in the dock header.
    `/switch <project>`  Alias for `/pin`.
    `/unpin`             Drop the pin, route implicitly again.
    `/memo`              Show a quick recap of the recent conversation.
    `/help`              This list.
    """)
  end

  defp build_memo([], _project), do: "No conversation yet to recap."

  defp build_memo(messages, project) do
    header =
      case project do
        nil -> "Recent recap (last #{length(messages)} turns):"
        name -> "Recent recap — pinned to **#{name}** (last #{length(messages)} turns):"
      end

    lines =
      messages
      |> Enum.map(fn
        %Tracy.LLM.Message{role: :user, content: c} -> "👤 #{first_line(c)}"
        %Tracy.LLM.Message{role: :assistant, content: c} -> "🧠 #{first_line(c)}"
        %Tracy.LLM.Message{role: :system, content: c} -> "ℹ️  #{first_line(c)}"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    "#{header}\n\n#{lines}"
  end

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 140)
  end

  defp push_system(content, socket) when is_binary(content) do
    push_system(socket, content)
  end

  defp push_system(socket, content) do
    idx = socket.assigns.next_index

    view = %{
      index: idx,
      role: :system,
      content: content,
      streaming?: false
    }

    {:noreply,
     socket
     |> stream_insert(:messages, view, dom_id: "dock-msg-#{idx}")
     |> assign(:next_index, idx + 1)
     |> assign(:open?, true)
     |> assign(:snap, "half")}
  end

  defp dispatch_message(text, socket) do
    user_idx = socket.assigns.next_index
    assistant_idx = user_idx + 1

    user_view = %{
      index: user_idx,
      role: :user,
      content: text,
      streaming?: false
    }

    assistant_view = %{
      index: assistant_idx,
      role: :assistant,
      content: "",
      streaming?: true
    }

    :ok = Session.stream_message(socket.assigns.session_id, text)

    socket =
      socket
      |> stream_insert(:messages, user_view, dom_id: "dock-msg-#{user_view.index}")
      |> stream_insert(:messages, assistant_view, dom_id: "dock-msg-#{assistant_view.index}")
      |> assign(:composer, "")
      |> assign(:streaming?, true)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, assistant_idx)
      |> assign(:next_index, assistant_idx + 1)
      |> assign(:open?, true)
      |> assign(:snap, "half")

    {:noreply, socket}
  end

  # ---- pubsub ----

  @impl true
  def handle_info({:session_event, _id, {:chunk, chunk}}, socket) do
    new_buffer = socket.assigns.streaming_buffer <> chunk

    updated = %{
      index: socket.assigns.streaming_index,
      role: :assistant,
      content: new_buffer,
      streaming?: true
    }

    {:noreply,
     socket
     |> stream_insert(:messages, updated, dom_id: "dock-msg-#{updated.index}")
     |> assign(:streaming_buffer, new_buffer)}
  end

  def handle_info({:session_event, _id, {:done, response}}, socket) do
    final = %{
      index: socket.assigns.streaming_index,
      role: :assistant,
      content: response.message.content,
      streaming?: false
    }

    {:noreply,
     socket
     |> stream_insert(:messages, final, dom_id: "dock-msg-#{final.index}")
     |> assign(:streaming?, false)
     |> assign(:streaming_buffer, "")
     |> assign(:streaming_index, nil)
     |> assign(:cost, Billing.sdk_pool_status())}
  end

  def handle_info({:session_event, _id, {:error, reason}}, socket) do
    err = %{
      index: socket.assigns.streaming_index || socket.assigns.next_index,
      role: :error,
      content: format_error(reason),
      streaming?: false
    }

    {:noreply,
     socket
     |> stream_insert(:messages, err, dom_id: "dock-msg-#{err.index}")
     |> assign(:streaming?, false)
     |> assign(:streaming_buffer, "")
     |> assign(:streaming_index, nil)
     |> assign(:next_index, max(socket.assigns.next_index, err.index + 1))}
  end

  # Context updates from page LiveViews — "you're now looking at project X"
  def handle_info({:context, ctx}, socket) when is_map(ctx) do
    {:noreply, assign(socket, :pinned_project, Map.get(ctx, :project))}
  end

  # Worker completion notice — drop a system bubble so Matt sees that
  # backgrounded work just landed without having to navigate to the
  # task's Live tab.
  def handle_info({:worker_completed_notice, task, report}, socket) do
    summary = Map.get(report, :summary, "Worker finished.")
    files = Map.get(report, :files_changed, [])

    files_line =
      case files do
        [] -> ""
        list -> "\n📂 " <> Enum.join(list, ", ")
      end

    push_system(
      "🔧 #{String.capitalize(task.role)} done — #{task.title}\n\n#{summary}#{files_line}",
      socket
    )
  end

  def handle_info({:worker_failed_notice, task, reason}, socket) do
    push_system(
      "⚠️  #{String.capitalize(task.role)} **failed** — #{task.title}\n\n#{inspect(reason, limit: 200)}",
      socket
    )
  end

  # Poll the embedder warm status until it flips to true, then stop
  # polling. Used for the subtle "still warming" indicator in the dock
  # header.
  def handle_info(:poll_warm, socket) do
    warm? = embedder_warm?()

    socket = assign(socket, :warm?, warm?)

    if not warm? do
      Process.send_after(self(), :poll_warm, 2_000)
    end

    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="chat-dock-root"
      phx-hook="ChatDock"
      class={[
        "chat-dock",
        @open? && "chat-dock--open",
        !@open? && "chat-dock--peek",
        "chat-dock--snap-#{@snap}"
      ]}
      data-open={to_string(@open?)}
      data-snap={@snap}
    >
      <%!-- Peek launcher — always visible. Tap to open. --%>
      <button
        type="button"
        phx-click="toggle"
        class="chat-dock__launcher"
        aria-label="Open Tracy"
        aria-expanded={to_string(@open?)}
      >
        <span class="chat-dock__avatar" aria-hidden="true">
          <span class={[
            "chat-dock__pulse",
            @streaming? && "chat-dock__pulse--active"
          ]}></span>
          <span class="chat-dock__avatar-letter">T</span>
        </span>
        <span class="chat-dock__launcher-label">Tracy</span>
        <span :if={@pinned_project} class="chat-dock__pinned-pill">
          📌 {@pinned_project}
        </span>
      </button>

      <%!-- Expanded panel (covers the launcher when open) --%>
      <section :if={@open?} class="chat-dock__panel" aria-label="Tracy chat">
        <header class="chat-dock__header">
          <div class="chat-dock__header-id">
            <span class="chat-dock__avatar chat-dock__avatar--small" aria-hidden="true">
              <span class="chat-dock__avatar-letter">T</span>
            </span>
            <div>
              <p class="chat-dock__header-name">Tracy</p>
              <p :if={!@warm?} class="chat-dock__header-sub chat-dock__header-sub--warming">
                warming memory…
              </p>
              <p :if={@warm? && @pinned_project} class="chat-dock__header-sub">
                pinned · {@pinned_project}
              </p>
              <p :if={@warm? && !@pinned_project} class="chat-dock__header-sub">
                {format_cost(@cost)}
              </p>
            </div>
          </div>
          <div class="chat-dock__header-actions">
            <%!-- Mobile snap controls --%>
            <button
              type="button"
              phx-click="snap"
              phx-value-to="full"
              class={["chat-dock__icon-btn chat-dock__icon-btn--mobile", @snap == "full" && "is-active"]}
              aria-label="Expand"
              title="Expand"
            >
              <span aria-hidden="true">▴</span>
            </button>
            <button
              type="button"
              phx-click="close"
              class="chat-dock__icon-btn"
              aria-label="Close"
              title="Close (Esc)"
            >
              <span aria-hidden="true">✕</span>
            </button>
          </div>
        </header>

        <section
          id="chat-dock-messages"
          phx-update="stream"
          phx-hook="ScrollToBottom"
          class="chat-dock__messages"
        >
          <article id="chat-dock-empty" class="only:flex hidden chat-dock__empty">
            <p>Say hi.</p>
            <p class="chat-dock__empty-hint">
              Cmd+J to open / close. Tap 🎤 to talk.
            </p>
          </article>

          <article
            :for={{dom_id, msg} <- @streams.messages}
            id={dom_id}
            class={[
              "chat-dock__bubble",
              "chat-dock__bubble--#{msg.role}"
            ]}
          >
            <%= cond do %>
              <% msg.role == :assistant and msg.content == "" -> %>
                <span class="chat-dock__thinking">
                  <span class="chat-dock__thinking-dot"></span>
                  <span>thinking…</span>
                </span>
              <% msg.role == :error -> %>
                <pre class="chat-dock__error">{msg.content}</pre>
              <% true -> %>
                <p>{msg.content}</p>
            <% end %>
          </article>
        </section>

        <form phx-submit="send" phx-change="compose" class="chat-dock__composer">
          <textarea
            id="chat-dock-input"
            name="composer"
            rows="1"
            phx-hook="GrowComposer"
            phx-keydown={JS.dispatch("tracy:submit-on-enter")}
            phx-key="Enter"
            placeholder={if @streaming?, do: "Tracy is thinking…", else: "Say something to Tracy…"}
            disabled={@streaming?}
            class="chat-dock__textarea"
          >{@composer}</textarea>

          <button
            type="button"
            id="chat-dock-mic"
            phx-hook="VoiceInput"
            data-listening={to_string(@listening?)}
            class={["chat-dock__mic", @listening? && "chat-dock__mic--listening"]}
            aria-label={if @listening?, do: "Stop listening", else: "Talk to Tracy"}
            title="Hold to talk · tap to toggle"
          >
            <%= if @listening? do %>
              <span aria-hidden="true">⏸</span>
            <% else %>
              <span aria-hidden="true">🎤</span>
            <% end %>
          </button>

          <button
            type="submit"
            disabled={@streaming? or @composer == ""}
            class="chat-dock__send"
            aria-label="Send"
            title="Send (Enter)"
          >
            <span aria-hidden="true">↑</span>
          </button>
        </form>
      </section>
    </div>
    """
  end

  # ---- helpers ----

  defp to_view_message({%Tracy.LLM.Message{} = msg, index}) do
    %{
      index: index,
      role: msg.role,
      content: msg.content,
      streaming?: false
    }
  end

  defp format_cost(%{spent_dollars: spent, cap_dollars: cap}),
    do: "$#{:erlang.float_to_binary(spent, decimals: 2)} / $#{cap}"

  defp format_cost(_), do: ""

  defp format_error({:claude_sdk_error, %{__struct__: _} = exception}),
    do: "SDK error: " <> Exception.message(exception)

  defp format_error({:claude_sdk_error, other}),
    do: "SDK error: " <> inspect(other, limit: 200)

  defp format_error(:timeout), do: "Timed out."
  defp format_error(other), do: "Error: " <> inspect(other, limit: 200)

  # Deterministic UUID derived from the user id so the same person
  # always reopens the same Boardroom session, no matter how many
  # tabs they have open. Mirrors BoardroomLive.derive_session_id/1.
  defp derive_session_id(user_id) do
    raw = :crypto.hash(:sha256, "tracy-session:#{user_id}")
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = raw

    <<a::32, b::16, c::16, d::16, e::48>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
