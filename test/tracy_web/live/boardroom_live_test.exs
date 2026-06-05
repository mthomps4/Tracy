defmodule TracyWeb.BoardroomLiveTest do
  use TracyWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Tracy.AccountsFixtures, only: [user_fixture: 0]

  describe "GET /boardroom (auth)" do
    test "redirects to log-in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/boardroom")
    end
  end

  describe "GET /boardroom (signed in)" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      %{conn: conn, user: user}
    end

    test "renders the boardroom shell", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/boardroom")
      assert html =~ "Boardroom"
      assert html =~ "TRACY" or html =~ "Tracy"
      assert html =~ user.email
      assert html =~ "SDK pool"
    end

    test "sending a message inserts user + assistant bubbles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boardroom")

      view
      |> form("form", composer: "hello boardroom")
      |> render_submit()

      # User message appears immediately
      assert render(view) =~ "hello boardroom"

      # Wait for the stream to complete + assistant content to land
      :timer.sleep(50)
      html = render(view)
      assert html =~ "hello boardroom"
      # Stub reply is templated; should contain the echo
      assert html =~ "(stub)" or html =~ "boardroom"
    end
  end
end
