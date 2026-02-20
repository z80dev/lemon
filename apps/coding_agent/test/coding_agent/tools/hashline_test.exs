defmodule CodingAgent.Tools.HashlineTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Hashline
  alias CodingAgent.Tools.Hashline.HashlineMismatchError

  # ============================================================================
  # Hash Computation Tests
  # ============================================================================

  describe "compute_line_hash/1" do
    test "returns a 2-character string" do
      hash = Hashline.compute_line_hash("hello world")
      assert is_binary(hash)
      assert String.length(hash) == 2
    end

    test "produces consistent hashes for same content" do
      hash1 = Hashline.compute_line_hash("test content")
      hash2 = Hashline.compute_line_hash("test content")
      assert hash1 == hash2
    end

    test "normalizes whitespace before hashing" do
      hash1 = Hashline.compute_line_hash("hello world")
      hash2 = Hashline.compute_line_hash("  hello  world  ")
      hash3 = Hashline.compute_line_hash("hello\t\tworld")
      assert hash1 == hash2
      assert hash1 == hash3
    end

    test "removes carriage returns" do
      hash1 = Hashline.compute_line_hash("hello world")
      hash2 = Hashline.compute_line_hash("hello world\r")
      assert hash1 == hash2
    end

    test "empty string produces a hash" do
      hash = Hashline.compute_line_hash("")
      assert is_binary(hash)
      assert String.length(hash) == 2
    end
  end

  describe "normalize_line/1" do
    test "removes all whitespace" do
      assert Hashline.normalize_line("  hello  world  ") == "helloworld"
    end

    test "removes tabs and newlines" do
      assert Hashline.normalize_line("hello\t\tworld\n") == "helloworld"
    end

    test "handles empty string" do
      assert Hashline.normalize_line("") == ""
    end
  end

  describe "format_hash/1" do
    test "formats hash values using custom alphabet" do
      # 0 = Z, 1 = P, etc.
      assert Hashline.format_hash(0) == "ZZ"
      assert Hashline.format_hash(1) == "ZP"
      assert Hashline.format_hash(16) == "PZ"
      assert Hashline.format_hash(17) == "PP"
    end

    test "formats max value correctly" do
      # 255 = 15 * 16 + 15 = HH
      assert Hashline.format_hash(255) == "HH"
    end
  end

  # ============================================================================
  # Formatting Tests
  # ============================================================================

  describe "format_line_tag/2" do
    test "formats tag with line number and hash" do
      tag = Hashline.format_line_tag(5, "hello")
      assert Regex.match?(~r/^5#[ZPMQVRWSNKTXJBYH]{2}$/, tag)
    end

    test "different content produces different hashes" do
      tag1 = Hashline.format_line_tag(1, "hello")
      tag2 = Hashline.format_line_tag(1, "world")
      # Same line number, different content
      assert String.starts_with?(tag1, "1#")
      assert String.starts_with?(tag2, "1#")
      assert tag1 != tag2
    end
  end

  describe "format_hashlines/2" do
    test "formats content with hashline prefixes" do
      content = "line1\nline2\nline3"
      result = Hashline.format_hashlines(content)

      lines = String.split(result, "\n")
      assert length(lines) == 3

      # Each line should be formatted as LINENUM#HASH:CONTENT
      [line1, line2, line3] = lines

      assert Regex.match?(~r/^1#[ZPMQVRWSNKTXJBYH]{2}:line1$/, line1)
      assert Regex.match?(~r/^2#[ZPMQVRWSNKTXJBYH]{2}:line2$/, line2)
      assert Regex.match?(~r/^3#[ZPMQVRWSNKTXJBYH]{2}:line3$/, line3)
    end

    test "handles empty lines" do
      content = "line1\n\nline3"
      result = Hashline.format_hashlines(content)

      lines = String.split(result, "\n")
      assert length(lines) == 3

      # Empty line should still have a hash
      [line1, line2, line3] = lines
      assert Regex.match?(~r/^1#[ZPMQVRWSNKTXJBYH]{2}:line1$/, line1)
      assert Regex.match?(~r/^2#[ZPMQVRWSNKTXJBYH]{2}:$/, line2)
      assert Regex.match?(~r/^3#[ZPMQVRWSNKTXJBYH]{2}:line3$/, line3)
    end

    test "handles single line without newline" do
      content = "single line"
      result = Hashline.format_hashlines(content)

      assert Regex.match?(~r/^1#[ZPMQVRWSNKTXJBYH]{2}:single line$/, result)
    end

    test "supports custom start line" do
      content = "line1\nline2"
      result = Hashline.format_hashlines(content, 10)

      lines = String.split(result, "\n")
      [line1, line2] = lines

      assert Regex.match?(~r/^10#[ZPMQVRWSNKTXJBYH]{2}:line1$/, line1)
      assert Regex.match?(~r/^11#[ZPMQVRWSNKTXJBYH]{2}:line2$/, line2)
    end
  end

  # ============================================================================
  # Parsing Tests
  # ============================================================================

  describe "parse_tag/1" do
    test "parses basic tag format" do
      result = Hashline.parse_tag("5#ZZ")
      assert result.line == 5
      assert result.hash == "ZZ"
    end

    test "parses tag with whitespace" do
      result = Hashline.parse_tag("  5  #  ZZ  ")
      assert result.line == 5
      assert result.hash == "ZZ"
    end

    test "parses tag with prefix markers" do
      result = Hashline.parse_tag(">>> 5#ZZ")
      assert result.line == 5
      assert result.hash == "ZZ"
    end

    test "parses tag with plus/minus markers" do
      result = Hashline.parse_tag("+5#ZZ")
      assert result.line == 5

      result2 = Hashline.parse_tag("-5#ZZ")
      assert result2.line == 5
    end

    test "raises on invalid format" do
      assert_raise ArgumentError, ~r/Invalid line reference/, fn ->
        Hashline.parse_tag("invalid")
      end
    end

    test "raises on line number less than 1" do
      assert_raise ArgumentError, ~r/Line number must be >= 1/, fn ->
        Hashline.parse_tag("0#ZZ")
      end
    end

    test "raises on wrong hash characters" do
      assert_raise ArgumentError, ~r/Invalid line reference/, fn ->
        Hashline.parse_tag("5#xx")
      end
    end
  end

  # ============================================================================
  # Validation Tests
  # ============================================================================

  describe "validate_line_ref/2" do
    setup do
      file_lines = ["line 1", "line 2", "line 3"]
      {:ok, file_lines: file_lines}
    end

    test "returns :ok for valid reference", %{file_lines: file_lines} do
      hash = Hashline.compute_line_hash("line 2")
      ref = %{line: 2, hash: hash}
      assert Hashline.validate_line_ref(ref, file_lines) == :ok
    end

    test "raises HashlineMismatchError for stale hash", %{file_lines: file_lines} do
      ref = %{line: 2, hash: "ZZ"}

      assert_raise HashlineMismatchError, ~r/changed since last read/, fn ->
        Hashline.validate_line_ref(ref, file_lines)
      end
    end

    test "raises ArgumentError for out of bounds line", %{file_lines: file_lines} do
      ref = %{line: 10, hash: "ZZ"}

      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Hashline.validate_line_ref(ref, file_lines)
      end
    end

    test "raises ArgumentError for line 0", %{file_lines: file_lines} do
      ref = %{line: 0, hash: "ZZ"}

      assert_raise ArgumentError, ~r/does not exist/, fn ->
        Hashline.validate_line_ref(ref, file_lines)
      end
    end
  end

  # ============================================================================
  # Edit Operations - Set
  # ============================================================================

  describe "apply_edits/2 - set operation" do
    test "replaces a single line" do
      content = "line1\nline2\nline3"
      hash = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :set, tag: %{line: 2, hash: hash}, content: ["replaced"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nreplaced\nline3"
      assert result.first_changed_line == 2
    end

    test "set operation marks as noop if content unchanged" do
      content = "line1\nline2\nline3"
      hash = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :set, tag: %{line: 2, hash: hash}, content: ["line2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.noop_edits != nil
      assert length(result.noop_edits) == 1
      assert hd(result.noop_edits).loc == "2##{hash}"
    end

    test "returns error for hash mismatch" do
      content = "line1\nline2\nline3"

      edits = [
        %{op: :set, tag: %{line: 2, hash: "ZZ"}, content: ["replaced"]}
      ]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert error.message =~ "changed since last read"
      assert length(error.mismatches) == 1
    end
  end

  # ============================================================================
  # Edit Operations - Replace
  # ============================================================================

  describe "apply_edits/2 - replace operation" do
    test "replaces a range of lines" do
      content = "line1\nline2\nline3\nline4\nline5"
      hash2 = Hashline.compute_line_hash("line2")
      hash4 = Hashline.compute_line_hash("line4")

      edits = [
        %{op: :replace, first: %{line: 2, hash: hash2}, last: %{line: 4, hash: hash4}, content: ["new2", "new3"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew2\nnew3\nline5"
      assert result.first_changed_line == 2
    end

    test "replace single line (same as set)" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :replace, first: %{line: 2, hash: hash2}, last: %{line: 2, hash: hash2}, content: ["replaced"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nreplaced\nline3"
    end

    test "replace with more lines than removed" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :replace, first: %{line: 2, hash: hash2}, last: %{line: 2, hash: hash2}, content: ["a", "b", "c"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\na\nb\nc\nline3"
    end

    test "returns error for hash mismatch in range" do
      content = "line1\nline2\nline3\nline4\nline5"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :replace, first: %{line: 2, hash: hash2}, last: %{line: 4, hash: "ZZ"}, content: ["new"]}
      ]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 1
    end

    test "returns error for hash mismatch at both ends" do
      content = "line1\nline2\nline3\nline4\nline5"

      edits = [
        %{op: :replace, first: %{line: 2, hash: "ZZ"}, last: %{line: 4, hash: "YY"}, content: ["new"]}
      ]

      assert {:error, %HashlineMismatchError{} = error} = Hashline.apply_edits(content, edits)
      assert length(error.mismatches) == 2
    end

    test "raises for invalid range (first > last)" do
      content = "line1\nline2\nline3"
      hash3 = Hashline.compute_line_hash("line3")
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :replace, first: %{line: 3, hash: hash3}, last: %{line: 2, hash: hash2}, content: ["new"]}
      ]

      assert_raise ArgumentError, ~r/must be <= end line/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end
  end

  # ============================================================================
  # Edit Operations - Append
  # ============================================================================

  describe "apply_edits/2 - append operation" do
    test "appends after a specific line" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")

      edits = [
        %{op: :append, after: %{line: 1, hash: hash1}, content: ["inserted"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\ninserted\nline2\nline3"
      assert result.first_changed_line == 2
    end

    test "appends at EOF when after is nil" do
      content = "line1\nline2"

      edits = [
        %{op: :append, after: nil, content: ["appended"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nline2\nappended"
    end

    test "appending to empty file replaces it" do
      content = ""

      edits = [
        %{op: :append, after: nil, content: ["line1", "line2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nline2"
    end

    test "raises for empty content" do
      content = "line1\nline2"
      hash1 = Hashline.compute_line_hash("line1")

      edits = [
        %{op: :append, after: %{line: 1, hash: hash1}, content: []}
      ]

      assert_raise ArgumentError, ~r/non-empty content/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "returns error for hash mismatch" do
      content = "line1\nline2\nline3"

      edits = [
        %{op: :append, after: %{line: 1, hash: "ZZ"}, content: ["inserted"]}
      ]

      assert {:error, %HashlineMismatchError{}} = Hashline.apply_edits(content, edits)
    end

    test "strips anchor echo from appended content" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")

      # Content starts with echo of anchor line
      edits = [
        %{op: :append, after: %{line: 1, hash: hash1}, content: ["line1", "new1", "new2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew1\nnew2\nline2\nline3"
    end
  end

  # ============================================================================
  # Edit Operations - Prepend
  # ============================================================================

  describe "apply_edits/2 - prepend operation" do
    test "prepends before a specific line" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :prepend, before: %{line: 2, hash: hash2}, content: ["inserted"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\ninserted\nline2\nline3"
      assert result.first_changed_line == 2
    end

    test "prepends at BOF when before is nil" do
      content = "line1\nline2"

      edits = [
        %{op: :prepend, before: nil, content: ["prepended"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "prepended\nline1\nline2"
    end

    test "prepends to empty file replaces it" do
      content = ""

      edits = [
        %{op: :prepend, before: nil, content: ["line1", "line2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nline2"
    end

    test "raises for empty content" do
      content = "line1\nline2"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :prepend, before: %{line: 2, hash: hash2}, content: []}
      ]

      assert_raise ArgumentError, ~r/non-empty content/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "returns error for hash mismatch" do
      content = "line1\nline2\nline3"

      edits = [
        %{op: :prepend, before: %{line: 2, hash: "ZZ"}, content: ["inserted"]}
      ]

      assert {:error, %HashlineMismatchError{}} = Hashline.apply_edits(content, edits)
    end

    test "strips anchor echo from prepended content" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")

      # Content ends with echo of anchor line
      edits = [
        %{op: :prepend, before: %{line: 2, hash: hash2}, content: ["new1", "new2", "line2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew1\nnew2\nline2\nline3"
    end
  end

  # ============================================================================
  # Edit Operations - Insert
  # ============================================================================

  describe "apply_edits/2 - insert operation" do
    test "inserts between two lines" do
      content = "line1\nline2\nline3\nline4"
      hash1 = Hashline.compute_line_hash("line1")
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :insert, after: %{line: 1, hash: hash1}, before: %{line: 3, hash: hash3}, content: ["inserted"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nline2\ninserted\nline3\nline4"
      assert result.first_changed_line == 3
    end

    test "inserts multiple lines" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :insert, after: %{line: 1, hash: hash1}, before: %{line: 3, hash: hash3}, content: ["a", "b", "c"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nline2\na\nb\nc\nline3"
    end

    test "raises when after >= before" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :insert, after: %{line: 3, hash: hash3}, before: %{line: 2, hash: hash2}, content: ["x"]}
      ]

      assert_raise ArgumentError, ~r/after.*< before/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "raises for empty content" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :insert, after: %{line: 1, hash: hash1}, before: %{line: 3, hash: hash3}, content: []}
      ]

      assert_raise ArgumentError, ~r/non-empty content/, fn ->
        Hashline.apply_edits(content, edits)
      end
    end

    test "returns error for hash mismatch on after line" do
      content = "line1\nline2\nline3"
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :insert, after: %{line: 1, hash: "ZZ"}, before: %{line: 3, hash: hash3}, content: ["x"]}
      ]

      assert {:error, %HashlineMismatchError{}} = Hashline.apply_edits(content, edits)
    end

    test "returns error for hash mismatch on before line" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")

      edits = [
        %{op: :insert, after: %{line: 1, hash: hash1}, before: %{line: 3, hash: "ZZ"}, content: ["x"]}
      ]

      assert {:error, %HashlineMismatchError{}} = Hashline.apply_edits(content, edits)
    end

    test "strips boundary echo from inserted content" do
      content = "line1\nline2\nline3"
      hash1 = Hashline.compute_line_hash("line1")
      hash3 = Hashline.compute_line_hash("line3")

      # Content includes echo of boundary lines
      edits = [
        %{op: :insert, after: %{line: 1, hash: hash1}, before: %{line: 3, hash: hash3}, content: ["line1", "new", "line3"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      # Should strip the first echo (line1)
      assert result.content == "line1\nline2\nnew\nline3"
    end
  end

  # ============================================================================
  # Multiple Edits
  # ============================================================================

  describe "apply_edits/2 - multiple edits" do
    test "applies multiple edits in bottom-up order" do
      content = "line1\nline2\nline3\nline4\nline5"
      hash2 = Hashline.compute_line_hash("line2")
      hash4 = Hashline.compute_line_hash("line4")

      edits = [
        # This should apply second (lower line number)
        %{op: :set, tag: %{line: 2, hash: hash2}, content: ["new2"]},
        # This should apply first (higher line number)
        %{op: :set, tag: %{line: 4, hash: hash4}, content: ["new4"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew2\nline3\nnew4\nline5"
      assert result.first_changed_line == 2
    end

    test "applies edits of different types" do
      content = "line1\nline2\nline3\nline4"
      hash1 = Hashline.compute_line_hash("line1")
      hash3 = Hashline.compute_line_hash("line3")

      edits = [
        %{op: :append, after: %{line: 1, hash: hash1}, content: ["after1"]},
        %{op: :set, tag: %{line: 3, hash: hash3}, content: ["new3"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nafter1\nline2\nnew3\nline4"
    end

    test "deduplicates identical edits" do
      content = "line1\nline2\nline3"
      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :set, tag: %{line: 2, hash: hash2}, content: ["new2"]},
        %{op: :set, tag: %{line: 2, hash: hash2}, content: ["new2"]}
      ]

      assert {:ok, result} = Hashline.apply_edits(content, edits)
      assert result.content == "line1\nnew2\nline3"
    end

    test "empty edits list returns unchanged" do
      content = "line1\nline2\nline3"

      assert {:ok, result} = Hashline.apply_edits(content, [])
      assert result.content == content
      assert result.first_changed_line == nil
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "HashlineMismatchError" do
    test "exception contains formatted message" do
      file_lines = ["line1", "line2", "line3", "line4", "line5"]
      hash = Hashline.compute_line_hash("line2")

      mismatches = [
        %{line: 2, expected: "ZZ", actual: hash}
      ]

      error = HashlineMismatchError.exception(mismatches: mismatches, file_lines: file_lines)

      assert error.message =~ "1 line has changed since last read"
      assert error.message =~ ">>>"
      assert error.message =~ "2##{hash}"
      assert error.remaps["2#ZZ"] == "2##{hash}"
    end

    test "exception with multiple mismatches" do
      file_lines = ["line1", "line2", "line3", "line4", "line5"]
      hash2 = Hashline.compute_line_hash("line2")
      hash4 = Hashline.compute_line_hash("line4")

      mismatches = [
        %{line: 2, expected: "ZZ", actual: hash2},
        %{line: 4, expected: "YY", actual: hash4}
      ]

      error = HashlineMismatchError.exception(mismatches: mismatches, file_lines: file_lines)

      assert error.message =~ "2 lines have changed since last read"
      assert error.remaps["2#ZZ"] == "2##{hash2}"
      assert error.remaps["4#YY"] == "4##{hash4}"
    end

    test "includes context lines around mismatches" do
      file_lines = ["line1", "line2", "line3", "line4", "line5"]
      hash3 = Hashline.compute_line_hash("line3")

      mismatches = [%{line: 3, expected: "ZZ", actual: hash3}]

      error = HashlineMismatchError.exception(mismatches: mismatches, file_lines: file_lines)

      # Should show context (lines 1-5 for a file with 5 lines, line 3 mismatch)
      assert error.message =~ "line1"
      assert error.message =~ "line2"
      assert error.message =~ ">>>"  # line 3 with marker
      assert error.message =~ "line4"
      assert error.message =~ "line5"
    end

    test "shows gap separator for non-contiguous regions" do
      file_lines = Enum.map(1..20, fn i -> "line#{i}" end)
      hash5 = Hashline.compute_line_hash("line5")
      hash15 = Hashline.compute_line_hash("line15")

      mismatches = [
        %{line: 5, expected: "ZZ", actual: hash5},
        %{line: 15, expected: "YY", actual: hash15}
      ]

      error = HashlineMismatchError.exception(mismatches: mismatches, file_lines: file_lines)

      assert error.message =~ "..."
    end
  end

  describe "format_mismatch_message/2" do
    test "formats single mismatch with context" do
      file_lines = ["a", "b", "c", "d", "e"]
      hash = Hashline.compute_line_hash("c")

      mismatches = [%{line: 3, expected: "ZZ", actual: hash}]

      message = Hashline.format_mismatch_message(mismatches, file_lines)

      assert message =~ "1 line has changed"
      assert message =~ ">>> 3##{hash}:c"
      assert message =~ "    1#"
      assert message =~ "    2#"
      assert message =~ "    4#"
      assert message =~ "    5#"
    end

    test "formats multiple mismatches" do
      file_lines = ["a", "b", "c", "d", "e"]
      hash2 = Hashline.compute_line_hash("b")
      hash4 = Hashline.compute_line_hash("d")

      mismatches = [
        %{line: 2, expected: "ZZ", actual: hash2},
        %{line: 4, expected: "YY", actual: hash4}
      ]

      message = Hashline.format_mismatch_message(mismatches, file_lines)

      assert message =~ "2 lines have changed"
      assert message =~ ">>> 2##{hash2}:b"
      assert message =~ ">>> 4##{hash4}:d"
    end
  end

  # ============================================================================
  # Sort Edits
  # ============================================================================

  describe "sort_edits/2" do
    test "sorts edits by line number descending" do
      content = "line1\nline2\nline3\nline4\nline5"
      file_lines = String.split(content, "\n")

      hash2 = Hashline.compute_line_hash("line2")
      hash4 = Hashline.compute_line_hash("line4")

      edits = [
        %{op: :set, tag: %{line: 2, hash: hash2}, content: ["new2"]},
        %{op: :set, tag: %{line: 4, hash: hash4}, content: ["new4"]}
      ]

      sorted = Hashline.sort_edits(edits, file_lines)

      # Should be sorted 4 then 2
      assert hd(sorted).tag.line == 4
      assert Enum.at(sorted, 1).tag.line == 2
    end

    test "append operations have lower precedence than set at same line" do
      content = "line1\nline2"
      file_lines = String.split(content, "\n")

      hash1 = Hashline.compute_line_hash("line1")

      edits = [
        %{op: :append, after: %{line: 1, hash: hash1}, content: ["appended"]},
        %{op: :set, tag: %{line: 1, hash: hash1}, content: ["new1"]}
      ]

      sorted = Hashline.sort_edits(edits, file_lines)

      # Set should come before append at same line
      assert hd(sorted).op == :set
      assert Enum.at(sorted, 1).op == :append
    end

    test "EOF append is sorted after all other edits" do
      content = "line1\nline2"
      file_lines = String.split(content, "\n")

      hash2 = Hashline.compute_line_hash("line2")

      edits = [
        %{op: :append, after: nil, content: ["eof"]},
        %{op: :set, tag: %{line: 2, hash: hash2}, content: ["new2"]}
      ]

      sorted = Hashline.sort_edits(edits, file_lines)

      # EOF append sorts at line 3 (after line 2), set is at line 2
      # EOF append should come first because line 3 > line 2
      assert hd(sorted).op == :append
      assert Enum.at(sorted, 1).op == :set
    end
  end
end
