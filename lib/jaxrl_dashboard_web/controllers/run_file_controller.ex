defmodule JaxrlDashboardWeb.RunFileController do
  use JaxrlDashboardWeb, :controller

  alias JaxrlDashboard.{Metrics, Runs, Videos}
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
      not_found(conn)
    end
  end

  @doc """
  Streams a recorded video. Supports single byte ranges, which browsers need
  to seek (and Safari needs to play at all). A set's files never change, so
  they can be cached for good.
  """
  def video(conn, %{"name" => name, "set" => set, "file" => file}) do
    run = Runs.get_run_by_name!(name)
    path = Videos.video_path(run.name, set, file)

    case path && File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        conn
        |> put_resp_content_type("video/mp4", nil)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
        |> send_video(path, size, get_req_header(conn, "range"))

      _ ->
        not_found(conn)
    end
  end

  defp send_video(conn, path, size, ["bytes=" <> range]) do
    case byte_range(range, size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      # Multiple or malformed ranges: the whole file is a valid answer.
      :error ->
        send_file(conn, 200, path)
    end
  end

  defp send_video(conn, path, _size, _range), do: send_file(conn, 200, path)

  defp byte_range(_range, 0), do: :unsatisfiable

  defp byte_range(range, size) do
    case String.split(range, "-", parts: 2) do
      # "-N": the last N bytes
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 -> {max(size - n, 0), size - 1}
          _ -> :error
        end

      [first, last] ->
        with {first, ""} when first >= 0 <- Integer.parse(first),
             {:ok, last} <- parse_last(last, size) do
          cond do
            first >= size -> :unsatisfiable
            first <= last -> {first, min(last, size - 1)}
            true -> :error
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_last("", size), do: {:ok, size - 1}

  defp parse_last(last, _size) do
    case Integer.parse(last) do
      {last, ""} -> {:ok, last}
      _ -> :error
    end
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("Not found")
end
