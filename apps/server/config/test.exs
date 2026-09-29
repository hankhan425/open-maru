import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :openmaru, Openmaru.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "openmaru_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :openmaru, OpenmaruWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YV2rAgbUQ7fehb6tgpSJctFplrydHXOhT8BdHVaQwog+Z5MC9Uk2JqlfoByr2Gtu",
  server: false

# Mox mocks (defined in test/test_helper.exs) replace these implementations.
config :openmaru, clock: Openmaru.ClockMock, health: Openmaru.HealthMock

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
