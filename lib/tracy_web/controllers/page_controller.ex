defmodule TracyWeb.PageController do
  use TracyWeb, :controller

  @doc """
  Home — if you're logged in, you go straight to the boardroom (chat is
  the front door). If you're not, the marketing landing welcomes you
  and points at the login.
  """
  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: "/boardroom")
    else
      render(conn, :home)
    end
  end

  def boardroom(conn, _params) do
    render(conn, :boardroom)
  end
end
