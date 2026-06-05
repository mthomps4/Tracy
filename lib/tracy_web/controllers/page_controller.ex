defmodule TracyWeb.PageController do
  use TracyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
