defmodule TracyWeb.BoardroomSlashCommandsTest do
  use TracyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  alias Tracy.Plans

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "/save-as-plan" do
    test "creates a triage plan and confirms in chat", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boardroom")

      view
      |> form("form", composer: "/save-as-plan Test designer brief")
      |> render_submit()

      html = render(view)
      assert html =~ "Saved as plan"
      assert html =~ "Test designer brief"

      plans = Plans.list_plans_by_status() |> Map.get("triage")
      assert Enum.any?(plans, &(&1.title == "Test designer brief"))
    end

    test "defaults the title to the last user message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boardroom")

      view |> form("form", composer: "Plan the marketing site update") |> render_submit()
      # Stub responds instantly; small wait for the :done event to land.
      :timer.sleep(50)
      view |> form("form", composer: "/save-as-plan") |> render_submit()

      plans = Plans.list_plans_by_status() |> Map.get("triage")
      assert Enum.any?(plans, &String.contains?(&1.title, "marketing site"))
    end
  end

  describe "/help" do
    test "lists available commands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boardroom")
      view |> form("form", composer: "/help") |> render_submit()

      html = render(view)
      assert html =~ "/save-as-plan"
      assert html =~ "/help"
    end
  end

  describe "unknown commands" do
    test "shows a system note", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boardroom")
      view |> form("form", composer: "/nope") |> render_submit()

      html = render(view)
      assert html =~ "Unknown command"
    end
  end
end
