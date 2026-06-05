defmodule TracyWeb.BoardroomLive do
  @moduledoc """
  The boardroom — Tracy's interactive surface.

  Drives a single `Tracy.Session` GenServer. The user types a message;
  `Tracy.Session.stream_message/2` is invoked; chunks arrive via PubSub on
  topic `session:<id>` and are appended to the in-progress assistant
  message in real time.

  ### Session id strategy

  v1 ships with one persistent session keyed by the authenticated user's id
  (so a single user has one room across page reloads). When Tracy gains
  multi-tenancy this changes; until then, `current_scope.user.id` is the
  stable key.

  ### Mobile-first

  Layout uses `Layouts.app` (top nav + mobile bottom tabs). The composer is
  sticky at the bottom of the messages region; the cost meter row stays at
  the top of the page header. Touch targets are ≥44pt; the composer textarea
  auto-grows up to ~6 lines before scrolling.
  """
  use TracyWeb, :live_view

  alias Tracy.{Billing, Plans, Session}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    session_id = derive_session_id(user)

    {:ok, _} = Session.start(id: session_id)

    if connected?(socket), do: :ok = Session.subscribe(session_id)

    messages = Session.messages(session_id) |> Enum.with_index(1) |> Enum.map(&to_view_message/1)
    next_index = length(messages) + 1

    socket =
      socket
      |> assign(:page_title, "Boardroom")
      |> assign(:session_id, session_id)
      |> assign(:streaming?, false)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, nil)
      |> assign(:next_message_index, next_index)
      |> assign(:composer, "")
      |> assign(:cost, Billing.sdk_pool_status())
      |> stream(:messages, messages, dom_id: &"msg-#{&1.index}")

    {:ok, socket}
  end

  @impl true
  def handle_event("compose", %{"composer" => text}, socket) do
    {:noreply, assign(socket, :composer, text)}
  end

  def handle_event("send", %{"composer" => text}, socket) when byte_size(text) > 0 do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, socket}

      slash_command?(text) ->
        handle_slash_command(text, socket)

      true ->
        dispatch_user_message(text, socket)
    end
  end

  def handle_event("send", _params, socket), do: {:noreply, socket}

  # ---- slash commands ----

  defp slash_command?(text), do: String.starts_with?(text, "/")

  defp handle_slash_command(text, socket) do
    case parse_command(text) do
      {:save_as_plan, title} ->
        save_conversation_as_plan(title, socket)

      :help ->
        push_system_message(socket, """
        Available commands:

          /save-as-plan [title]   Capture this conversation as a Plan
                                  (default title = your last message)
          /help                   Show this list
        """)

      {:unknown, name} ->
        push_system_message(socket, "Unknown command: `/#{name}`. Try `/help`.")
    end
  end

  defp parse_command(text) do
    case String.split(text, " ", parts: 2) do
      ["/save-as-plan"] -> {:save_as_plan, nil}
      ["/save-as-plan", rest] -> {:save_as_plan, String.trim(rest)}
      ["/help"] -> :help
      ["/" <> name | _] -> {:unknown, name}
    end
  end

  defp save_conversation_as_plan(title, socket) do
    messages = Session.messages(socket.assigns.session_id)
    last_user = messages |> Enum.reverse() |> Enum.find_value(fn
      %Tracy.LLM.Message{role: :user, content: c} -> c
      _ -> nil
    end)

    title = title || (last_user && first_line(last_user)) || "New plan from boardroom"
    brief = build_brief(messages)

    attrs = %{
      title: String.slice(title, 0, 200),
      brief: brief,
      source_session_id: socket.assigns.session_id
    }

    case Plans.create_plan(attrs) do
      {:ok, plan} ->
        Phoenix.PubSub.broadcast(Tracy.PubSub, "plans", :plans_changed)

        push_system_message(
          socket,
          """
          Saved as plan: **#{plan.title}**
          Status: Triage · open it in the Plans tab to add tasks or approve.
          """
        )

      {:error, cs} ->
        push_system_message(socket, "Couldn't save plan: #{inspect(cs.errors, limit: 200)}")
    end
  end

  defp build_brief(messages) do
    # Compose a quick brief from the last few user messages + assistant replies.
    messages
    |> Enum.take(-6)
    |> Enum.map(fn
      %Tracy.LLM.Message{role: :user, content: c} -> "Matt: #{c}"
      %Tracy.LLM.Message{role: :assistant, content: c} -> "Tracy: #{c}"
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.slice(0, 4000)
  end

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> List.first() |> String.trim()

  defp push_system_message(socket, content) do
    idx = socket.assigns.next_message_index

    view = %{
      index: idx,
      role: :system,
      content: content,
      streaming?: false,
      created_at: DateTime.utc_now()
    }

    # Persist as an Episode so the system bubble survives rehydration.
    # Best-effort — boardroom UX shouldn't fail if the DB write hiccups.
    _ =
      try do
        Tracy.Memory.record_episode(
          %{
            source: "session",
            body: content,
            metadata: %{"role" => "system"}
          },
          embed: false
        )
      rescue
        _ -> :ok
      end

    socket =
      socket
      |> stream_insert(:messages, view, dom_id: "msg-#{idx}")
      |> assign(:composer, "")
      |> assign(:next_message_index, idx + 1)

    {:noreply, socket}
  end

  # ---- normal user message dispatch ----

  defp dispatch_user_message(text, socket) do
    user_idx = socket.assigns.next_message_index
    assistant_idx = user_idx + 1

    user_view = %{
      index: user_idx,
      role: :user,
      content: text,
      streaming?: false,
      created_at: DateTime.utc_now()
    }

    assistant_view = %{
      index: assistant_idx,
      role: :assistant,
      content: "",
      streaming?: true,
      created_at: DateTime.utc_now()
    }

    :ok = Session.stream_message(socket.assigns.session_id, text)

    socket =
      socket
      |> stream_insert(:messages, user_view, dom_id: "msg-#{user_view.index}")
      |> stream_insert(:messages, assistant_view, dom_id: "msg-#{assistant_view.index}")
      |> assign(:composer, "")
      |> assign(:streaming?, true)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, assistant_idx)
      |> assign(:next_message_index, assistant_idx + 1)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_event, _id, {:chunk, chunk}}, socket) do
    new_buffer = socket.assigns.streaming_buffer <> chunk

    updated = %{
      index: socket.assigns.streaming_index,
      role: :assistant,
      content: new_buffer,
      streaming?: true,
      created_at: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:messages, updated, dom_id: "msg-#{updated.index}")
      |> assign(:streaming_buffer, new_buffer)

    {:noreply, socket}
  end

  def handle_info({:session_event, _id, {:done, response}}, socket) do
    final = %{
      index: socket.assigns.streaming_index,
      role: :assistant,
      content: response.message.content,
      streaming?: false,
      created_at: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:messages, final, dom_id: "msg-#{final.index}")
      |> assign(:streaming?, false)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, nil)
      |> assign(:cost, Billing.sdk_pool_status())

    {:noreply, socket}
  end

  def handle_info({:session_event, _id, {:error, reason}}, socket) do
    # Replace the in-flight 'thinking…' assistant bubble with a visible
    # error message so the user always knows the request didn't silently die.
    err_view = %{
      index: socket.assigns.streaming_index || socket.assigns.next_message_index,
      role: :error,
      content: format_error(reason),
      streaming?: false,
      created_at: DateTime.utc_now()
    }

    socket =
      socket
      |> stream_insert(:messages, err_view, dom_id: "msg-#{err_view.index}")
      |> assign(:streaming?, false)
      |> assign(:streaming_buffer, "")
      |> assign(:streaming_index, nil)
      |> assign(:next_message_index, max(socket.assigns.next_message_index, err_view.index + 1))

    {:noreply, socket}
  end

  defp format_error(reason) do
    case reason do
      {:claude_sdk_error, %{__struct__: mod} = exception} ->
        "Claude SDK error (#{inspect(mod)}): #{Exception.message(exception)}"

      {:claude_sdk_error, other} ->
        "Claude SDK error: #{inspect(other, limit: 200)}"

      :timeout ->
        "The request timed out. Try again or check the Phoenix logs."

      other ->
        "Something went wrong: #{inspect(other, limit: 200)}"
    end
  end

  # ---- view ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} page_title="Boardroom">
      <div class="flex h-[calc(100dvh-7rem)] flex-col sm:h-[calc(100dvh-8rem)]">
        <.boardroom_header cost={@cost} email={@current_scope.user.email} />

        <section
          id="messages"
          phx-update="stream"
          phx-hook="ScrollToBottom"
          class="flex-1 space-y-3 overflow-y-auto px-1 py-2 sm:px-2"
        >
          <article id="msg-empty" class="only:flex hidden h-full flex-col items-center justify-center text-center text-base-content/60">
            <.icon name="hero-chat-bubble-left-right" class="size-10 text-primary/60" />
            <p class="mt-3 text-sm">The boardroom is open.</p>
            <p class="text-xs text-base-content/40">Say something to get started — Tracy's on the Stub adapter until you wire the real Claude.</p>
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
              "max-w-[85%] rounded-2xl px-3 py-2 text-sm leading-relaxed sm:max-w-[75%] sm:px-4 sm:py-3 sm:text-base",
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
                <% msg.role == :system -> %>
                  <div class="flex items-start gap-2">
                    <.icon name="hero-sparkles" class="mt-0.5 size-4 shrink-0 text-accent" />
                    <p class="whitespace-pre-wrap text-xs sm:text-sm">{msg.content}</p>
                  </div>
                <% true -> %>
                  <p class="whitespace-pre-wrap">{msg.content}</p>
              <% end %>
            </div>
          </article>
        </section>

        <.composer text={@composer} disabled?={@streaming?} />
      </div>
    </Layouts.app>
    """
  end

  attr :cost, :map, required: true
  attr :email, :string, required: true

  defp boardroom_header(assigns) do
    ~H"""
    <header class="mb-3 flex flex-col gap-3 sm:mb-4 sm:flex-row sm:items-end sm:justify-between">
      <div>
        <p class="text-xs font-medium uppercase tracking-wider text-base-content/50">Tracy</p>
        <h1 class="text-xl font-bold tracking-tight text-base-content sm:text-2xl">Boardroom</h1>
        <p class="mt-0.5 text-xs text-base-content/60">Signed in as {@email}</p>
      </div>

      <div class="rounded-box border border-base-300/60 bg-base-200/40 px-3 py-2 sm:max-w-xs">
        <div class="flex items-baseline justify-between gap-2">
          <span class="text-[10px] font-medium uppercase tracking-wider text-base-content/60">
            SDK pool
          </span>
          <span class="text-xs tabular-nums text-base-content/70">
            ${:io_lib.format(~c"~.2f", [@cost.spent_dollars])} / ${@cost.cap_dollars}
          </span>
        </div>
        <div
          class="mt-1.5 h-1.5 w-full overflow-hidden rounded-full bg-base-300/70"
          role="progressbar"
          aria-valuenow={trunc(@cost.pct)}
          aria-valuemin="0"
          aria-valuemax="100"
        >
          <div
            class={[
              "h-full transition-all",
              @cost.zone == :normal && "bg-success",
              @cost.zone == :caution && "bg-success",
              @cost.zone == :winddown && "bg-warning",
              @cost.zone == :hardstop && "bg-error"
            ]}
            style={"width: #{max(@cost.pct, 1.5)}%"}
          ></div>
        </div>
      </div>
    </header>
    """
  end

  attr :text, :string, required: true
  attr :disabled?, :boolean, default: false

  defp composer(assigns) do
    ~H"""
    <form
      phx-submit="send"
      phx-change="compose"
      class="sticky bottom-0 -mx-1 mt-2 flex items-end gap-2 border-t border-base-300/60 bg-base-100/80 px-1 pt-2 pb-1 backdrop-blur sm:-mx-2 sm:gap-3 sm:px-2 sm:pt-3"
    >
      <label for="composer" class="sr-only">Message</label>
      <textarea
        id="composer"
        name="composer"
        rows="1"
        placeholder={if @disabled?, do: "Tracy is thinking…", else: "Say something to Tracy…"}
        disabled={@disabled?}
        phx-hook="GrowComposer"
        phx-keydown={JS.dispatch("tracy:submit-on-enter")}
        phx-key="Enter"
        class="textarea textarea-bordered min-h-12 flex-1 resize-none bg-base-200/60 text-base"
      >{@text}</textarea>
      <button
        type="submit"
        disabled={@disabled? or @text == ""}
        class="btn btn-primary btn-square h-12 min-h-12 w-12 shrink-0 sm:btn-md"
        aria-label="Send"
      >
        <.icon name="hero-paper-airplane" class="size-5" />
      </button>
    </form>
    """
  end

  # ---- helpers ----

  defp derive_session_id(user) do
    # Stable per-user UUIDv5-ish derivation. For v1 a single fixed id per user is enough.
    # We use sha256-of-user-id-prefixed to keep it deterministic without pulling uuid_v5.
    raw = :crypto.hash(:sha256, "tracy-session:#{user.id}")
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = raw

    <<a::32, b::16, c::16, d::16, e::48>>
    |> Base.encode16(case: :lower)
    |> format_uuid()
  end

  defp format_uuid(<<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>>),
    do: "#{a}-#{b}-#{c}-#{d}-#{e}"

  defp to_view_message({%Tracy.LLM.Message{} = msg, index}) do
    %{
      index: index,
      role: msg.role,
      content: msg.content,
      streaming?: false,
      created_at: DateTime.utc_now()
    }
  end

end
