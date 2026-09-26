# Refreshes the schema snapshot the tests use after jaxrl's config models
# change:  mix run priv/python/dump_schema.exs
alias JaxrlDashboard.Configs.PythonValidator

{:ok, _} = PythonValidator.start_link([])
{:ok, schema} = PythonValidator.schema()
path = "test/support/fixtures/config_schema.json"
File.write!(path, Jason.encode_to_iodata!(schema, pretty: true))
IO.puts("Wrote #{path}")
