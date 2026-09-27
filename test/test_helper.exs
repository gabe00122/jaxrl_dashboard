# Tests tagged with a project's id (:jaxrl, :llm_rl) run the real config
# validator with that project's Python; they're skipped where the project and
# its venv aren't around.
alias JaxrlDashboard.Projects
alias JaxrlDashboard.Projects.Project

missing =
  for project <- Projects.list(),
      not File.exists?(Project.python_path(project)),
      do: String.to_atom(project.id)

ExUnit.start(exclude: missing)
Ecto.Adapters.SQL.Sandbox.mode(JaxrlDashboard.Repo, :manual)
