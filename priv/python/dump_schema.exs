# Refreshes the schema snapshots the tests use after a project's config
# models change:  mix run --no-start priv/python/dump_schema.exs
# (Started like the mix dashboard.* tasks: with a validator per project, and
# without the scheduler, which would launch queued runs.)
alias JaxrlDashboard.Configs.PythonValidator
alias JaxrlDashboard.Projects

Mix.Dashboard.start_app()

for project <- Projects.list() do
  {:ok, schema} = PythonValidator.schema(project)
  path = "test/support/fixtures/#{project.id}_config_schema.json"
  File.write!(path, Jason.encode_to_iodata!(schema, pretty: true))
  IO.puts("Wrote #{path}")
end
