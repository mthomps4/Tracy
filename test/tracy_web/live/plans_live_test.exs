defmodule TracyWeb.PlansLiveTest do
  use TracyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias Tracy.Plans

  describe "GET /plans (auth)" do
    test "redirects to log-in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/plans")
    end
  end

  describe "GET /plans (signed in)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "renders the header and empty-state when no plans exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/plans")
      assert html =~ "Plans"
      assert html =~ "0 plans"
    end

    test "shows plans grouped by status", %{conn: conn} do
      {:ok, _} = Plans.create_plan(%{title: "Triage thing"})
      {:ok, p} = Plans.create_plan(%{title: "Working on it"})
      {:ok, _} = Plans.transition_plan(p, "in_progress")

      {:ok, _view, html} = live(conn, ~p"/plans")
      assert html =~ "Triage thing"
      assert html =~ "Working on it"
      assert html =~ "Triage"
      assert html =~ "In Progress"
    end

    test "toggle_terminal flips done/canceled visibility", %{conn: conn} do
      {:ok, p} = Plans.create_plan(%{title: "Finished thing"})
      {:ok, _} = Plans.transition_plan(p, "done")

      {:ok, view, html} = live(conn, ~p"/plans")
      refute html =~ "Finished thing"

      html_after = view |> element("button", "Show done") |> render_click()
      assert html_after =~ "Finished thing"
    end

    test "navigates to the detail page", %{conn: conn} do
      {:ok, _plan} = Plans.create_plan(%{title: "Drill-down"})

      {:ok, view, _html} = live(conn, ~p"/plans")
      {:ok, _detail_view, detail_html} =
        view |> element("a", "Drill-down") |> render_click() |> follow_redirect(conn)

      assert detail_html =~ "Drill-down"
    end
  end
end
