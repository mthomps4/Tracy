defmodule TracyWeb.PageControllerTest do
  use TracyWeb.ConnCase

  describe "GET /" do
    test "renders the public landing page with brand + auth CTAs", %{conn: conn} do
      conn = get(conn, ~p"/")
      body = html_response(conn, 200)
      assert body =~ "tracy"
      assert body =~ "personal ai dev orchestrator"
      assert body =~ "Register"
      assert body =~ "Log in"
    end
  end

  describe "GET /boardroom" do
    import Tracy.AccountsFixtures, only: [user_fixture: 0]

    test "requires authentication", %{conn: conn} do
      conn = get(conn, ~p"/boardroom")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "renders the boardroom when logged in", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/boardroom")
      body = html_response(conn, 200)
      assert body =~ "Boardroom"
      assert body =~ "Tracy"
      assert body =~ user.email
    end
  end
end
