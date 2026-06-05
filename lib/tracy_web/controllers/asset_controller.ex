defmodule TracyWeb.AssetController do
  @moduledoc """
  Serves an asset's binary content. Authenticated; requires the requester
  to be a logged-in user (single-user system for now — every signed-in
  user can read every asset).
  """
  use TracyWeb, :controller

  alias Tracy.Assets

  def download(conn, %{"id" => id}) do
    case Assets.get_asset(id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> text("Asset not found")

      %Tracy.Assets.Asset{kind: kind} when kind in ["link", "note"] ->
        conn
        |> put_status(:bad_request)
        |> text("This asset has no binary content. Open it from the plan page.")

      asset ->
        disposition =
          case get_format(conn) do
            "inline" -> "inline"
            _ -> ~s(attachment; filename="#{asset.filename}")
          end

        conn
        |> put_resp_content_type(asset.content_type, nil)
        |> put_resp_header("content-disposition", disposition)
        |> send_resp(200, asset.data || <<>>)
    end
  end
end
