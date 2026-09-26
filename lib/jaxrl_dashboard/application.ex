defmodule JaxrlDashboard.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        JaxrlDashboardWeb.Telemetry,
        JaxrlDashboard.Repo,
        {DNSCluster, query: Application.get_env(:jaxrl_dashboard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: JaxrlDashboard.PubSub},
        JaxrlDashboard.RateLimiter,
        {Registry, keys: :unique, name: JaxrlDashboard.Runs.WatcherRegistry},
        {DynamicSupervisor, name: JaxrlDashboard.Runs.WatcherSupervisor, strategy: :one_for_one}
      ] ++
        config_validator() ++
        scheduler() ++
        [
          # Start to serve requests, typically the last entry
          JaxrlDashboardWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: JaxrlDashboard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp config_validator do
    case Application.fetch_env!(:jaxrl_dashboard, :config_validator) do
      JaxrlDashboard.Configs.PythonValidator = validator -> [validator]
      _fake -> []
    end
  end

  defp scheduler do
    if JaxrlDashboard.Runs.Settings.get(:start_scheduler),
      do: [JaxrlDashboard.Runs.Scheduler],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    JaxrlDashboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
