defmodule TracyWeb.TaskLive.ShowTest do
  use TracyWeb.ConnCase, async: true

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
end
