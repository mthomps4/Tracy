import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tracy start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tracy, TracyWeb.Endpoint, server: true
end

config :tracy, TracyWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# ----------------------------------------------------------------------------
# LLM adapter selection
# ----------------------------------------------------------------------------
# Set TRACY_LLM_ADAPTER=claude in your environment to route real Claude calls
# through `claude_agent_sdk` (which uses the OAuth session from
# `claude setup-token`). Otherwise, Tracy stays on the Stub adapter so dev
# and tests don't accidentally spend SDK credits.
#
# If you set TRACY_LLM_ADAPTER=claude, also CONFIRM that ANTHROPIC_API_KEY
# is NOT set in your environment — if it is, Claude Code prefers it over the
# OAuth token and bills at API rates (bypassing the Max plan SDK credit pool).
case System.get_env("TRACY_LLM_ADAPTER") do
  "claude" ->
    config :tracy, Tracy.LLM,
      adapter: Tracy.LLM.Claude,
      default_model: System.get_env("TRACY_CLAUDE_MODEL", "sonnet")

  _ ->
    # Stays on the Stub by default — config/config.exs already sets this.
    :ok
end

# ----------------------------------------------------------------------------
# Worker adapter selection
# ----------------------------------------------------------------------------
# TRACY_WORKERS_ADAPTER controls the default worker backend. When set to
# "claude", new dispatches spawn real `claude -p` subprocesses via
# Tracy.Workers.Claude. Otherwise Tracy.Workers.Stub stays the default —
# safe for tests, CI, and local iteration where you don't want to spend
# SDK credits on every "Dispatch" click.
#
# Per-role overrides can be added via :per_role in config (e.g. only the
# Engineer role uses real Claude while other roles stay Stub).
case System.get_env("TRACY_WORKERS_ADAPTER") do
  "claude" ->
    config :tracy, Tracy.Workers,
      default_adapter: Tracy.Workers.Claude,
      per_role: %{}

  _ ->
    config :tracy, Tracy.Workers,
      default_adapter: Tracy.Workers.Stub,
      per_role: %{}
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tracy, Tracy.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tracy, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tracy, TracyWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tracy, TracyWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tracy, TracyWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
