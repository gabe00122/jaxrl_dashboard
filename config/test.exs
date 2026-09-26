import Config

# Only in tests, make password hashing cheap
config :argon2_elixir, t_cost: 1, m_cost: 8

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :jaxrl_dashboard, JaxrlDashboard.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "jaxrl_dashboard_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :jaxrl_dashboard, JaxrlDashboardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "oVN3fiR3ihq7GKoDGGr8gphY2QL/iGJ3qam/+2qwJ+Sy+ZLeN20QZ6q4Y+zD0jIS",
  server: false

# Validation against the real Python models is tested in
# python_validator_test.exs; everything else uses a fake.
config :jaxrl_dashboard, :config_validator, JaxrlDashboard.FakeConfigValidator

# Tests start the scheduler themselves, against a fake training script.
config :jaxrl_dashboard, :runs,
  train_command: ["bash", Path.expand("../test/support/fake_train.sh", __DIR__)],
  poll_interval: 20,
  watch_interval: 20,
  kill_grace_period: 2_000,
  start_scheduler: false

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
