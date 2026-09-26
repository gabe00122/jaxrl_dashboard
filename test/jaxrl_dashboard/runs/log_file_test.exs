defmodule JaxrlDashboard.Runs.LogFileTest do
  use ExUnit.Case, async: true

  alias JaxrlDashboard.Runs.LogFile

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    %{path: Path.join(dir, "log.txt")}
  end

  describe "read_lines/3" do
    test "returns complete lines with their offsets and holds back a partial one", %{path: path} do
      File.write!(path, "ab\ncde\nf")

      assert LogFile.read_lines(path, 0) == {[{0, "ab"}, {3, "cde"}], 7}

      # The partial line is picked up once it's finished.
      File.write!(path, "gh\n", [:append])
      assert LogFile.read_lines(path, 7) == {[{7, "fgh"}], 11}
      assert LogFile.read_lines(path, 11) == {[], 11}
    end

    test "includes a trailing partial line when asked", %{path: path} do
      File.write!(path, "ab\ncd")
      assert LogFile.read_lines(path, 0, partial: true) == {[{0, "ab"}, {3, "cd"}], 3}
    end

    test "keeps empty lines", %{path: path} do
      File.write!(path, "a\n\nb\n")
      assert LogFile.read_lines(path, 0) == {[{0, "a"}, {2, ""}, {3, "b"}], 5}
    end

    test "reads in chunks of max_bytes", %{path: path} do
      File.write!(path, "aaaa\nbbbb\ncccc\n")

      assert {[{0, "aaaa"}], 5} = LogFile.read_lines(path, 0, max_bytes: 8)
      assert {[{5, "bbbb"}], 10} = LogFile.read_lines(path, 5, max_bytes: 8)
    end

    test "makes progress on a line longer than max_bytes", %{path: path} do
      File.write!(path, "0123456789\n")
      assert {[{0, "0123"}], 4} = LogFile.read_lines(path, 0, max_bytes: 4)
    end

    test "starts over when the file was rewritten shorter", %{path: path} do
      File.write!(path, "new\n")
      assert LogFile.read_lines(path, 100) == {[{0, "new"}], 4}
    end

    test "returns nothing for a missing file", %{path: path} do
      assert LogFile.read_lines(path, 0) == {[], 0}
    end
  end

  describe "read_tail_lines/2" do
    test "starts at a line boundary", %{path: path} do
      File.write!(path, "first line\nsecond\nthird\n")

      # The last 12 bytes start mid-way through "second".
      assert LogFile.read_tail_lines(path, 12) == {[{18, "third"}], 24}
    end

    test "returns the whole file when it's small, including a partial last line", %{path: path} do
      File.write!(path, "a\nb")
      # next_offset points at "b" so it's read again once complete.
      assert LogFile.read_tail_lines(path, 1024) == {[{0, "a"}, {2, "b"}], 2}
    end

    test "returns nothing for a missing file", %{path: path} do
      assert LogFile.read_tail_lines(path, 1024) == {[], 0}
    end
  end
end
