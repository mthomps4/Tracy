defmodule TracyWeb.PlanLiveTest do
  use TracyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias Tracy.Plans

  describe "GET /plans/:id (auth)" do
    test "redirects to log-in when not authenticated", %{conn: conn} do
      {:ok, plan} = Plans.create_plan(%{title: "anything"})
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/plans/#{plan.id}")
    end
  end

  describe "GET /plans/:id (signed in)" do
    setup %{conn: conn} do
      user = user_fixture()
      {:ok, plan} = Plans.create_plan(%{title: "My plan", project: "tracy", brief: "Some brief"})
      %{conn: log_in_user(conn, user), user: user, plan: plan}
    end

    test "renders title, project, brief", %{conn: conn, plan: plan} do
      {:ok, _view, html} = live(conn, ~p"/plans/#{plan.id}")
      assert html =~ "My plan"
      assert html =~ "tracy"
      assert html =~ "Some brief"
    end

    test "missing plan redirects to /plans", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/plans"}}} =
               live(conn, ~p"/plans/#{missing_id}")
    end

    test "transitioning a plan updates the UI", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}")

      # Open the transition menu and pick backlog
      view |> element("button[phx-click='toggle_transition_menu']") |> render_click()
      view |> element("button[phx-value-to='backlog']") |> render_click()

      html = render(view)
      assert html =~ "Backlog"
    end

    test "adding a task appends it to the list", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}")

      view
      |> form("form[phx-submit='create_task']",
        new_task: %{title: "Investigate the bug", role: "researcher"}
      )
      |> render_submit()

      html = render(view)
      assert html =~ "Investigate the bug"
      assert html =~ "researcher"
    end

    test "transitioning a task marks it done", %{conn: conn, plan: plan} do
      {:ok, _t} = Plans.create_task(%{plan_id: plan.id, title: "do this", role: "engineer"})

      {:ok, view, _html} = live(conn, ~p"/plans/#{plan.id}")
      view |> element("button[phx-click='toggle_task_menu']") |> render_click()
      view |> element("button[phx-value-to='done']") |> render_click()

      html = render(view)
      assert html =~ "do this"
      assert html =~ "Done"
    end
  end
end
