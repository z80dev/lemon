defmodule LemonGateway.Telegram.FormatterTest do
  @moduledoc """
  Comprehensive tests for LemonGateway.Telegram.Formatter module.

  Tests cover:
  - Text escaping for Telegram MarkdownV2 format
  - Special character escaping
  - Code block and inline code handling
  - Bold/italic/underline character escaping
  - Link formatting character escaping
  - Mention formatting (@username)
  - Hashtag handling
  - Emoji handling
  - Resume line preservation
  - Multi-line text handling
  - Edge cases and boundary conditions
  - prepare_for_telegram/1 function
  """
  use ExUnit.Case, async: true

  alias LemonGateway.Telegram.Formatter

  describe "escape_markdown/1 basic escaping" do
    test "returns empty string unchanged" do
      assert Formatter.escape_markdown("") == ""
    end

    test "returns nil as empty string" do
      assert Formatter.escape_markdown(nil) == ""
    end

    test "returns plain text unchanged" do
      assert Formatter.escape_markdown("Hello world") == "Hello world"
    end

    test "returns alphanumeric text unchanged" do
      text = "abc123XYZ"
      assert Formatter.escape_markdown(text) == text
    end

    test "preserves spaces" do
      text = "Hello    world"
      assert Formatter.escape_markdown(text) == text
    end

    test "preserves tabs" do
      text = "Hello\tworld"
      assert Formatter.escape_markdown(text) == text
    end

    test "preserves newlines" do
      text = "Line 1\nLine 2\nLine 3"
      result = Formatter.escape_markdown(text)
      assert result == "Line 1\nLine 2\nLine 3"
    end
  end

  describe "escape_markdown/1 special characters" do
    test "escapes underscore" do
      assert Formatter.escape_markdown("_italic_") == "\\_italic\\_"
    end

    test "escapes asterisk" do
      assert Formatter.escape_markdown("*bold*") == "\\*bold\\*"
    end

    test "escapes square brackets" do
      assert Formatter.escape_markdown("[link]") == "\\[link\\]"
    end

    test "escapes parentheses" do
      assert Formatter.escape_markdown("(text)") == "\\(text\\)"
    end

    test "escapes tilde" do
      assert Formatter.escape_markdown("~strikethrough~") == "\\~strikethrough\\~"
    end

    test "escapes backtick" do
      assert Formatter.escape_markdown("`code`") == "\\`code\\`"
    end

    test "escapes greater than" do
      assert Formatter.escape_markdown(">quote") == "\\>quote"
    end

    test "escapes hash" do
      assert Formatter.escape_markdown("#hashtag") == "\\#hashtag"
    end

    test "escapes plus" do
      assert Formatter.escape_markdown("+1") == "\\+1"
    end

    test "escapes minus/hyphen" do
      assert Formatter.escape_markdown("a-b") == "a\\-b"
    end

    test "escapes equals" do
      assert Formatter.escape_markdown("a=b") == "a\\=b"
    end

    test "escapes pipe" do
      assert Formatter.escape_markdown("a|b") == "a\\|b"
    end

    test "escapes curly braces" do
      assert Formatter.escape_markdown("{text}") == "\\{text\\}"
    end

    test "escapes period" do
      assert Formatter.escape_markdown("Hello.") == "Hello\\."
    end

    test "escapes exclamation mark" do
      assert Formatter.escape_markdown("Hello!") == "Hello\\!"
    end
  end

  describe "escape_markdown/1 multiple special characters" do
    test "escapes multiple different special characters" do
      text = "*bold* and _italic_"
      expected = "\\*bold\\* and \\_italic\\_"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes all markdown special characters in one string" do
      text = "_*[]()~`>#+-=|{}.!"
      expected = "\\_\\*\\[\\]\\(\\)\\~\\`\\>\\#\\+\\-\\=\\|\\{\\}\\.\\!"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes repeated same character" do
      text = "***bold***"
      expected = "\\*\\*\\*bold\\*\\*\\*"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes interleaved special characters" do
      text = "*_*_*_"
      expected = "\\*\\_\\*\\_\\*\\_"
      assert Formatter.escape_markdown(text) == expected
    end
  end

  describe "escape_markdown/1 inline code formatting" do
    test "escapes backticks for inline code" do
      text = "`code`"
      assert Formatter.escape_markdown(text) == "\\`code\\`"
    end

    test "escapes triple backticks for code blocks" do
      text = "```code```"
      assert Formatter.escape_markdown(text) == "\\`\\`\\`code\\`\\`\\`"
    end

    test "escapes code block with language specifier" do
      text = "```elixir\ndefmodule Foo do\nend\n```"
      result = Formatter.escape_markdown(text)
      assert String.starts_with?(result, "\\`\\`\\`elixir")
    end
  end

  describe "escape_markdown/1 bold/italic/underline" do
    test "escapes bold markdown syntax" do
      text = "**bold text**"
      expected = "\\*\\*bold text\\*\\*"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes italic with underscore" do
      text = "_italic text_"
      expected = "\\_italic text\\_"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes italic with asterisk" do
      text = "*italic text*"
      expected = "\\*italic text\\*"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes underline syntax" do
      text = "__underline__"
      expected = "\\_\\_underline\\_\\_"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes strikethrough syntax" do
      text = "~~strikethrough~~"
      expected = "\\~\\~strikethrough\\~\\~"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes combined formatting" do
      text = "***bold italic***"
      expected = "\\*\\*\\*bold italic\\*\\*\\*"
      assert Formatter.escape_markdown(text) == expected
    end
  end

  describe "escape_markdown/1 link formatting" do
    test "escapes markdown link syntax" do
      text = "[Link Text](https://example.com)"
      expected = "\\[Link Text\\]\\(https://example\\.com\\)"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes URL with special characters" do
      text = "[Link](https://example.com/path?query=1&foo=bar)"
      result = Formatter.escape_markdown(text)
      assert String.contains?(result, "\\[Link\\]")
      assert String.contains?(result, "\\(")
      assert String.contains?(result, "\\)")
    end

    test "escapes reference-style link" do
      text = "[Link][ref]"
      expected = "\\[Link\\]\\[ref\\]"
      assert Formatter.escape_markdown(text) == expected
    end

    test "escapes bare URL with period" do
      text = "https://example.com"
      result = Formatter.escape_markdown(text)
      assert String.contains?(result, "\\.")
    end
  end

  describe "escape_markdown/1 mention formatting (@username)" do
    test "preserves at symbol (not in escape list)" do
      text = "@username"
      assert Formatter.escape_markdown(text) == "@username"
    end

    test "handles mention with underscore in username" do
      text = "@user_name"
      assert Formatter.escape_markdown(text) == "@user\\_name"
    end

    test "handles multiple mentions" do
      text = "@alice @bob @charlie"
      assert Formatter.escape_markdown(text) == "@alice @bob @charlie"
    end

    test "handles mention followed by special character" do
      text = "@user!"
      assert Formatter.escape_markdown(text) == "@user\\!"
    end
  end

  describe "escape_markdown/1 hashtag handling" do
    test "escapes hash symbol in hashtag" do
      text = "#hashtag"
      assert Formatter.escape_markdown(text) == "\\#hashtag"
    end

    test "escapes multiple hashtags" do
      text = "#one #two #three"
      result = Formatter.escape_markdown(text)
      assert result == "\\#one \\#two \\#three"
    end

    test "escapes hashtag with underscore" do
      text = "#hash_tag"
      assert Formatter.escape_markdown(text) == "\\#hash\\_tag"
    end
  end

  describe "escape_markdown/1 emoji handling" do
    test "preserves simple emoji" do
      text = "Hello \u{1F600}"
      assert Formatter.escape_markdown(text) == "Hello \u{1F600}"
    end

    test "preserves multiple emojis" do
      text = "\u{1F600}\u{1F389}\u{1F680}"
      assert Formatter.escape_markdown(text) == "\u{1F600}\u{1F389}\u{1F680}"
    end

    test "preserves emoji with text" do
      text = "Hello \u{1F600} World"
      assert Formatter.escape_markdown(text) == "Hello \u{1F600} World"
    end

    test "preserves flag emoji" do
      text = "\u{1F1FA}\u{1F1F8}"
      assert Formatter.escape_markdown(text) == "\u{1F1FA}\u{1F1F8}"
    end

    test "preserves emoji with skin tone modifier" do
      text = "\u{1F44B}\u{1F3FD}"
      assert Formatter.escape_markdown(text) == "\u{1F44B}\u{1F3FD}"
    end

    test "preserves ZWJ sequence emoji" do
      text = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      assert Formatter.escape_markdown(text) == "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    end

    test "escapes special characters around emoji" do
      text = "*\u{1F600}*"
      assert Formatter.escape_markdown(text) == "\\*\u{1F600}\\*"
    end
  end

  describe "escape_markdown/1 resume line preservation" do
    test "preserves /resume line unchanged" do
      text = "/resume claude:abc123"
      assert Formatter.escape_markdown(text) == "/resume claude:abc123"
    end

    test "preserves /resume line with special characters" do
      text = "/resume session_id-123"
      assert Formatter.escape_markdown(text) == "/resume session_id-123"
    end

    test "preserves /resume line at start of multiline text" do
      text = "/resume abc123\nSome other text"
      result = Formatter.escape_markdown(text)
      lines = String.split(result, "\n")
      assert Enum.at(lines, 0) == "/resume abc123"
    end

    test "preserves /resume line in middle of text" do
      text = "Line 1\n/resume abc123\nLine 3"
      result = Formatter.escape_markdown(text)
      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) == "/resume abc123"
    end

    test "preserves /resume line at end of text" do
      text = "Some text\n/resume abc123"
      result = Formatter.escape_markdown(text)
      assert String.ends_with?(result, "/resume abc123")
    end

    test "preserves multiple /resume lines" do
      text = "/resume abc123\n/resume def456"
      result = Formatter.escape_markdown(text)
      assert result == "/resume abc123\n/resume def456"
    end

    test "preserves /resume with leading whitespace" do
      text = "  /resume abc123"
      # Leading whitespace means trim won't match, so it gets escaped
      result = Formatter.escape_markdown(text)
      assert String.contains?(result, "/resume abc123")
    end

    test "escapes non-resume lines normally" do
      text = "resume abc123"
      result = Formatter.escape_markdown(text)
      # "resume" without "/" is normal text, no special treatment
      assert result == "resume abc123"
    end
  end

  describe "escape_markdown/1 multi-line text" do
    test "handles multiple lines with different content" do
      text = "Line 1 with *bold*\nLine 2 with _italic_\nLine 3 plain"
      result = Formatter.escape_markdown(text)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == "Line 1 with \\*bold\\*"
      assert Enum.at(lines, 1) == "Line 2 with \\_italic\\_"
      assert Enum.at(lines, 2) == "Line 3 plain"
    end

    test "handles empty lines" do
      text = "Line 1\n\nLine 3"
      result = Formatter.escape_markdown(text)
      assert result == "Line 1\n\nLine 3"
    end

    test "handles lines with only special characters" do
      text = "***\n---\n___"
      result = Formatter.escape_markdown(text)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == "\\*\\*\\*"
      assert Enum.at(lines, 1) == "\\-\\-\\-"
      assert Enum.at(lines, 2) == "\\_\\_\\_"
    end

    test "handles mixed resume and regular lines" do
      text = "Hello *world*!\n/resume abc123\nGoodbye _everyone_!"
      result = Formatter.escape_markdown(text)
      lines = String.split(result, "\n")

      assert Enum.at(lines, 0) == "Hello \\*world\\*\\!"
      assert Enum.at(lines, 1) == "/resume abc123"
      assert Enum.at(lines, 2) == "Goodbye \\_everyone\\_\\!"
    end
  end

  describe "escape_markdown/1 blockquote handling" do
    test "escapes greater than at line start" do
      text = "> This is a quote"
      assert Formatter.escape_markdown(text) == "\\> This is a quote"
    end

    test "escapes nested blockquotes" do
      text = ">> Nested quote"
      assert Formatter.escape_markdown(text) == "\\>\\> Nested quote"
    end

    test "escapes multiline blockquote" do
      text = "> Line 1\n> Line 2"
      result = Formatter.escape_markdown(text)
      assert result == "\\> Line 1\n\\> Line 2"
    end
  end

  describe "escape_markdown/1 list formatting" do
    test "escapes dash for unordered list" do
      text = "- Item 1\n- Item 2"
      result = Formatter.escape_markdown(text)
      assert result == "\\- Item 1\n\\- Item 2"
    end

    test "escapes plus for unordered list" do
      text = "+ Item 1\n+ Item 2"
      result = Formatter.escape_markdown(text)
      assert result == "\\+ Item 1\n\\+ Item 2"
    end

    test "escapes period in ordered list" do
      text = "1. First\n2. Second"
      result = Formatter.escape_markdown(text)
      assert result == "1\\. First\n2\\. Second"
    end
  end

  describe "escape_markdown/1 unicode handling" do
    test "preserves Chinese characters" do
      text = "\u{4E2D}\u{6587}"
      assert Formatter.escape_markdown(text) == "\u{4E2D}\u{6587}"
    end

    test "preserves Arabic characters" do
      text = "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
      assert Formatter.escape_markdown(text) == "\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"
    end

    test "preserves Cyrillic characters" do
      text = "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
      assert Formatter.escape_markdown(text) == "\u{041F}\u{0440}\u{0438}\u{0432}\u{0435}\u{0442}"
    end

    test "handles mixed scripts with special characters" do
      text = "Hello *\u{4E16}\u{754C}*!"
      result = Formatter.escape_markdown(text)
      assert result == "Hello \\*\u{4E16}\u{754C}\\*\\!"
    end

    test "preserves combining characters" do
      text = "e\u{0301}"
      assert Formatter.escape_markdown(text) == "e\u{0301}"
    end

    test "ensures result is valid UTF-8" do
      text = "Test \u{1F600} emoji \u{4E2D}\u{6587} mixed"
      result = Formatter.escape_markdown(text)
      assert String.valid?(result)
    end
  end

  describe "escape_markdown/1 edge cases" do
    test "handles single character special char" do
      assert Formatter.escape_markdown("*") == "\\*"
      assert Formatter.escape_markdown("_") == "\\_"
      assert Formatter.escape_markdown(".") == "\\."
    end

    test "handles string of only special characters" do
      text = "*.!#"
      assert Formatter.escape_markdown(text) == "\\*\\.\\!\\#"
    end

    test "handles very long line" do
      text = String.duplicate("a*b", 1000)
      result = Formatter.escape_markdown(text)
      assert String.valid?(result)
      assert String.contains?(result, "\\*")
    end

    test "handles line with only whitespace" do
      text = "   "
      assert Formatter.escape_markdown(text) == "   "
    end

    test "handles tab characters" do
      text = "col1\tcol2\tcol3"
      assert Formatter.escape_markdown(text) == "col1\tcol2\tcol3"
    end

    test "handles carriage return" do
      text = "line1\r\nline2"
      result = Formatter.escape_markdown(text)
      # \r is not a newline for splitting, so it stays in line1
      assert String.contains?(result, "line1")
      assert String.contains?(result, "line2")
    end

    test "handles null bytes gracefully" do
      text = "hello\x00world"
      result = Formatter.escape_markdown(text)
      assert is_binary(result)
    end
  end

  describe "escape_markdown/1 real-world examples" do
    test "escapes typical agent response with tool result" do
      text =
        "I found the file `config.ex` with the following content:\n```elixir\ndefmodule Config do\n  @version \"1.0.0\"\nend\n```"

      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\`config\\.ex\\`")
      assert String.contains?(result, "\\`\\`\\`elixir")
    end

    test "escapes error message with special characters" do
      text = "Error: File not found (path: /home/user/.config)"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\(path:")
      assert String.contains?(result, "\\.config\\)")
    end

    test "escapes message with URL" do
      text = "See documentation at https://docs.example.com/api#section"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\.com")
      assert String.contains?(result, "\\#section")
    end

    test "escapes mathematical expression" do
      text = "The formula is: a + b = c * d"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\+")
      assert String.contains?(result, "\\=")
      assert String.contains?(result, "\\*")
    end

    test "escapes git diff output" do
      text = "+++ b/file.ex\n--- a/file.ex\n@@ -1,3 +1,4 @@"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\+\\+\\+")
      assert String.contains?(result, "\\-\\-\\-")
    end

    test "escapes JSON snippet" do
      text = "{\"key\": \"value\", \"count\": 42}"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\{")
      assert String.contains?(result, "\\}")
    end

    test "escapes shell command with pipes and redirects" do
      text = "Run: cat file.txt | grep pattern > output.txt"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\|")
      assert String.contains?(result, "\\>")
      assert String.contains?(result, "\\.")
    end
  end

  describe "escape_markdown/1 tool result formatting" do
    test "escapes file read tool output" do
      text = "Contents of /path/to/file.ex:\n```\ndefmodule Foo do\n  def bar, do: :ok\nend\n```"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "file\\.ex")
      assert String.contains?(result, "\\`\\`\\`")
    end

    test "escapes search tool output" do
      text = "Found 3 matches:\n- file1.ex:10\n- file2.ex:25\n- file3.ex:42"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\-")
      assert String.contains?(result, "\\.")
    end

    test "escapes bash tool output with exit code" do
      text =
        "Command output:\n$ ls -la\ntotal 16\n-rw-r--r--  1 user  staff  123 Jan  1 00:00 file.txt"

      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\-la")
      assert String.contains?(result, "\\-rw\\-r\\-\\-r\\-\\-")
    end
  end

  describe "escape_markdown/1 agent response formatting" do
    test "escapes thinking/explanation text" do
      text =
        "Let me analyze this:\n1. First, check the config\n2. Then, update the module\n3. Finally, run tests"

      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "1\\.")
      assert String.contains?(result, "2\\.")
      assert String.contains?(result, "3\\.")
    end

    test "escapes code suggestion" do
      text = "Try replacing:\n`old_function()` with `new_function()`"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\`old\\_function\\(\\)\\`")
      assert String.contains?(result, "\\`new\\_function\\(\\)\\`")
    end

    test "escapes completion message with resume line" do
      text = "Task completed successfully!\n/resume session123"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\!")
      assert String.ends_with?(result, "/resume session123")
    end
  end

  describe "escape_markdown/1 error message formatting" do
    test "escapes compilation error" do
      text = "** (CompileError) lib/foo.ex:10: undefined function bar/1"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\*\\*")
      assert String.contains?(result, "\\(CompileError\\)")
      assert String.contains?(result, "foo\\.ex")
    end

    test "escapes runtime error" do
      text =
        "** (RuntimeError) Something went wrong!\n    (myapp 0.1.0) lib/myapp.ex:15: MyApp.run/0"

      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\*\\*")
      assert String.contains?(result, "\\!")
      assert String.contains?(result, "\\(myapp 0\\.1\\.0\\)")
    end

    test "escapes pattern match error" do
      text = "** (MatchError) no match of right hand side value: {:error, :not_found}"
      result = Formatter.escape_markdown(text)

      assert String.contains?(result, "\\{")
      assert String.contains?(result, "\\}")
    end
  end

  describe "prepare_for_telegram/1" do
    test "returns tuple with escaped text and parse mode" do
      text = "Hello *world*!"
      {escaped, parse_mode} = Formatter.prepare_for_telegram(text)

      assert escaped == "Hello \\*world\\*\\!"
      assert parse_mode == "MarkdownV2"
    end

    test "handles empty string" do
      {escaped, parse_mode} = Formatter.prepare_for_telegram("")

      assert escaped == ""
      assert parse_mode == "MarkdownV2"
    end

    test "handles nil" do
      {escaped, parse_mode} = Formatter.prepare_for_telegram(nil)

      assert escaped == ""
      assert parse_mode == "MarkdownV2"
    end

    test "handles plain text" do
      {escaped, parse_mode} = Formatter.prepare_for_telegram("Hello world")

      assert escaped == "Hello world"
      assert parse_mode == "MarkdownV2"
    end

    test "handles complex message" do
      text = "Found file `test.ex`:\n```\ncode\n```\n/resume abc"
      {escaped, parse_mode} = Formatter.prepare_for_telegram(text)

      assert parse_mode == "MarkdownV2"
      assert String.contains?(escaped, "\\`test\\.ex\\`")
      assert String.ends_with?(escaped, "/resume abc")
    end

    test "always returns MarkdownV2 parse mode" do
      texts = [
        "plain",
        "*bold*",
        "_italic_",
        "[link](url)",
        "/resume abc"
      ]

      for text <- texts do
        {_escaped, parse_mode} = Formatter.prepare_for_telegram(text)
        assert parse_mode == "MarkdownV2"
      end
    end
  end

  describe "escape_markdown/1 boundary conditions" do
    test "handles exactly one character before special char" do
      assert Formatter.escape_markdown("a*") == "a\\*"
    end

    test "handles exactly one character after special char" do
      assert Formatter.escape_markdown("*a") == "\\*a"
    end

    test "handles special char at start of line" do
      text = "*start of line"
      assert Formatter.escape_markdown(text) == "\\*start of line"
    end

    test "handles special char at end of line" do
      text = "end of line*"
      assert Formatter.escape_markdown(text) == "end of line\\*"
    end

    test "handles consecutive lines with special chars" do
      text = "*line1*\n*line2*"
      result = Formatter.escape_markdown(text)
      assert result == "\\*line1\\*\n\\*line2\\*"
    end

    test "handles empty lines between content" do
      text = "line1\n\n\nline4"
      result = Formatter.escape_markdown(text)
      assert result == "line1\n\n\nline4"
    end
  end

  describe "escape_markdown/1 long message handling" do
    test "handles message at Telegram limit (4096 chars)" do
      text = String.duplicate("a*", 2048)
      result = Formatter.escape_markdown(text)

      assert String.valid?(result)
      # Each "a*" becomes "a\*", so length doubles for special chars
      assert String.length(result) > String.length(text)
    end

    test "handles message exceeding Telegram limit" do
      text = String.duplicate("Hello! ", 1000)
      result = Formatter.escape_markdown(text)

      assert String.valid?(result)
      assert String.contains?(result, "\\!")
    end

    test "handles very long line without breaks" do
      text = String.duplicate("*", 5000)
      result = Formatter.escape_markdown(text)

      assert String.valid?(result)
      # All asterisks should be escaped
      refute String.contains?(result, "**")
      assert String.starts_with?(result, "\\*")
    end
  end

  describe "escape_markdown/1 multi-part message scenarios" do
    test "handles message that would need splitting" do
      # Simulate a long agent response
      parts = for i <- 1..100, do: "Step #{i}: Do something *important* here!\n"
      text = Enum.join(parts)

      result = Formatter.escape_markdown(text)

      assert String.valid?(result)
      assert String.contains?(result, "\\*important\\*")
      assert String.contains?(result, "\\!")
    end

    test "handles alternating resume and content lines" do
      text = """
      Content line 1
      /resume abc123
      Content line 2
      /resume def456
      Content line 3
      """

      result = Formatter.escape_markdown(text)

      lines = String.split(result, "\n")
      assert Enum.at(lines, 1) == "/resume abc123"
      assert Enum.at(lines, 3) == "/resume def456"
    end
  end
end
