defmodule JaxrlDashboard.Metrics do
  @moduledoc """
  Training metrics from jaxrl's `logs.jsonl`: one JSON object per update,
  like `{"step": 12, "algo/actor_loss": 0.002, "env/reward": 0.05}`.

  Rows are parsed into `%{step: 12, values: %{"algo/actor_loss" => 0.002}, nan: []}`.
  Non-finite values become `nil` in `values` and their keys are listed in `nan`,
  so charts can show where a run diverged.
  """

  alias JaxrlDashboard.Runs.{LogFile, Settings}

  # Python's json.dumps writes NaN, Infinity and -Infinity, which aren't
  # valid JSON. Swap them for a marker string before decoding.
  @non_finite ~r/:\s*(?:-?Infinity|NaN)(?=\s*[,}])/
  @non_finite_marker "__non_finite__"

  def path(run_name), do: Path.join(Settings.experiment_dir(run_name), "logs.jsonl")

  @doc """
  Parses one line of `logs.jsonl`. Returns `nil` for lines that aren't a
  metrics row. Non-numeric values are dropped.
  """
  def parse_line(line) do
    line = Regex.replace(@non_finite, line, ~s(: "#{@non_finite_marker}"))

    case Jason.decode(line) do
      {:ok, %{"step" => step} = object} when is_integer(step) ->
        {values, nan} =
          object
          |> Map.delete("step")
          |> Enum.reduce({%{}, []}, fn
            {key, value}, {values, nan} when is_number(value) ->
              {Map.put(values, key, value), nan}

            {key, @non_finite_marker}, {values, nan} ->
              {Map.put(values, key, nil), [key | nan]}

            _other, acc ->
              acc
          end)

        %{step: step, values: values, nan: Enum.sort(nan)}

      _ ->
        nil
    end
  end

  def parse_lines(lines) do
    for {_offset, line} <- lines, row = parse_line(line), do: row
  end

  @doc """
  Loads all of a run's metrics in columnar form, ready for charting:

      %{steps: [0, 1, ...], series: %{"algo/actor_loss" => [0.002, nil, ...]},
        nan: %{"algo/actor_loss" => %{first: 1, last: 9, count: 9}}}

  `nan` summarizes, per metric, the steps whose value was non-finite, which
  tells a run that diverged (NaN from some step to the end) apart from one
  with occasional NaNs.
  """
  def load(run_name) do
    {lines, _offset} = LogFile.read_lines(path(run_name), 0, max_bytes: 64_000_000, partial: true)
    lines |> parse_lines() |> to_columns()
  end

  def to_columns(rows) do
    keys = rows |> Enum.flat_map(&Map.keys(&1.values)) |> Enum.uniq() |> Enum.sort()

    nan =
      Enum.reduce(rows, %{}, fn row, acc ->
        Enum.reduce(row.nan, acc, fn key, acc ->
          Map.update(
            acc,
            key,
            %{first: row.step, last: row.step, count: 1},
            &%{&1 | last: row.step, count: &1.count + 1}
          )
        end)
      end)

    %{
      steps: Enum.map(rows, & &1.step),
      series: Map.new(keys, fn key -> {key, Enum.map(rows, &Map.get(&1.values, key))} end),
      nan: nan
    }
  end
end
