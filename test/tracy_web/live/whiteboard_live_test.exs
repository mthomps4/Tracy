defmodule TracyWeb.WhiteboardLiveTest do
  # async: false — the Whiteboard mounts a Tracy.Session GenServer which
  # writes Episodes from a separate process. Shared sandbox handles it but
  # keep the test serial to avoid cross-test session id collisions.
  use TracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias Tracy.Plans

  # Poll `fun` (must return truthy/falsy) until it passes or timeout fires.
  # The Stub LLM's streaming `:done` event lands via PubSub from a Task —
  # there's a brief window between `render_submit` returning and the
  # assistant content being rendered.
  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_poll = fn poll ->
      if fun.() do
        true
      else
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          poll.(poll)
        else
          false
        end
      end
    end

    do_poll.(do_poll)
  end

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, plan} = Plans.create_plan(%{title: "Whiteboard plan", project: "tracy"})
    %{conn: log_in_user(conn, user), plan: plan}
  end

  describe "Whiteboard tab" do
    test "live_renders inside the Whiteboard tab", %{conn: conn, plan: plan} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}?tab=whiteboard")
      assert html =~ "Whiteboard"
      assert html =~ "planning chat scoped to this plan"
      assert html =~ "Think out loud about this plan"
    end

    test "is NOT rendered when a different tab is active", %{conn: conn, plan: plan} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}?tab=tasks")
      refute html =~ "planning chat scoped to this plan"
    end

    test "sending a message renders user + assistant bubbles", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}?tab=whiteboard")

      wb = find_live_child(view, "whiteboard-#{plan.id}")

      wb
      |> form("form[phx-submit='send']", composer: "design the brand mark")
      |> render_submit()

      assert render(wb) =~ "design the brand mark"

      # The Stub LLM emits chunks via PubSub from a Task; wait for the
      # `:done` event to reach the LiveView and flip the streaming bubble.
      assert eventually(fn -> render(wb) =~ "heard you on" end)
    end
  end
end
