defmodule CodingAgent.Tools.HashlineTest do
  @moduledoc """
  Tests for the Hashline edit mode with streaming support.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Hashline
  alias CodingAgent.Tools.Hashline.HashlineMismatchError

  # ============================================================================
  # compute_line_hash/1
  # ============================================================================

  describe "compute_line_hash/1" do
    test "returns consistent hash for same content" do
      hash1 = Hashline.compute_line_hash("hello")
      hash2 = Hashline.compute_line_hash("hello")
      assert hash1 == hash2
    end

    test "returns different hash for different content" do
      hash1 = Hashline.compute_line_hash("hello")
      hash2 = Hashline.compute_line_hash("world")
      assert hash1 != hash2
    end

    test "normalizes whitespace before hashing" do
      hash1 = Hashline.compute_line_hash("  hello  world  ")
      hash2 = Hashline.compute_line_hash("helloworld")
      assert hash1 == hash2
    end

    test "returns 2-character hash" do
      hash = Hashline.compute_line_hash("any content")
      assert String.length(hash) == 2
    end

    test "uses custom nibble alphabet" do
      hash = Hashline.compute_line_hash("test")
      # Should only contain characters from the nibble alphabet
      assert hash =~ ~r/^[ZPMQVRWSNKTXJBYH]{2}$/
    end
  end

  # ============================================================================
  # format_line_tag/2
  # ============================================================================

  describe "format_line_tag/2" do
    test "formats tag with line number and hash" do
      tag = Hashline.format_line_tag(5, "hello")
      hash = Hashline.compute_line_hash("hello")
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
      hash = Hashline.compute_line_hash("hello")
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
      hash = Hashline.compute_line_hash("")
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
      hash = Hashline.compute_line_hash("hello")

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
  # apply_edits/2 - set operation
  # ============================================================================

  describe "apply_edits/2 - set operation" do
    test "replaces single line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :set, tag: %{line: 2, hash: Hashline.compute_line_hash("bbb")}, content: ["BBB"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB\nccc"
      assert result.first_changed_line == 2
    end

    test "deletes line with empty content" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :set, tag: %{line: 2, hash: Hashline.compute_line_hash("bbb")}, content: []}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nccc"
      assert result.first_changed_line == 2
    end

    test "detects noop edits" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :set, tag: %{line: 2, hash: Hashline.compute_line_hash("bbb")}, content: ["bbb"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.noop_edits != nil
      assert length(result.noop_edits) == 1
    end
  end

  # ============================================================================
  # apply_edits/2 - replace operation
  # ============================================================================

  describe "apply_edits/2 - replace operation" do
    test "replaces range of lines" do
      content = "aaa\nbbb\nccc\nddd"
      edits = [
        %{
          op: :replace,
          first: %{line: 2, hash: Hashline.compute_line_hash("bbb")},
          last: %{line: 3, hash: Hashline.compute_line_hash("ccc")},
          content: ["XXX"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nXXX\nddd"
    end

    test "expands to more lines" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{
          op: :replace,
          first: %{line: 2, hash: Hashline.compute_line_hash("bbb")},
          last: %{line: 2, hash: Hashline.compute_line_hash("bbb")},
          content: ["xxx", "yyy", "zzz"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nxxx\nyyy\nzzz\nccc"
    end
  end

  # ============================================================================
  # apply_edits/2 - append operation
  # ============================================================================

  describe "apply_edits/2 - append operation" do
    test "inserts after a line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :append, after: %{line: 1, hash: Hashline.compute_line_hash("aaa")}, content: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nNEW\nbbb\nccc"
    end

    test "appends at EOF without anchor" do
      content = "aaa\nbbb"
      edits = [%{op: :append, after: nil, content: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nbbb\nNEW"
    end

    test "replaces empty file when appending at EOF" do
      content = ""
      edits = [%{op: :append, after: nil, content: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "NEW"
    end
  end

  # ============================================================================
  # apply_edits/2 - prepend operation
  # ============================================================================

  describe "apply_edits/2 - prepend operation" do
    test "inserts before a line" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :prepend, before: %{line: 2, hash: Hashline.compute_line_hash("bbb")}, content: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nNEW\nbbb\nccc"
    end

    test "prepends at BOF without anchor" do
      content = "aaa\nbbb"
      edits = [%{op: :prepend, before: nil, content: ["NEW"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "NEW\naaa\nbbb"
    end
  end

  # ============================================================================
  # apply_edits/2 - insert operation
  # ============================================================================

  describe "apply_edits/2 - insert operation" do
    test "inserts between two lines" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{
          op: :insert,
          after: %{line: 1, hash: Hashline.compute_line_hash("aaa")},
          before: %{line: 2, hash: Hashline.compute_line_hash("bbb")},
          content: ["NEW"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nNEW\nbbb\nccc"
    end

    test "inserts multiple lines between anchors" do
      content = "aaa\nbbb\nccc"
      edits = [
        %{
          op: :insert,
          after: %{line: 1, hash: Hashline.compute_line_hash("aaa")},
          before: %{line: 3, hash: Hashline.compute_line_hash("ccc")},
          content: ["x", "y", "z"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nbbb\nx\ny\nz\nccc"
    end

    test "raises when before line <= after line" do
      content = "aaa\nbbb\nccc"

      assert_raise ArgumentError, ~r/after.*<.*before/, fn ->
        edits = [
          %{
            op: :insert,
            after: %{line: 3, hash: Hashline.compute_line_hash("ccc")},
            before: %{line: 1, hash: Hashline.compute_line_hash("aaa")},
            content: ["NEW"]
          }
        ]

        Hashline.apply_edits(content, edits)
      end
    end
  end

  # ============================================================================
  # apply_edits/2 - multiple edits
  # ============================================================================

  describe "apply_edits/2 - multiple edits" do
    test "applies multiple non-overlapping edits" do
      content = "aaa\nbbb\nccc\nddd\neee"
      edits = [
        %{op: :set, tag: %{line: 2, hash: Hashline.compute_line_hash("bbb")}, content: ["BBB"]},
        %{op: :set, tag: %{line: 4, hash: Hashline.compute_line_hash("ddd")}, content: ["DDD"]}
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
    end

    test "deduplicates identical edits" do
      content = "aaa\nbbb\nccc"
      hash = Hashline.compute_line_hash("bbb")

      edits = [
        %{op: :set, tag: %{line: 2, hash: hash}, content: ["BBB"]},
        %{op: :set, tag: %{line: 2, hash: hash}, content: ["BBB"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "aaa\nBBB\nccc"
    end
  end

  # ============================================================================
  # apply_edits/2 - error handling
  # ============================================================================

  describe "apply_edits/2 - error handling" do
    test "returns error on stale hash" do
      content = "aaa\nbbb\nccc"
      edits = [%{op: :set, tag: %{line: 2, hash: "ZZ"}, content: ["BBB"]}]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 1
      assert hd(error.mismatches).line == 2
    end

    test "collects all mismatches" do
      content = "aaa\nbbb\nccc\nddd\neee"
      edits = [
        %{op: :set, tag: %{line: 2, hash: "ZZ"}, content: ["BBB"]},
        %{op: :set, tag: %{line: 4, hash: "YY"}, content: ["DDD"]}
      ]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 2
    end

    test "error includes correct hashes" do
      content = "aaa\nbbb\nccc"
      correct_hash = Hashline.compute_line_hash("bbb")

      edits = [%{op: :set, tag: %{line: 2, hash: "ZZ"}, content: ["BBB"]}]

      assert {:error, error} = Hashline.apply_edits(content, edits)
      # The error should include the correct hash in remaps
      assert error.remaps["2#ZZ"] == "2##{correct_hash}"
    end

    test "raises on line out of range" do
      content = "aaa\nbbb"

      assert_raise ArgumentError, ~r/does not exist/, fn ->
        edits = [%{op: :set, tag: %{line: 10, hash: "ZZ"}, content: ["X"]}]
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
  # apply_edits/2 - autocorrect features (ported from Oh-My-Pi)
  # ============================================================================

  describe "apply_edits/2 - autocorrect: restore indent for paired replacement" do
    setup do
      Application.put_env(:coding_agent, :hashline_autocorrect, true)

      on_exit(fn ->
        Application.delete_env(:coding_agent, :hashline_autocorrect)
      end)
    end

    test "restores stripped indentation on set operation" do
      content = "  def foo do\n    :bar\n  end"
      hash = Hashline.compute_line_hash("    :bar")

      # Model returns content without indentation
      edits = [%{op: :set, tag: %{line: 2, hash: hash}, content: [":baz"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      # Autocorrect should restore the original indentation
      assert result.content == "  def foo do\n    :baz\n  end"
    end

    test "does not modify lines that already have indentation" do
      content = "  def foo do\n    :bar\n  end"
      hash = Hashline.compute_line_hash("    :bar")

      edits = [%{op: :set, tag: %{line: 2, hash: hash}, content: ["    :baz"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "  def foo do\n    :baz\n  end"
    end

    test "restores indentation on replace operation" do
      content = "  line1\n    line2\n    line3\n  end"
      first_hash = Hashline.compute_line_hash("    line2")
      last_hash = Hashline.compute_line_hash("    line3")

      # Model returns replacement without indentation
      edits = [
        %{
          op: :replace,
          first: %{line: 2, hash: first_hash},
          last: %{line: 3, hash: last_hash},
          content: ["new_line2", "new_line3"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "  line1\n    new_line2\n    new_line3\n  end"
    end
  end

  describe "apply_edits/2 - autocorrect: strip range boundary echo" do
    setup do
      Application.put_env(:coding_agent, :hashline_autocorrect, true)

      on_exit(fn ->
        Application.delete_env(:coding_agent, :hashline_autocorrect)
      end)
    end

    test "strips echoed boundary lines on set when content grew" do
      content = "before\ntarget\nafter"
      hash = Hashline.compute_line_hash("target")

      # Model echoes the line before and after the target
      edits = [%{op: :set, tag: %{line: 2, hash: hash}, content: ["before", "new_target", "after"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "before\nnew_target\nafter"
    end

    test "strips echoed boundary on replace when content grew" do
      content = "ctx_before\nline1\nline2\nctx_after"
      first_hash = Hashline.compute_line_hash("line1")
      last_hash = Hashline.compute_line_hash("line2")

      # Model echoes boundary context lines
      edits = [
        %{
          op: :replace,
          first: %{line: 2, hash: first_hash},
          last: %{line: 3, hash: last_hash},
          content: ["ctx_before", "new1", "new2", "new3", "ctx_after"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "ctx_before\nnew1\nnew2\nnew3\nctx_after"
    end

    test "does not strip when content did not grow" do
      content = "before\ntarget\nafter"
      hash = Hashline.compute_line_hash("target")

      # Single line replacement - should not strip
      edits = [%{op: :set, tag: %{line: 2, hash: hash}, content: ["new_target"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "before\nnew_target\nafter"
    end
  end

  describe "apply_edits/2 - autocorrect: restore old wrapped lines" do
    setup do
      Application.put_env(:coding_agent, :hashline_autocorrect, true)

      on_exit(fn ->
        Application.delete_env(:coding_agent, :hashline_autocorrect)
      end)
    end

    test "undoes model line reflow that splits one line into two" do
      original_line = "def very_long_function_name(arg1, arg2, arg3)"
      content = "start\n#{original_line}\nend"
      hash = Hashline.compute_line_hash(original_line)

      # Model splits the line into two but content is same (ignoring whitespace)
      edits = [
        %{
          op: :set,
          tag: %{line: 2, hash: hash},
          content: ["def very_long_function_name(arg1,", " arg2, arg3)"]
        }
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      # Autocorrect should restore the original single line
      assert result.content == "start\n#{original_line}\nend"
    end
  end

  describe "apply_edits/2 - autocorrect disabled by default" do
    test "does not restore indentation when autocorrect is off" do
      content = "  def foo do\n    :bar\n  end"
      hash = Hashline.compute_line_hash("    :bar")

      # Without autocorrect, the stripped indentation should stay
      edits = [%{op: :set, tag: %{line: 2, hash: hash}, content: [":baz"]}]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "  def foo do\n:baz\n  end"
    end
  end

  # ============================================================================
  # apply_edits/2 - replace_text operation
  # ============================================================================

  describe "apply_edits/2 with replace_text" do
    test "replaces first occurrence by default" do
      content = "foo bar\nfoo baz\nfoo qux"
      edits = [%{op: :replace_text, old_text: "foo", new_text: "hello", all: false}]
      {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "hello bar\nfoo baz\nfoo qux"
      assert result.first_changed_line == 1
    end

    test "replaces all occurrences when all is true" do
      content = "foo bar\nfoo baz\nfoo qux"
      edits = [%{op: :replace_text, old_text: "foo", new_text: "hello", all: true}]
      {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "hello bar\nhello baz\nhello qux"
    end

    test "raises ArgumentError when old_text is empty" do
      content = "hello world"
      edits = [%{op: :replace_text, old_text: "", new_text: "bye", all: false}]
      assert_raise ArgumentError, ~r/non-empty/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "raises ArgumentError when old_text not found" do
      content = "hello world"
      edits = [%{op: :replace_text, old_text: "missing", new_text: "found", all: false}]
      assert_raise ArgumentError, ~r/not found/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "replaces text spanning multiple lines" do
      content = "hello\nworld"
      edits = [%{op: :replace_text, old_text: "hello\nworld", new_text: "goodbye\nplanet", all: false}]
      {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "goodbye\nplanet"
    end

    test "handles replacement that changes line count" do
      content = "line1\nline2\nline3"
      edits = [%{op: :replace_text, old_text: "line2", new_text: "new2a\nnew2b", all: false}]
      {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew2a\nnew2b\nline3"
    end
  end
end
