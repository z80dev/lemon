defmodule Ai.TextTest do
  use ExUnit.Case, async: true

  alias Ai.Text

  describe "truncate_chars/3" do
    test "keeps short text and truncates long text by characters" do
      assert Text.truncate_chars("hello", 5) == "hello"
      assert Text.truncate_chars("hello!", 5) == "hello..."
    end

    test "supports custom markers and forced truncation" do
      assert Text.truncate_chars("abcdef", 3, marker: "--") == "abc--"
      assert Text.truncate_chars("éé", 3, force: true) == "éé..."
    end

    test "boundary cases: empty string and exactly-at-limit input" do
      assert Text.truncate_chars("", 5) == ""
      assert Text.truncate_chars("abcde", 5) == "abcde"
      assert Text.truncate_chars("abcdef", 5) == "abcde..."
    end
  end

  describe "shared defaults (characterization)" do
    # Many delegating call sites (context_guardrails, bash_executor,
    # presentation) rely on these defaults matching their former inline
    # constants. Changing them silently changes behavior across apps.
    test "truncate_middle_utf8 reserves 256 bytes for the marker and gives 70% to the head" do
      text = String.duplicate("a", 2_000)
      out = Text.truncate_middle_utf8(text, 1_000, marker: fn removed -> "<#{removed}>" end)

      # budget = 1000 - 256 = 744; head = 70% of 744 = 520
      assert String.starts_with?(out, String.duplicate("a", 520))
      refute String.starts_with?(out, String.duplicate("a", 521))
    end

    test "truncate_tail defaults keep byte-identical notice format" do
      content = Enum.map_join(1..3, "\n", &"line #{&1}")

      {out, true, _meta} = Text.truncate_tail(content, max_bytes: 100, max_lines: 2)
      assert out == "[Output truncated. Total: 3 lines, 20 bytes]\n\nline 2\nline 3"
    end
  end

  describe "truncate_bytes_utf8/3" do
    test "trims invalid UTF-8 boundary before appending marker" do
      assert Text.truncate_bytes_utf8("éabc", 1, marker: fn removed -> "...#{removed}" end) ==
               "...5"
    end

    test "supports markerless byte truncation" do
      assert Text.truncate_bytes_utf8("éabc", 3, marker: "") == "éa"
    end
  end

  describe "truncate_middle_utf8/3" do
    test "keeps short text unchanged" do
      assert Text.truncate_middle_utf8("short", 5) == "short"
    end

    test "preserves UTF-8 validity when multibyte characters straddle the cut" do
      text = "é" <> String.duplicate("a", 300) <> "é"

      truncated =
        Text.truncate_middle_utf8(text, 60,
          marker: fn removed -> "\n... [TRUNCATED #{removed} bytes] ...\n" end
        )

      assert String.valid?(truncated)
      assert byte_size(truncated) <= 60
      assert truncated =~ "TRUNCATED"
    end
  end

  describe "truncate_tail/2" do
    test "keeps content within byte and line budgets" do
      assert Text.truncate_tail("a\nb", max_bytes: 10, max_lines: 2) ==
               {"a\nb", false,
                %{total_lines: 2, total_bytes: 3, output_lines: 2, output_bytes: 3}}
    end

    test "keeps the last lines and prepends the default notice" do
      content = "one\ntwo\nthree"

      assert Text.truncate_tail(content, max_bytes: 100, max_lines: 2) ==
               {"[Output truncated. Total: 3 lines, 13 bytes]\n\ntwo\nthree", true,
                %{total_lines: 3, total_bytes: 13, output_lines: 2, output_bytes: 9}}
    end

    test "keeps the last bytes after line truncation" do
      content = "12345\nabcdef"

      assert Text.truncate_tail(content, max_bytes: 4, max_lines: 10) ==
               {"[Output truncated. Total: 2 lines, 12 bytes]\n\ncdef", true,
                %{total_lines: 2, total_bytes: 12, output_lines: 1, output_bytes: 4}}
    end
  end
end
