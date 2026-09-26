defmodule JaxrlDashboard.Runs.LogFile do
  @moduledoc """
  Line-oriented reads of files that are still being appended to.

  Lines come back as `{offset, line}`, where `offset` is the byte position the
  line starts at. Offsets identify lines across reads, which lets readers
  that got the same data from different places (a file read and a watcher
  broadcast) drop duplicates.
  """

  @doc """
  Reads complete lines starting at byte `offset`.

  Returns `{lines, next_offset}`. A trailing line without a newline is still
  being written, so it's left for the next read, unless `partial: true` (for a
  final read after the writer has exited). If the file got shorter than
  `offset`, it was rewritten and is read from the start.

  ## Options

    * `:max_bytes` - read at most this much (default 1 MB)
    * `:partial` - include a trailing unterminated line (default false)
  """
  def read_lines(path, offset, opts \\ []) do
    max_bytes = Keyword.get(opts, :max_bytes, 1_000_000)

    case File.stat(path) do
      {:ok, %{size: size}} ->
        offset = if size < offset, do: 0, else: offset
        data = pread(path, offset, min(size - offset, max_bytes))

        split_lines(
          data,
          offset,
          Keyword.get(opts, :partial, false),
          byte_size(data) == max_bytes
        )

      {:error, _} ->
        {[], offset}
    end
  end

  @doc """
  Reads the lines in the last `max_bytes` of the file, including a trailing
  unterminated line.

  `next_offset` points at the start of that unterminated line (if any), so a
  later read picks it up again once it's complete.
  """
  def read_tail_lines(path, max_bytes) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        start = max(size - max_bytes, 0)
        data = pread(path, start, size - start)

        # Starting mid-file means starting mid-line; skip to the next line.
        {data, start} =
          case start > 0 && :binary.match(data, "\n") do
            {pos, 1} -> {binary_part(data, pos + 1, byte_size(data) - pos - 1), start + pos + 1}
            _ -> {data, start}
          end

        split_lines(data, start, true, false)

      {:error, _} ->
        {[], 0}
    end
  end

  defp pread(_path, _offset, 0), do: ""

  defp pread(path, offset, length) do
    File.open!(path, [:read, :binary], fn file ->
      case :file.pread(file, offset, length) do
        {:ok, data} -> data
        _ -> ""
      end
    end)
  end

  defp split_lines(data, offset, include_partial?, hit_limit?) do
    [partial | complete_reversed] = data |> :binary.split("\n", [:global]) |> Enum.reverse()

    {lines, next_offset} =
      complete_reversed
      |> Enum.reverse()
      |> Enum.map_reduce(offset, fn line, pos -> {{pos, line}, pos + byte_size(line) + 1} end)

    cond do
      partial == "" ->
        {lines, next_offset}

      include_partial? ->
        {lines ++ [{next_offset, partial}], next_offset}

      # A single line longer than max_bytes would otherwise never be consumed.
      lines == [] and hit_limit? ->
        {[{offset, partial}], offset + byte_size(partial)}

      true ->
        {lines, next_offset}
    end
  end
end
