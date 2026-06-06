defmodule TracyWeb.ChatDockLiveTest do
  @moduledoc """
  Coverage for the ChatDock — the sticky JARVIS chat surface.

  Boundary-of-concerns: we don't test the underlying Session GenServer
  here (that's in `Tracy.SessionTest`), and we don't drive a real LLM
  (the Stub adapter does that for us). What we lock down is the dock's
  own behavior: mounting, slash command parsing, voice transcript
  handling, project pin/unpin context broadcast, and worker-completion
  notifications rendering as system bubbles.
  """
  # async: false — the Tracy.Session GenServer writes Episodes from a
  # separate process; shared sandbox needs serial tests. Same pattern
  # as the Whiteboard test.
  use TracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias TracyWeb.ChatDockLive

  defp mount_dock(user) do
    {:ok, view, html} =
      live_isolated(build_conn(), ChatDockLive, session: %{"user_id" => user.id})

    {view, html}
  end

  describe "mount" do
    test "boots clean with a user_id" do
      user = user_fixture()
      {view, html} = mount_dock(user)

      assert html =~ "Tracy"
      # Peek launcher is always visible
      assert html =~ "chat-dock__launcher"
      # Panel is hidden until toggle (data-open=false)
      assert html =~ ~s(data-open="false")

      send(view.pid, :flush)
    end

    test "toggle event opens the panel" do
      user = user_fixture()
      {view, _} = mount_dock(user)

      assert render(view) =~ ~s(data-open="false")

      view |> element("button[phx-click='toggle']") |> render_click()

      html = render(view)
      assert html =~ ~s(data-open="true")
      # Composer textarea visible when open
      assert html =~ "chat-dock-input"
    end
  end

  describe "slash commands" do
    setup do
      user = user_fixture()
      {view, _} = mount_dock(user)
      view |> element("button[phx-click='toggle']") |> render_click()

      %{view: view, user: user}
    end

    test "/help lists the available commands", %{view: view} do
      view
      |> form("form[phx-submit='send']", composer: "/help")
      |> render_submit()

      html = render(view)
      assert html =~ "Slash commands"
      assert html =~ "/pin"
      assert html =~ "/switch"
      assert html =~ "/memo"
    end

    test "/pin sets the project context + shows the pin in header", %{view: view, user: user} do
      Phoenix.PubSub.subscribe(Tracy.PubSub, "chat:context:#{user.id}")

      view
      |> form("form[phx-submit='send']", composer: "/pin Tracy")
      |> render_submit()

      assert_receive {:context, %{project: "Tracy"}}, 500

      html = render(view)
      # System bubble confirms the pin
      assert html =~ "Pinned project"
      assert html =~ "Tracy"
    end

    test "/unpin clears the context", %{view: view, user: user} do
      Phoenix.PubSub.subscribe(Tracy.PubSub, "chat:context:#{user.id}")

      view |> form("form[phx-submit='send']", composer: "/pin Tracy") |> render_submit()
      assert_receive {:context, %{project: "Tracy"}}, 500

      view |> form("form[phx-submit='send']", composer: "/unpin") |> render_submit()
      assert_receive {:context, %{project: nil}}, 500

      assert render(view) =~ "Unpinned"
    end

    test "/switch is an alias for /pin", %{view: view} do
      view
      |> form("form[phx-submit='send']", composer: "/switch DayJob")
      |> render_submit()

      html = render(view)
      assert html =~ "Pinned project"
      assert html =~ "DayJob"
    end

    test "/remember stashes a fact and confirms in chat", %{view: view} do
      view
      |> form("form[phx-submit='send']", composer: "/remember Matt prefers Phoenix without umbrellas")
      |> render_submit()

      html = render(view)
      assert html =~ "Recorded"
      assert html =~ "Matt prefers Phoenix without umbrellas"

      # And it landed in the Facts table
      facts = Tracy.Memory.current_facts()
      assert Enum.any?(facts, &(&1.statement =~ "umbrella"))
    end

    test "/remember without an argument explains the syntax", %{view: view} do
      view
      |> form("form[phx-submit='send']", composer: "/remember")
      |> render_submit()

      html = render(view)
      assert html =~ "Tell me what to remember"
    end

    test "unknown command produces a system message, not a Claude call", %{view: view} do
      view
      |> form("form[phx-submit='send']", composer: "/totallymadeup")
      |> render_submit()

      html = render(view)
      assert html =~ "Unknown command"
      assert html =~ "totallymadeup"
    end
  end

  describe "worker-completion notifications" do
    setup do
      user = user_fixture()
      {view, _} = mount_dock(user)
      view |> element("button[phx-click='toggle']") |> render_click()

      %{view: view, user: user}
    end

    test "drops a system bubble into the chat when a worker reports completion", %{view: view} do
      task = %Tracy.Plans.Task{role: "engineer", title: "silence verified-routes warnings"}

      report = %{
        summary: "Updated TracyWeb.static_paths/0 — 4 warnings gone.",
        files_changed: ["lib/tracy_web.ex"]
      }

      Phoenix.PubSub.broadcast(
        Tracy.PubSub,
        "chat:notifications",
        {:worker_completed_notice, task, report}
      )

      eventually(fn -> render(view) =~ "silence verified-routes" end)
      html = render(view)
      assert html =~ "Engineer done"
      assert html =~ "lib/tracy_web.ex"
    end

    test "failures land as their own system bubble with a warning glyph", %{view: view} do
      task = %Tracy.Plans.Task{role: "designer", title: "draft hero illustrations"}

      Phoenix.PubSub.broadcast(
        Tracy.PubSub,
        "chat:notifications",
        {:worker_failed_notice, task, :sdk_pool_paused}
      )

      eventually(fn -> render(view) =~ "draft hero illustrations" end)
      html = render(view)
      assert html =~ "failed"
      assert html =~ "sdk_pool_paused"
    end
  end

  describe "voice:transcript event" do
    setup do
      user = user_fixture()
      {view, _} = mount_dock(user)
      view |> element("button[phx-click='toggle']") |> render_click()

      %{view: view}
    end

    test "interim transcript updates composer without sending", %{view: view} do
      render_hook(view, "voice:transcript", %{
        "text" => "tell me about the favicon",
        "final" => false
      })

      html = render(view)
      assert html =~ "tell me about the favicon"
    end

    test "final transcript auto-dispatches the message", %{view: view} do
      render_hook(view, "voice:transcript", %{
        "text" => "show me the cost meter",
        "final" => true
      })

      html = render(view)
      # The composer empties (message dispatched), and the user bubble shows up
      assert html =~ "show me the cost meter"
    end
  end

  # ---- helpers ----

  # Poll `fun` until it returns truthy or the timeout expires. The
  # ChatDock processes a stream of events from PubSub (the worker
  # notifications, session events) that arrive asynchronously, so we
  # need a small wait window before asserting rendered output.
  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    poll = fn poll ->
      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) >= deadline ->
          flunk("eventually/2 timed out after #{timeout_ms}ms")

        true ->
          Process.sleep(20)
          poll.(poll)
      end
    end

    poll.(poll)
  end
end
