import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tracy, Tracy.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tracy_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tracy, TracyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "qhlwDeGSqWTBOk36zpBe0/zIJtkoBGuFikw1ImVhw1Jna5nnk0omw6nrGHBPC8HU",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests keep the Stub embedder — Nomic's first-call model load would
# add 5-30s to the first test that touches Memory, and the Stub returns
# deterministic vectors anyway.
config :tracy, Tracy.Memory.Embeddings,
  provider: Tracy.Memory.Embeddings.Stub

# Tests stay on the BinaryBackend — EXLA isn't needed for deterministic
# Stub vectors, and BinaryBackend boots instantly.
config :nx, default_backend: Nx.BinaryBackend

# No prewarm in test — Stub doesn't need a model.
config :tracy, :prewarm_embedder, false
