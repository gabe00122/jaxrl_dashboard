defmodule Mix.Tasks.Dashboard.ImportRuns do
  @shortdoc "Imports runs trained outside the dashboard from the jaxrl results dir"
  @moduledoc """
  Adds every run in the jaxrl results directory that the dashboard doesn't
  know about yet, so its config and metrics can be browsed. Safe to re-run.

      $ mix dashboard.import_runs
  """
  use Mix.Task

  alias JaxrlDashboard.Runs

  @impl true
  def run(_args) do
    Mix.Dashboard.start_app()

    {imported, skipped} = Runs.import_existing_runs()

    Mix.shell().info("Imported #{length(imported)} runs.")

    for {name, reason} <- skipped do
      Mix.shell().info("  skipped #{name}: #{reason}")
    end
  end
end
