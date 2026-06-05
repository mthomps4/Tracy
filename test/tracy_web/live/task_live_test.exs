defmodule TracyWeb.TaskLive.ShowTest do
  # async: false — the Live tab dispatches Tracy.Workers.Server processes
  # which write to the DB from outside the test pid. Shared sandbox needs
  # serial tests.
  use TracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias Tracy.Plans

  describe "GET /plans/:plan_id/tasks/:id (auth)" do
    test "redirects to log-in when not authenticated", %{conn: conn} do
      {:ok, plan} = Plans.create_plan(%{title: "anything"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "do thing", role: "engineer"})

      assert {:error, {:redirect, %{to: "/users/log-in"}}} =
               live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}")
    end
  end

  describe "GET /plans/:plan_id/tasks/:id (signed in)" do
    setup %{conn: conn} do
      user = user_fixture()
      {:ok, plan} = Plans.create_plan(%{title: "My plan", project: "tracy"})

      {:ok, task} =
        Plans.create_task(%{
          plan_id: plan.id,
          title: "Investigate the bug",
          role: "engineer",
          brief: "The bug appears intermittently when X happens."
        })

      %{conn: log_in_user(conn, user), user: user, plan: plan, task: task}
    end

    test "renders title, brief, role, and activity stream", %{conn: conn, plan: plan, task: task} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}")

      assert html =~ "Investigate the bug"
      assert html =~ "The bug appears intermittently"
      assert html =~ "engineer"
      assert html =~ "Activity"
      assert html =~ "Task created"
      assert html =~ "Comments"
    end

    test "missing task redirects to plan", %{conn: conn, plan: plan} do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/plans/#{plan.id}/tasks/#{missing_id}")

      assert to == "/plans/#{plan.id}"
    end

    test "task on the wrong plan path bounces to canonical URL", %{conn: conn, plan: plan, task: task} do
      {:ok, other_plan} = Plans.create_plan(%{title: "wrong one"})

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, ~p"/plans/#{other_plan.id}/tasks/#{task.id}")

      assert to == "/plans/#{plan.id}/tasks/#{task.id}"
    end

    test "transitioning from the detail view updates UI", %{conn: conn, plan: plan, task: task} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}")

      view |> element("button[phx-click='toggle_transition_menu']") |> render_click()
      view |> element("button[phx-value-to='in_review']") |> render_click()

      assert render(view) =~ "In Review"
    end

    test "brief tab task row links to the detail view", %{conn: conn, plan: plan, task: task} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}")
      assert html =~ ~s(/plans/#{plan.id}/tasks/#{task.id})
    end
  end

  describe "Live tab" do
    setup %{conn: conn} do
      user = user_fixture()
      {:ok, plan} = Plans.create_plan(%{title: "live plan"})

      {:ok, task} =
        Plans.create_task(%{plan_id: plan.id, title: "watch me", role: "engineer"})

      %{conn: log_in_user(conn, user), plan: plan, task: task}
    end

    test "tab bar renders Details + Live", %{conn: conn, plan: plan, task: task} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}")
      assert html =~ "Details"
      assert html =~ "Live"
    end

    test "Live tab shows empty-state when worker has never run", %{conn: conn, plan: plan, task: task} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}?tab=live")
      assert html =~ "No live transcript"
      # No cancel button when not running.
      refute html =~ "phx-click=\"cancel_worker\""
    end

    test "Live tab shows the Cancel button while the worker is running", %{conn: conn, plan: plan, task: task} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}?tab=live")

      # Dispatch directly via API with a slow delay so the cancel button
      # is observable. The LiveView is subscribed to worker:<task_id> and
      # will receive :worker_started → renders the Cancel button.
      Tracy.Workers.dispatch(task.id,
        adapter: Tracy.Workers.Stub,
        adapter_opts: [delay_ms: 2_000]
      )

      eventually(fn -> render(view) =~ "phx-click=\"cancel_worker\"" end)
      assert render(view) =~ "Cancel"
    end

    test "cancel_worker event transitions the task to canceled", %{conn: conn, plan: plan, task: task} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}/tasks/#{task.id}?tab=live")

      Tracy.Workers.dispatch(task.id,
        adapter: Tracy.Workers.Stub,
        adapter_opts: [delay_ms: 5_000]
      )

      eventually(fn -> render(view) =~ "phx-click=\"cancel_worker\"" end)

      view |> element("button[phx-click='cancel_worker']") |> render_click()

      eventually(fn -> render(view) =~ "Canceled" end)
    end
  end

  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_poll = fn poll ->
      cond do
        fun.() ->
          true

        System.monotonic_time(:millisecond) < deadline ->
          Process.sleep(20)
          poll.(poll)

        true ->
          false
      end
    end

    assert do_poll.(do_poll)
  end
end
