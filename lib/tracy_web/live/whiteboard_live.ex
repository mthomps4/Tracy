defmodule TracyWeb.WhiteboardLive do
  @moduledoc """
  Per-plan chat surface — the "boardroom for this project."

  Mounted as a nested LiveView from `PlanLive.Show` when the Whiteboard tab
  is active. Each plan gets a deterministically-derived `Tracy.Session` id
  so the conversation persists across reloads (rehydrated via session-scoped
  Episodes — see `Tracy.Memory.session_history/1`).

  ### Why this is a separate LiveView (not inline in PlanLive.Show)

  - Lazy mount: the session GenServer doesn't spin up until the user opens
    the tab. Cheap when most plan views never visit the Whiteboard.
  - Pubsub isolation: this LiveView subscribes to `session:<derived_id>`;
    PlanLive.Show's `plans` / `worker:*` / `assets:*` subscriptions stay
    untangled.
  - Future reuse: a self-contained Whiteboard surface drops cleanly into
    other contexts (popout window, side panel) without dragging
    PlanLive.Show along.

  ### Composer text loss on tab switch

  Switching to Tasks/Brief unmounts this LiveView (the `:if=` removes the
  DOM node), which loses the in-progress composer text. Conversation
  history survives because it lives in the Session GenServer + Episodes.
  If this annoys, swap the `:if=` for CSS hide-on-inactive and the
  LiveView stays mounted.
  """
  use TracyWeb, :live_view

  alias Tracy.Session

  @impl true
  def mount(_params, %{"plan_id" => plan_id}, socket) do
    session_id = derive_session_id(plan_id)

    {:ok, _} = Session.start(id: session_id, project: "plan:#{plan_id}")

    if connected?(socket), do: :ok = Session.subscribe(session_id)

    messages =
      session_id
      |> Session.messages()
      |> Enum.with_index(1)
      |> Enum.map(&to_view_message/1)

    next_index = length(messages) + 1

    socket =
      socket
      |> assign(:plan_id, plan_id)
      |> assign(:session_id, session_id)
      |> assign(:composer, "")
      |> assign(:streaming?, false)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, nil)
      |> assign(:next_index, next_index)
      |> stream(:messages, messages, dom_id: &"wb-msg-#{&1.index}")

    {:ok, socket, layout: false}
  end

  # ---- events ----

  @impl true
  def handle_event("compose", %{"composer" => text}, socket) do
    {:noreply, assign(socket, :composer, text)}
  end

  def handle_event("send", %{"composer" => text}, socket) when byte_size(text) > 0 do
    text = String.trim(text)

    if text == "" do
      {:noreply, socket}
    else
      dispatch_message(text, socket)
    end
  end

  def handle_event("send", _, socket), do: {:noreply, socket}

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
      |> stream_insert(:messages, user_view, dom_id: "wb-msg-#{user_view.index}")
      |> stream_insert(:messages, assistant_view, dom_id: "wb-msg-#{assistant_view.index}")
      |> assign(:composer, "")
      |> assign(:streaming?, true)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, assistant_idx)
      |> assign(:next_index, assistant_idx + 1)

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
     |> stream_insert(:messages, updated, dom_id: "wb-msg-#{updated.index}")
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
     |> stream_insert(:messages, final, dom_id: "wb-msg-#{final.index}")
     |> assign(:streaming?, false)
     |> assign(:streaming_buffer, "")
     |> assign(:streaming_index, nil)}
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
     |> stream_insert(:messages, err, dom_id: "wb-msg-#{err.index}")
     |> assign(:streaming?, false)
     |> assign(:streaming_buffer, "")
     |> assign(:streaming_index, nil)
     |> assign(:next_index, max(socket.assigns.next_index, err.index + 1))}
  end

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100dvh-18rem)] min-h-[24rem] flex-col rounded-box border border-base-300/60 bg-base-100/40 sm:h-[calc(100dvh-17rem)]">
      <header class="flex items-center gap-2 border-b border-base-300/60 px-3 py-2 sm:px-4">
        <.icon name="hero-chat-bubble-left-right" class="size-4 text-primary/70" />
        <p class="text-xs font-medium text-base-content/70">
          Whiteboard
        </p>
        <span class="text-[10px] text-base-content/40">— planning chat scoped to this plan</span>
      </header>

      <section
        id={"wb-messages-#{@plan_id}"}
        phx-update="stream"
        phx-hook="ScrollToBottom"
        class="flex-1 space-y-3 overflow-y-auto px-2 py-3 sm:px-3"
      >
        <article id={"wb-empty-#{@plan_id}"} class="only:flex hidden h-full flex-col items-center justify-center text-center text-base-content/60">
          <.icon name="hero-sparkles" class="size-8 text-primary/60" />
          <p class="mt-2 text-sm">Whiteboard's open.</p>
          <p class="text-xs text-base-content/40">
            Use this chat for plan-specific thinking — design choices, scope
            questions, follow-ups. Conversation stays with this plan.
          </p>
        </article>

        <article
          :for={{dom_id, msg} <- @streams.messages}
          id={dom_id}
          class={[
            "flex gap-2 sm:gap-3",
            msg.role == :user && "justify-end",
            msg.role in [:assistant, :error, :system] && "justify-start"
          ]}
        >
          <div class={[
            "max-w-[85%] rounded-2xl px-3 py-2 text-sm leading-relaxed sm:max-w-[78%] sm:px-3.5 sm:py-2.5",
            msg.role == :user && "bg-primary text-primary-content rounded-tr-sm",
            msg.role == :assistant && "bg-base-200 text-base-content rounded-tl-sm",
            msg.role == :system && "border border-accent/40 bg-accent/10 text-base-content rounded-tl-sm",
            msg.role == :error && "border border-error/40 bg-error/10 text-error rounded-tl-sm"
          ]}>
            <%= cond do %>
              <% msg.role == :assistant and msg.content == "" -> %>
                <span class="inline-flex items-center gap-1 text-base-content/60">
                  <span class="size-1.5 rounded-full bg-primary web-pulse"></span>
                  <span class="text-xs">thinking…</span>
                </span>
              <% msg.role == :error -> %>
                <div class="flex items-start gap-2">
                  <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-4 shrink-0" />
                  <p class="whitespace-pre-wrap text-xs sm:text-sm">{msg.content}</p>
                </div>
              <% true -> %>
                <p class="whitespace-pre-wrap">{msg.content}</p>
            <% end %>
          </div>
        </article>
      </section>

      <form
        phx-submit="send"
        phx-change="compose"
        class="flex items-end gap-2 border-t border-base-300/60 bg-base-100/80 px-2 py-2 backdrop-blur sm:px-3"
      >
        <label for={"wb-composer-#{@plan_id}"} class="sr-only">Whiteboard message</label>
        <textarea
          id={"wb-composer-#{@plan_id}"}
          name="composer"
          rows="1"
          placeholder={if @streaming?, do: "Tracy is thinking…", else: "Think out loud about this plan…"}
          disabled={@streaming?}
          phx-hook="GrowComposer"
          phx-keydown={JS.dispatch("tracy:submit-on-enter")}
          phx-key="Enter"
          class="textarea textarea-bordered min-h-11 flex-1 resize-none bg-base-200/60 text-sm sm:text-base"
        >{@composer}</textarea>
        <button
          type="submit"
          disabled={@streaming? or @composer == ""}
          class="btn btn-primary btn-square h-11 min-h-11 w-11 shrink-0"
          aria-label="Send"
        >
          <.icon name="hero-paper-airplane" class="size-4" />
        </button>
      </form>
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

  defp format_error({:claude_sdk_error, %{__struct__: mod} = exception}),
    do: "Claude SDK error (#{inspect(mod)}): #{Exception.message(exception)}"

  defp format_error({:claude_sdk_error, other}),
    do: "Claude SDK error: #{inspect(other, limit: 200)}"

  defp format_error(:timeout),
    do: "The request timed out. Try again or check the Phoenix logs."

  defp format_error(other), do: "Something went wrong: #{inspect(other, limit: 200)}"

  # Deterministic UUID from the plan id so the same plan always opens the
  # same session, even across BEAM restarts and idle-timeout reaps.
  defp derive_session_id(plan_id) do
    raw = :crypto.hash(:sha256, "tracy-whiteboard:#{plan_id}")
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = raw

    <<a::32, b::16, c::16, d::16, e::48>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"
end
