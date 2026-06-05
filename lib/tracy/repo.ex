defmodule Tracy.Repo do
  use Ecto.Repo,
    otp_app: :tracy,
    adapter: Ecto.Adapters.Postgres
end
