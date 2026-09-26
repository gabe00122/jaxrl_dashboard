defmodule JaxrlDashboard.Repo do
  use Ecto.Repo,
    otp_app: :jaxrl_dashboard,
    adapter: Ecto.Adapters.Postgres
end
