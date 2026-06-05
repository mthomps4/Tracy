defmodule TracyWeb.PageController do
  use TracyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def boardroom(conn, _params) do
    render(conn, :boardroom)
  end
end
