defmodule CodingAgent.Tools.HashlineTest do
  @moduledoc """
  Tests for the Hashline edit mode with streaming support.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Hashline
  alias CodingAgent.Tools.Hashline.HashlineMismatchError

  # ============================================================================
  # compute_line_hash/2
  # ============================================================================

  describe "compute_line_hash/2" do
    test "returns consistent hash for same content" do
      hash1 = Hashline.compute_line_hash(1, "hello")
      hash2 = Hashline.compute_line_hash(1, "hello")
      assert hash1 == hash2
    end

    test "returns different hash for different content" do
      hash1 = Hashline.compute_line_hash(1, "hello")
      hash2 = Hashline.compute_line_hash(1, "world")
      assert hash1 != hash2
    end

    test "normalizes whitespace before hashing" do
      hash1 = Hashline.compute_line_hash(1, "  hello  world  ")
      hash2 = Hashline.compute_line_hash(1, "helloworld")
      assert hash1 == hash2
    end

    test "returns 2-character hash" do
      hash = Hashline.compute_line_hash(1, "any content")
      assert String.length(hash) == 2
    end

    test "uses custom nibble alphabet" do
      hash = Hashline.compute_line_hash(1, "test")
      # Should only contain characters from the nibble alphabet
      assert hash =~ ~r/^[ZPMQVRWSNKTXJBYH]{2}$/
    end

    test "mixes in line number for symbol-only lines" do
      hash1 = Hashline.compute_line_hash(1, "---")
      hash2 = Hashline.compute_line_hash(2, "---")
      assert hash1 != hash2
    end

    test "does not mix in line number for lines with alphanumeric chars" do
      hash1 = Hashline.compute_line_hash(1, "hello")
      hash2 = Hashline.compute_line_hash(2, "hello")
      assert hash1 == hash2
    end

    test "empty line gets line number mixed in" do
      hash1 = Hashline.compute_line_hash(1, "")
      hash2 = Hashline.compute_line_hash(2, "")
      assert hash1 != hash2
    end
  end

  # ============================================================================
  # format_line_tag/2
  # ============================================================================

  describe "format_line_tag/2" do
    test "formats tag with line number and hash" do
      tag = Hashline.format_line_tag(5, "hello")
      hash = Hashline.compute_line_hash(5, "hello")
      assert tag == "5##{hash}"
    end

    test "uses line number provided" do
      tag = Hashline.format_line_tag(100, "content")
      assert String.starts_with?(tag, "100#")
    end
  end

  # ============================================================================
  # format_hashlines/2
  # ============================================================================

  describe "format_hashlines/2" do
    test "formats single line" do
      result = Hashline.format_hashlines("hello")
      hash = Hashline.compute_line_hash(1, "hello")
      assert result == "1##{hash}:hello"
    end

    test "formats multiple lines with correct line numbers" do
      result = Hashline.format_hashlines("a\nb\nc")
      lines = String.split(result, "\n")

      assert length(lines) == 3
      assert String.starts_with?(Enum.at(lines, 0), "1#")
      assert String.starts_with?(Enum.at(lines, 1), "2#")
      assert String.starts_with?(Enum.at(lines, 2), "3#")
    end

    test "respects start_line parameter" do
      result = Hashline.format_hashlines("a\nb", 10)
      lines = String.split(result, "\n")

      assert String.starts_with?(Enum.at(lines, 0), "10#")
      assert String.starts_with?(Enum.at(lines, 1), "11#")
    end

    test "handles empty content" do
      result = Hashline.format_hashlines("")
      hash = Hashline.compute_line_hash(1, "")
      assert result == "1##{hash}:"
    end

    test "handles empty lines within content" do
      result = Hashline.format_hashlines("line1\n\nline3")
      lines = String.split(result, "\n")

      assert length(lines) == 3
      # Middle line should have empty content after colon
      assert Regex.match?(~r/^2#[ZPMQVRWSNKTXJBYH]{2}:$/, Enum.at(lines, 1))
    end
  end

  # ============================================================================
  # parse_tag/1
  # ============================================================================

  describe "parse_tag/1" do
    test "parses valid tag" do
      result = Hashline.parse_tag("5#ZZ")
      assert result.line == 5
      assert result.hash == "ZZ"
    end

    test "parses tag with whitespace" do
      result = Hashline.parse_tag("  5  #  ZZ  ")
      assert result.line == 5
      assert result.hash == "ZZ"
    end

    test "raises on invalid format" do
      assert_raise ArgumentError, ~r/Invalid line reference/, fn ->
        Hashline.parse_tag("invalid")
      end
    end

    test "raises on missing hash" do
      assert_raise ArgumentError, ~r/Invalid line reference/, fn ->
        Hashline.parse_tag("5#")
      end
    end

    test "raises on line number 0" do
      assert_raise ArgumentError, ~r/Line number must be >= 1/, fn ->
        Hashline.parse_tag("0#ZZ")
      end
    end

    test "raises on non-numeric line" do
      assert_raise ArgumentError, ~r/Invalid line reference/, fn ->
        Hashline.parse_tag("abc#ZZ")
      end
    end
  end

  # ============================================================================
  # validate_line_ref/2
  # ============================================================================

  describe "validate_line_ref/2" do
    test "accepts valid reference" do
      lines = ["hello", "world"]
      hash = Hashline.compute_line_hash(1, "hello")

      assert :ok = Hashline.validate_line_ref(%{line: 1, hash: hash}, lines)
    end

    test "raises on line out of range" do
      lines = ["hello"]

      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Hashline.validate_line_ref(%{line: 2, hash: "ZZ"}, lines)
      end
    end

    test "raises on hash mismatch" do
      lines = ["hello", "world"]

      assert_raise HashlineMismatchError, ~r/have changed/, fn ->
        Hashline.validate_line_ref(%{line: 1, hash: "XX"}, lines)
      end
    end
  end

  # ============================================================================
  # apply_edits/2 - replace operation (single line)
  # ============================================================================

  describe "apply_edits/2 - replace single line" do
    test "replaces single line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["BBB"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB\nccc"
      assert result.first_changed_line == 2
    end

    test "deletes line with empty lines" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: []}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nccc"
      assert result.first_changed_line == 2
    end

    test "detects noop edits" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["bbb"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.noop_edits != nil
      assert length(result.noop_edits) == 1
    end

    test "expands single line to multiple" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["xxx", "yyy", "zzz"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nxxx\nyyy\nzzz\nccc"
    end
  end

  # ============================================================================
  # apply_edits/2 - replace operation (range)
  # ============================================================================

  describe "apply_edits/2 - replace range" do
    test "replaces range of lines" do
      content = "aaa\nbbb\nccc\nddd"
      edits = [
        %{
          op: :replace,
          pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")},
          end: %{line: 3, hash: Hashline.compute_line_hash(3, "ccc")},
          lines: ["XXX"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nXXX\nddd"
    end

    test "expands range to more lines" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{
          op: :replace,
          pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")},
          end: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")},
          lines: ["xxx", "yyy", "zzz"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nxxx\nyyy\nzzz\nccc"
    end

    test "deletes range of lines" do
      content = "aaa\nbbb\nccc\nddd"
      edits = [
        %{
          op: :replace,
          pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")},
          end: %{line: 3, hash: Hashline.compute_line_hash(3, "ccc")},
          lines: []
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nddd"
    end
  end

  # ============================================================================
  # apply_edits/2 - append operation
  # ============================================================================

  describe "apply_edits/2 - append operation" do
    test "inserts after a line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :append, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nNEW\nbbb\nccc"
    end

    test "appends at EOF without anchor" do
      content = "aaa\nbbb"
      edits = [%{op: :append, pos: nil, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nbbb\nNEW"
    end

    test "replaces empty file when appending at EOF" do
      content = ""
      edits = [%{op: :append, pos: nil, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "NEW"
    end

    test "inserts multiple lines after anchor" do
      content = "aaa\nbbb"
      edits = [%{op: :append, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: ["x", "y", "z"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nx\ny\nz\nbbb"
    end
  end

  # ============================================================================
  # apply_edits/2 - prepend operation
  # ============================================================================

  describe "apply_edits/2 - prepend operation" do
    test "inserts before a line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :prepend, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nNEW\nbbb\nccc"
    end

    test "prepends at BOF without anchor" do
      content = "aaa\nbbb"
      edits = [%{op: :prepend, pos: nil, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "NEW\naaa\nbbb"
    end

    test "inserts before first line" do
      content = "aaa\nbbb"
      edits = [%{op: :prepend, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "NEW\naaa\nbbb"
    end
  end

  # ============================================================================
  # apply_edits/2 - multiple edits
  # ============================================================================

  describe "apply_edits/2 - multiple edits" do
    test "applies multiple non-overlapping edits" do
      content = "aaa\nbbb\nccc\nddd\neee"
      edits = [
        %{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["BBB"]},
        %{op: :replace, pos: %{line: 4, hash: Hashline.compute_line_hash(4, "ddd")}, lines: ["DDD"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB\nccc\nDDD\neee"
      assert result.first_changed_line == 2
    end

    test "empty edits array is no-op" do
      content = "aaa\nbbb"
      assert {:ok, result} = Hashline.apply_edits(content, [])
      assert result.content == content
      assert result.first_changed_line == nil
      assert result.deduplicated_edits == nil
    end

    test "deduplicates identical edits" do
      content = "aaa\nbbb\nccc"
      hash = Hashline.compute_line_hash(2, "bbb")

      edits = [
        %{op: :replace, pos: %{line: 2, hash: hash}, lines: ["BBB"]},
        %{op: :replace, pos: %{line: 2, hash: hash}, lines: ["BBB"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB\nccc"
      assert length(result.deduplicated_edits) == 1
      dedup = hd(result.deduplicated_edits)
      assert dedup.edit_index == 1
      assert dedup.duplicate_of == 0
      assert dedup.op == :replace
    end

    test "does not deduplicate edits with same target but different content" do
      content = "aaa\nbbb\nccc"
      hash = Hashline.compute_line_hash(2, "bbb")

      edits = [
        %{op: :replace, pos: %{line: 2, hash: hash}, lines: ["BBB"]},
        %{op: :replace, pos: %{line: 2, hash: hash}, lines: ["BBB2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB2\nccc"
      assert result.deduplicated_edits == nil
    end

    test "applies replace + append in one call" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{op: :replace, pos: %{line: 3, hash: Hashline.compute_line_hash(3, "ccc")}, lines: ["CCC"]},
        %{op: :append, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: ["INSERTED"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nINSERTED\nbbb\nCCC"
    end

    test "prepend and append at same line produce correct order" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{op: :prepend, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["BEFORE"]},
        %{op: :append, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["AFTER"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBEFORE\nbbb\nAFTER\nccc"
    end

    test "prepend with replace at same line" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{op: :prepend, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["BEFORE"]},
        %{op: :replace, pos: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")}, lines: ["BBB"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBEFORE\nBBB\nccc"
    end
  end

  # ============================================================================
  # apply_edits/2 - error handling
  # ============================================================================

  describe "apply_edits/2 - error handling" do
    test "returns error on stale hash" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :replace, pos: %{line: 2, hash: "ZZ"}, lines: ["BBB"]}]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 1
      assert hd(error.mismatches).line == 2
    end

    test "collects all mismatches" do
      content = "aaa\nbbb\nccc\nddd\neee"
      edits = [
        %{op: :replace, pos: %{line: 2, hash: "ZZ"}, lines: ["BBB"]},
        %{op: :replace, pos: %{line: 4, hash: "YY"}, lines: ["DDD"]}
      ]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 2
    end

    test "error includes correct hashes" do
      content = "aaa\nbbb\nccc"
      correct_hash = Hashline.compute_line_hash(2, "bbb")

      edits = [%{op: :replace, pos: %{line: 2, hash: "ZZ"}, lines: ["BBB"]}]

      assert {:error, error} = Hashline.apply_edits(content, edits)
      # The error should include the correct hash in remaps
      assert error.remaps["2#ZZ"] == "2##{correct_hash}"
    end

    test "raises on line out of range" do
      content = "aaa\nbbb"

      assert_raise ArgumentError, ~r/does not exist/, fn ->
        edits = [%{op: :replace, pos: %{line: 10, hash: "ZZ"}, lines: ["X"]}]
        Hashline.apply_edits(content, edits)
      end
    end

    test "rejects range with start > end" do
      content = "aaa\nbbb\nccc\nddd\neee"

      assert_raise ArgumentError, ~r/must be <=/, fn ->
        edits = [
          %{
            op: :replace,
            pos: %{line: 5, hash: Hashline.compute_line_hash(5, "eee")},
            end: %{line: 2, hash: Hashline.compute_line_hash(2, "bbb")},
            lines: ["X"]
          }
        ]

        Hashline.apply_edits(content, edits)
      end
    end

    test "rejects append with empty lines" do
      content = "aaa\nbbb"
      edits = [%{op: :append, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: []}]

      assert_raise ArgumentError, ~r/non-empty/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "rejects prepend with empty lines" do
      content = "aaa\nbbb"
      edits = [%{op: :prepend, pos: %{line: 1, hash: Hashline.compute_line_hash(1, "aaa")}, lines: []}]

      assert_raise ArgumentError, ~r/non-empty/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end
  end

  # ============================================================================
  # format_mismatch_message/2
  # ============================================================================

  describe "format_mismatch_message/2" do
    test "includes number of mismatches" do
      lines = ["aaa", "bbb", "ccc", "ddd", "eee"]
      mismatches = [%{line: 2, expected: "ZZ", actual: "YY"}]

      message = Hashline.format_mismatch_message(mismatches, lines)
      assert message =~ "1 line has changed"
    end

    test "includes context lines around mismatch" do
      lines = ["aaa", "bbb", "ccc", "ddd", "eee"]
      mismatches = [%{line: 3, expected: "ZZ", actual: "YY"}]

      message = Hashline.format_mismatch_message(mismatches, lines)
      assert message =~ "bbb"
      assert message =~ "ccc"
      assert message =~ "ddd"
    end

    test "marks mismatched line with >>>" do
      lines = ["aaa", "bbb", "ccc"]
      mismatches = [%{line: 2, expected: "ZZ", actual: "YY"}]

      message = Hashline.format_mismatch_message(mismatches, lines)
      assert message =~ ">>>"
    end

    test "handles multiple mismatches" do
      lines = ["aaa", "bbb", "ccc", "ddd", "eee"]
      mismatches = [
        %{line: 2, expected: "ZZ", actual: "YY"},
        %{line: 4, expected: "XX", actual: "WW"}
      ]

      message = Hashline.format_mismatch_message(mismatches, lines)
      assert message =~ "2 lines have changed"
    end
  end

  # ============================================================================
  # stream_hashlines/2
  # ============================================================================

  describe "stream_hashlines/2" do
    test "streams formatted lines in chunks" do
      content = "line1\nline2\nline3"

      chunks =
        content
        |> Hashline.stream_hashlines(max_chunk_lines: 1)
        |> Enum.to_list()

      assert length(chunks) == 3
      assert Enum.at(chunks, 0) =~ "1#"
      assert Enum.at(chunks, 1) =~ "2#"
      assert Enum.at(chunks, 2) =~ "3#"
    end

    test "respects max_chunk_lines" do
      content = Enum.join(1..100 |> Enum.map(&"line#{&1}"), "\n")

      chunks =
        content
        |> Hashline.stream_hashlines(max_chunk_lines: 10)
        |> Enum.to_list()

      # Should have approximately 10 chunks (100 lines / 10 per chunk)
      assert length(chunks) >= 10
    end

    test "respects start_line option" do
      content = "aaa\nbbb"

      chunks =
        content
        |> Hashline.stream_hashlines(start_line: 100)
        |> Enum.to_list()

      result = Enum.join(chunks, "\n")
      assert result =~ "100#"
      assert result =~ "101#"
    end

    test "handles empty content" do
      chunks =
        ""
        |> Hashline.stream_hashlines()
        |> Enum.to_list()

      assert length(chunks) == 1
      assert Enum.at(chunks, 0) =~ "1#"
    end

    test "handles large files efficiently" do
      # Generate a large file (1000 lines)
      content = Enum.join(1..1000 |> Enum.map(&"line content #{&1}"), "\n")

      chunks =
        content
        |> Hashline.stream_hashlines(max_chunk_lines: 100)
        |> Enum.to_list()

      assert length(chunks) == 10

      # Verify all chunks are formatted correctly
      for chunk <- chunks do
        assert chunk =~ ~r/^\d+#[ZPMQVRWSNKTXJBYH]{2}:/
      end
    end
  end

  # ============================================================================
  # stream_hashlines_from_enumerable/2
  # ============================================================================

  describe "stream_hashlines_from_enumerable/2" do
    test "produces same output as stream_hashlines for simple content" do
      content = "line1\nline2\nline3"

      expected =
        content
        |> Hashline.stream_hashlines(max_chunk_lines: 1)
        |> Enum.to_list()

      actual =
        [content]
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      assert actual == expected
    end

    test "handles content split across multiple chunks" do
      # Split "line1\nline2\nline3" across chunk boundaries
      chunks = ["lin", "e1\nli", "ne2\nline3"]

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      assert length(result) == 3
      assert Enum.at(result, 0) =~ ~r/^1#[ZPMQVRWSNKTXJBYH]{2}:line1$/
      assert Enum.at(result, 1) =~ ~r/^2#[ZPMQVRWSNKTXJBYH]{2}:line2$/
      assert Enum.at(result, 2) =~ ~r/^3#[ZPMQVRWSNKTXJBYH]{2}:line3$/
    end

    test "handles newline at chunk boundary" do
      chunks = ["hello\n", "world"]

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      assert length(result) == 2
      assert Enum.at(result, 0) =~ "hello"
      assert Enum.at(result, 1) =~ "world"
    end

    test "handles content ending with newline" do
      chunks = ["line1\nline2\n"]

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      # Should emit 3 lines: "line1", "line2", and the final empty line
      assert length(result) == 3
      assert Enum.at(result, 0) =~ "line1"
      assert Enum.at(result, 1) =~ "line2"
      assert Enum.at(result, 2) =~ ~r/^3#[ZPMQVRWSNKTXJBYH]{2}:$/
    end

    test "handles empty enumerable" do
      result =
        []
        |> Hashline.stream_hashlines_from_enumerable()
        |> Enum.to_list()

      # Empty source should emit one empty line (like "".split("\n"))
      assert length(result) == 1
      assert Enum.at(result, 0) =~ ~r/^1#[ZPMQVRWSNKTXJBYH]{2}:$/
    end

    test "respects max_chunk_lines option" do
      content = Enum.map_join(1..20, "\n", &"line#{&1}")
      chunks = [content]

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 5)
        |> Enum.to_list()

      assert length(result) == 4

      for chunk <- result do
        lines = String.split(chunk, "\n")
        assert length(lines) <= 5
      end
    end

    test "respects start_line option" do
      chunks = ["aaa\nbbb"]

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(start_line: 50, max_chunk_lines: 1)
        |> Enum.to_list()

      assert Enum.at(result, 0) =~ ~r/^50#/
      assert Enum.at(result, 1) =~ ~r/^51#/
    end

    test "works with File.stream!-style binary chunks" do
      # Simulate File.stream! producing binary chunks
      content = "defmodule Foo do\n  def bar, do: :ok\nend\n"
      chunk_size = 10
      chunks = for <<chunk::binary-size(chunk_size) <- content>>, do: chunk
      # Add remainder
      remainder_size = rem(byte_size(content), chunk_size)
      chunks = if remainder_size > 0 do
        chunks ++ [binary_part(content, byte_size(content) - remainder_size, remainder_size)]
      else
        chunks
      end

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      # 4 lines: "defmodule Foo do", "  def bar, do: :ok", "end", ""
      assert length(result) == 4
      assert Enum.at(result, 0) =~ "defmodule Foo do"
      assert Enum.at(result, 1) =~ "def bar, do: :ok"
      assert Enum.at(result, 2) =~ "end"
    end

    test "hashes match between stream_hashlines and stream_hashlines_from_enumerable" do
      content = "alpha\nbeta\ngamma"

      from_string =
        content
        |> Hashline.stream_hashlines(max_chunk_lines: 100)
        |> Enum.to_list()
        |> Enum.join("\n")

      from_enum =
        [content]
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 100)
        |> Enum.to_list()
        |> Enum.join("\n")

      assert from_string == from_enum
    end

    test "handles single-character chunks" do
      content = "ab\ncd"
      chunks = String.graphemes(content)

      result =
        chunks
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_lines: 1)
        |> Enum.to_list()

      assert length(result) == 2
      assert Enum.at(result, 0) =~ "ab"
      assert Enum.at(result, 1) =~ "cd"
    end

    test "handles max_chunk_bytes limit" do
      # Create lines that are large enough to trigger byte limits
      long_line = String.duplicate("x", 1000)
      content = Enum.map_join(1..5, "\n", fn _ -> long_line end)

      result =
        [content]
        |> Hashline.stream_hashlines_from_enumerable(max_chunk_bytes: 2048, max_chunk_lines: 100)
        |> Enum.to_list()

      # Should produce multiple chunks due to byte limit
      assert length(result) > 1

      for chunk <- result do
        assert byte_size(chunk) <= 2048 + 1100  # one line can exceed since first line always goes in
      end
    end
  end
end
