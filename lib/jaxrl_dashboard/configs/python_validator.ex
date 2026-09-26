defmodule JaxrlDashboard.Configs.PythonValidator do
  @moduledoc """
  Runs `priv/python/config_validator.py` with the jaxrl project's Python and
  keeps it running, since importing jaxrl's config models (and with them JAX)
  takes a moment. Requests are answered in order over a length-prefixed JSON
  pipe; the process is started on first use and again if it dies.
  """

  @behaviour JaxrlDashboard.Configs.Validator

  use GenServer
  require Logger

  alias JaxrlDashboard.Runs.Settings

  @call_timeout 20_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl JaxrlDashboard.Configs.Validator
  def schema do
    with {:ok, response} <- request(%{cmd: "schema"}) do
      {:ok, Map.take(response, ["config", "environments"])}
    end
  end

  @impl JaxrlDashboard.Configs.Validator
  def validate(config) do
    with {:ok, %{"errors" => errors}} <- request(%{cmd: "validate", config: config}) do
      {:ok, Enum.map(errors, &%{path: &1["loc"], message: &1["msg"]})}
    end
  end

  @impl JaxrlDashboard.Configs.Validator
  def format(config) do
    with {:ok, %{"json" => json}} <- request(%{cmd: "format", config: config}) do
      {:ok, json}
    end
  end

  defp request(request) do
    GenServer.call(__MODULE__, {:request, request}, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, "the config validator didn't answer in time"}
    :exit, {:noproc, _} -> {:error, "the config validator isn't running"}
  end

  @impl GenServer
  def init(nil) do
    # The schema can't change while the jaxrl code is loaded, so it's cached.
    {:ok, %{port: nil, waiting: :queue.new(), schema: nil}}
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
        Logger.error("Config validator error: #{error}")
        GenServer.reply(from, {:error, "the config validator failed: #{last_line(error)}"})
        {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("Config validator exited with status #{status}")

    for {from, _cmd} <- :queue.to_list(state.waiting) do
      GenServer.reply(from, {:error, "the config validator exited (status #{status})"})
    end

    {:noreply, %{state | port: nil, waiting: :queue.new()}}
  end

  defp ensure_port(%{port: port} = state) when port != nil, do: {:ok, state}

  defp ensure_port(state) do
    python = Path.expand(Settings.get(:python), Settings.project_dir())
    script = Application.app_dir(:jaxrl_dashboard, "priv/python/config_validator.py")

    if File.exists?(python) do
      port =
        Port.open({:spawn_executable, python}, [
          :binary,
          :exit_status,
          packet: 4,
          args: [script],
          cd: Settings.project_dir(),
          env: [{~c"JAX_PLATFORMS", ~c"cpu"}]
        ])

      {:ok, %{state | port: port}}
    else
      {:error, "jaxrl's Python wasn't found at #{python}"}
    end
  end

  defp last_line(text), do: text |> String.trim() |> String.split("\n") |> List.last()
end
