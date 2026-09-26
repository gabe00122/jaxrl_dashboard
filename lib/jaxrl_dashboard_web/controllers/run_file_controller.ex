defmodule JaxrlDashboardWeb.RunFileController do
  use JaxrlDashboardWeb, :controller

  alias JaxrlDashboard.{Metrics, Runs}
  alias JaxrlDashboard.Runs.Settings

  @doc """
  Downloads one of a run's raw files. Only these names are served, and the
  run must exist, so the path can't be steered anywhere else.
  """
  def show(conn, %{"name" => name, "file" => file}) do
    run = Runs.get_run_by_name!(name)

    path =
      case file do
        "logs.jsonl" -> Metrics.path(run.name)
        "output.log" -> Settings.output_path(run.name)
        _ -> nil
      end

    if path && File.regular?(path) do
      send_download(conn, {:file, path},
        filename: "#{run.name}-#{file}",
        content_type: "text/plain"
      )
    else
      conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
