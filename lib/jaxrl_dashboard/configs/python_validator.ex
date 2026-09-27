defmodule JaxrlDashboard.Configs.PythonValidator do
  @moduledoc """
  Runs a project's validator script (`priv/python/<project>_config_validator.py`,
  see `c:JaxrlDashboard.Projects.Adapter.validator_script/0`) with that
  project's Python and keeps it running, since importing the config models
  (and, for jaxrl, JAX) takes a moment. There's one of these per project.
  Requests are answered in order over a length-prefixed JSON pipe; the
  process is started on first use and again if it dies.
  """

  @behaviour JaxrlDashboard.Configs.Validator

  use GenServer
  require Logger

  alias JaxrlDashboard.Projects
  alias JaxrlDashboard.Projects.Project

  @registry JaxrlDashboard.Configs.ValidatorRegistry
  @call_timeout 20_000

  @doc "A child spec per project, for the application supervisor."
  def child_specs do
    [{Registry, keys: :unique, name: @registry}] ++
      for id <- Projects.ids(), do: Supervisor.child_spec({__MODULE__, id}, id: {__MODULE__, id})
  end

  def start_link(project_id),
    do: GenServer.start_link(__MODULE__, project_id, name: via(project_id))

  defp via(project_id), do: {:via, Registry, {@registry, project_id}}

  @impl JaxrlDashboard.Configs.Validator
  def schema(%Project{} = project) do
    with {:ok, response} <- request(project, %{cmd: "schema"}) do
      {:ok, Map.take(response, ["config", "environments"])}
    end
  end

  @impl JaxrlDashboard.Configs.Validator
  def validate(%Project{} = project, config) do
    with {:ok, %{"errors" => errors}} <- request(project, %{cmd: "validate", config: config}) do
      {:ok, Enum.map(errors, &%{path: &1["loc"], message: &1["msg"]})}
    end
  end

  @impl JaxrlDashboard.Configs.Validator
  def format(%Project{} = project, config) do
    with {:ok, %{"json" => json}} <- request(project, %{cmd: "format", config: config}) do
      {:ok, json}
    end
  end

  defp request(%Project{id: id}, request) do
    GenServer.call(via(id), {:request, request}, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, "the config validator didn't answer in time"}
    :exit, {:noproc, _} -> {:error, "the config validator isn't running"}
  end

  @impl GenServer
  def init(project_id) do
    # The schema can't change while the project's code is loaded, so it's cached.
    {:ok, %{project_id: project_id, port: nil, waiting: :queue.new(), schema: nil}}
  end

  @impl GenServer
  def handle_call({:request, %{cmd: "schema"}}, _from, %{schema: schema} = state)
      when schema != nil do
    {:reply, {:ok, schema}, state}
  end

  def handle_call({:request, request}, from, state) do
    case ensure_port(state) do
      {:ok, state} ->
        Port.command(state.port, Jason.encode_to_iodata!(request))
        {:noreply, %{state | waiting: :queue.in({from, request.cmd}, state.waiting)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {{:value, {from, cmd}}, waiting} = :queue.out(state.waiting)
    state = %{state | waiting: waiting}

    case Jason.decode!(data) do
      %{"ok" => true} = response ->
        GenServer.reply(from, {:ok, response})
        {:noreply, if(cmd == "schema", do: %{state | schema: response}, else: state)}

      %{"error" => error} ->
        Logger.error("Config validator error (#{state.project_id}): #{error}")
        GenServer.reply(from, {:error, "the config validator failed: #{last_line(error)}"})
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Config validator for #{state.project_id} exited with status #{status}")

    for {from, _cmd} <- :queue.to_list(state.waiting) do
      GenServer.reply(from, {:error, "the config validator exited (status #{status})"})
    end

    {:noreply, %{state | port: nil, waiting: :queue.new()}}
  end

  defp ensure_port(%{port: port} = state) when port != nil, do: {:ok, state}

  defp ensure_port(state) do
    project = Projects.get!(state.project_id)
    python = Project.python_path(project)

    script =
      Application.app_dir(
        :jaxrl_dashboard,
        Path.join("priv/python", project.adapter.validator_script())
      )

    if File.exists?(python) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          packet: 4,
          args: [script],
          cd: project.dir,
          # No __pycache__ in priv/ for the shared validator_server module.
          env: [{~c"JAX_PLATFORMS", ~c"cpu"}, {~c"PYTHONDONTWRITEBYTECODE", ~c"1"}]
        ])

      {:ok, %{state | port: port}}
    else
      {:error, "#{project.label}'s Python wasn't found at #{python}"}
    end
  end

  defp last_line(text), do: text |> String.trim() |> String.split("\n") |> List.last()
end
