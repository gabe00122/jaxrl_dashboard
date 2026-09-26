# Tests tagged :jaxrl run the real config validator with jaxrl's Python;
# they're skipped where the jaxrl project and its venv aren't around.
alias JaxrlDashboard.Runs.Settings

jaxrl_python = Path.expand(Settings.get(:python), Settings.project_dir())
ExUnit.start(exclude: if(File.exists?(jaxrl_python), do: [], else: [:jaxrl]))
Ecto.Adapters.SQL.Sandbox.mode(JaxrlDashboard.Repo, :manual)
