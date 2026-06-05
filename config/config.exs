# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tracy, :scopes,
  user: [
    default: true,
    module: Tracy.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Tracy.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :tracy,
  ecto_repos: [Tracy.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Register the pgvector Postgrex extension so the `vector` column type works in Ecto.
config :tracy, Tracy.Repo, types: Tracy.PostgresTypes

# Default LLM adapter. Stub for dev/test/CI; flip to Tracy.LLM.Claude in
# runtime.exs once `claude setup-token` has produced an OAuth token.
config :tracy, Tracy.LLM,
  adapter: Tracy.LLM.Stub,
  default_model: "stub"

# Swoosh: local-only mail in dev (/dev/mailbox), no SMTP. Prod adapter set in runtime.exs if/when needed.
config :tracy, Tracy.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

# Configure the endpoint
config :tracy, TracyWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TracyWeb.ErrorHTML, json: TracyWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tracy.PubSub,
  live_view: [signing_salt: "tVv0XRZ6"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tracy: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  tracy: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
