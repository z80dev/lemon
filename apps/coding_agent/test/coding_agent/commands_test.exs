defmodule CodingAgent.CommandsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Commands

  @moduletag :tmp_dir

  describe "list/1" do
    test "returns empty list when no commands exist", %{tmp_dir: tmp_dir} do
      assert Commands.list(tmp_dir) == []
    end

    test "loads commands from project directory", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Test command
      ---

      This is the template.
      """

      File.write!(Path.join(cmd_dir, "test.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1

      cmd = hd(commands)
      assert cmd.name == "test"
      assert cmd.description == "Test command"
      assert String.contains?(cmd.template, "This is the template")
    end

    test "handles commands without frontmatter", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      File.write!(Path.join(cmd_dir, "simple.md"), "Just a template")

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1

      cmd = hd(commands)
      assert cmd.name == "simple"
      assert cmd.description == ""
      assert cmd.template == "Just a template"
    end

    test "parses model field", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Uses opus
      model: opus
      ---

      Template here.
      """

      File.write!(Path.join(cmd_dir, "with-model.md"), content)

      commands = Commands.list(tmp_dir)
      assert hd(commands).model == "opus"
    end

    test "parses subtask field", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: A subtask command
      subtask: true
      ---

      Run as subtask.
      """

      File.write!(Path.join(cmd_dir, "subtask.md"), content)

      commands = Commands.list(tmp_dir)
      assert hd(commands).subtask == true
    end

    test "defaults subtask to false", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Normal command
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "normal.md"), content)

      commands = Commands.list(tmp_dir)
      assert hd(commands).subtask == false
    end

    test "loads multiple commands", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      for name <- ["alpha", "beta", "gamma"] do
        content = """
        ---
        description: Command #{name}
        ---

        Template for #{name}.
        """

        File.write!(Path.join(cmd_dir, "#{name}.md"), content)
      end

      commands = Commands.list(tmp_dir)
      assert length(commands) == 3
      names = Enum.map(commands, & &1.name)
      assert "alpha" in names
      assert "beta" in names
      assert "gamma" in names
    end
  end

  describe "get/2" do
    test "returns command by name", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: My command
      ---

      My template.
      """

      File.write!(Path.join(cmd_dir, "mycommand.md"), content)

      cmd = Commands.get(tmp_dir, "mycommand")
      assert cmd != nil
      assert cmd.name == "mycommand"
    end

    test "returns nil for non-existent command", %{tmp_dir: tmp_dir} do
      assert Commands.get(tmp_dir, "nonexistent") == nil
    end
  end

  describe "expand/2" do
    test "expands $ARGUMENTS placeholder" do
      cmd = %{template: "Run with: $ARGUMENTS"}
      result = Commands.expand(cmd, ["arg1", "arg2", "arg3"])
      assert result == "Run with: arg1 arg2 arg3"
    end

    test "expands positional placeholders" do
      cmd = %{template: "Fix $1 in $2"}
      result = Commands.expand(cmd, ["bug", "login.ex"])
      assert result == "Fix bug in login.ex"
    end

    test "handles missing positional args" do
      cmd = %{template: "Value: $1, Other: $2"}
      result = Commands.expand(cmd, ["only-one"])
      assert result == "Value: only-one, Other: $2"
    end

    test "handles empty args" do
      cmd = %{template: "No args: $ARGUMENTS"}
      result = Commands.expand(cmd, [])
      assert result == "No args: "
    end

    test "combines positional and $ARGUMENTS" do
      cmd = %{template: "First: $1, Rest: $ARGUMENTS"}
      result = Commands.expand(cmd, ["one", "two", "three"])
      assert result == "First: one, Rest: one two three"
    end
  end

  describe "parse_input/1" do
    test "parses command with no args" do
      assert Commands.parse_input("/commit") == {"commit", []}
    end

    test "parses command with args" do
      assert Commands.parse_input("/commit fix the bug") == {"commit", ["fix", "the", "bug"]}
    end

    test "returns nil for non-command input" do
      assert Commands.parse_input("hello world") == nil
    end

    test "handles leading whitespace" do
      assert Commands.parse_input("  /review") == {"review", []}
    end

    test "handles extra whitespace between args" do
      assert Commands.parse_input("/cmd  arg1   arg2") == {"cmd", ["arg1", "arg2"]}
    end

    test "returns nil for empty string" do
      assert Commands.parse_input("") == nil
    end
  end

  describe "format_for_description/1" do
    test "returns empty string when no commands", %{tmp_dir: tmp_dir} do
      assert Commands.format_for_description(tmp_dir) == ""
    end

    test "formats commands as list", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Commit changes
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "commit.md"), content)

      result = Commands.format_for_description(tmp_dir)
      assert result == "- /commit: Commit changes"
    end
  end

  # ==========================================================================
  # Special Characters and Unicode Handling Tests
  # ==========================================================================

  describe "expand/2 with special characters" do
    test "preserves dollar sign in arguments" do
      cmd = %{template: "Process: $1"}
      result = Commands.expand(cmd, ["$100"])
      assert result == "Process: $100"
    end

    test "preserves asterisk in arguments" do
      cmd = %{template: "Files: $ARGUMENTS"}
      result = Commands.expand(cmd, ["*.ex", "*.exs"])
      assert result == "Files: *.ex *.exs"
    end

    test "handles backslashes in arguments" do
      cmd = %{template: "Path: $1"}
      result = Commands.expand(cmd, ["C:\\Users\\test"])
      assert result == "Path: C:\\Users\\test"
    end

    test "handles regex-like patterns in arguments" do
      cmd = %{template: "Pattern: $1"}
      result = Commands.expand(cmd, ["[a-z]+.*\\d{3}"])
      assert result == "Pattern: [a-z]+.*\\d{3}"
    end

    test "handles quotes in arguments" do
      cmd = %{template: "Message: $ARGUMENTS"}
      result = Commands.expand(cmd, ["\"hello\"", "'world'"])
      assert result == "Message: \"hello\" 'world'"
    end

    test "handles ampersand and pipe characters" do
      cmd = %{template: "Command: $1"}
      result = Commands.expand(cmd, ["cmd1 && cmd2 | cmd3"])
      assert result == "Command: cmd1 && cmd2 | cmd3"
    end

    test "handles parentheses and brackets" do
      cmd = %{template: "Expr: $1"}
      result = Commands.expand(cmd, ["func(x) + arr[0]"])
      assert result == "Expr: func(x) + arr[0]"
    end

    test "handles curly braces (used in shell expansion)" do
      cmd = %{template: "Files: $1"}
      result = Commands.expand(cmd, ["{file1,file2}.txt"])
      assert result == "Files: {file1,file2}.txt"
    end

    test "handles percent signs" do
      cmd = %{template: "Discount: $1"}
      result = Commands.expand(cmd, ["50%"])
      assert result == "Discount: 50%"
    end

    test "handles hash/pound sign" do
      cmd = %{template: "Comment: $1"}
      result = Commands.expand(cmd, ["# this is a comment"])
      assert result == "Comment: # this is a comment"
    end

    test "handles at sign" do
      cmd = %{template: "Email: $1"}
      result = Commands.expand(cmd, ["user@example.com"])
      assert result == "Email: user@example.com"
    end

    test "handles tilde" do
      cmd = %{template: "Path: $1"}
      result = Commands.expand(cmd, ["~/Documents"])
      assert result == "Path: ~/Documents"
    end

    test "handles caret and exclamation mark" do
      cmd = %{template: "Expr: $1"}
      result = Commands.expand(cmd, ["x^2 != y!"])
      assert result == "Expr: x^2 != y!"
    end

    test "handles argument that looks like placeholder but is not" do
      # $ARGUMENTS is replaced first, then $1, $2, etc.
      # An argument containing $3 should be preserved after expansion
      cmd = %{template: "Value: $1"}
      result = Commands.expand(cmd, ["cost is $300"])
      # After replacing $1 with "cost is $300", $3 in the result remains
      # but since we're replacing $1 first, it should work
      assert result == "Value: cost is $300"
    end

    test "multiple special characters in single argument" do
      cmd = %{template: "Complex: $1"}
      result = Commands.expand(cmd, ["$VAR && echo 'test' | grep \"pattern\" > out.txt"])
      assert result == "Complex: $VAR && echo 'test' | grep \"pattern\" > out.txt"
    end
  end

  describe "expand/2 with very long argument lists" do
    test "handles 100 arguments" do
      cmd = %{template: "$ARGUMENTS"}
      args = Enum.map(1..100, fn i -> "arg#{i}" end)
      result = Commands.expand(cmd, args)
      assert result == Enum.join(args, " ")
    end

    test "handles arguments with positional placeholders up to 20" do
      placeholders = Enum.map(1..20, fn i -> "$#{i}" end) |> Enum.join(" ")
      cmd = %{template: placeholders}
      args = Enum.map(1..20, fn i -> "val#{i}" end)
      result = Commands.expand(cmd, args)
      expected = Enum.map(1..20, fn i -> "val#{i}" end) |> Enum.join(" ")
      assert result == expected
    end

    test "handles very long individual arguments" do
      cmd = %{template: "Long: $1"}
      long_arg = String.duplicate("a", 10_000)
      result = Commands.expand(cmd, [long_arg])
      assert result == "Long: " <> long_arg
    end

    test "handles arguments with mixed lengths" do
      cmd = %{template: "$ARGUMENTS"}
      args = ["a", String.duplicate("b", 1000), "c", String.duplicate("d", 500)]
      result = Commands.expand(cmd, args)
      assert result == Enum.join(args, " ")
    end
  end

  describe "expand/2 with unicode" do
    test "handles unicode in arguments" do
      cmd = %{template: "Message: $ARGUMENTS"}
      result = Commands.expand(cmd, ["Hello", "世界", "🌍"])
      assert result == "Message: Hello 世界 🌍"
    end

    test "handles unicode in template and arguments" do
      cmd = %{template: "Say $1 to 世界"}
      result = Commands.expand(cmd, ["你好"])
      assert result == "Say 你好 to 世界"
    end

    test "handles emoji in arguments" do
      cmd = %{template: "Status: $1"}
      result = Commands.expand(cmd, ["✅ done"])
      assert result == "Status: ✅ done"
    end

    test "handles RTL unicode (Arabic)" do
      cmd = %{template: "Text: $1"}
      result = Commands.expand(cmd, ["مرحبا"])
      assert result == "Text: مرحبا"
    end

    test "handles combining characters" do
      cmd = %{template: "Name: $1"}
      # e with combining acute accent
      result = Commands.expand(cmd, ["café"])
      assert result == "Name: café"
    end

    test "handles zero-width characters" do
      cmd = %{template: "Text: $1"}
      # Zero-width joiner
      result = Commands.expand(cmd, ["test\u200Dword"])
      assert result == "Text: test\u200Dword"
    end

    test "handles emoji sequences (ZWJ sequences)" do
      cmd = %{template: "Family: $1"}
      # Family emoji (composed with ZWJ)
      result = Commands.expand(cmd, ["👨‍👩‍👧‍👦"])
      assert result == "Family: 👨‍👩‍👧‍👦"
    end
  end

  describe "list/1 with unicode command names" do
    test "loads command with unicode in description", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: 提交代码更改 (Commit code changes)
      ---

      Commit the changes with 日本語 template.
      """

      File.write!(Path.join(cmd_dir, "commit.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1

      cmd = hd(commands)
      assert cmd.description == "提交代码更改 (Commit code changes)"
      assert String.contains?(cmd.template, "日本語")
    end

    test "loads command with emoji in description", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: 🚀 Deploy to production
      ---

      Deploy the app.
      """

      File.write!(Path.join(cmd_dir, "deploy.md"), content)

      commands = Commands.list(tmp_dir)
      assert hd(commands).description == "🚀 Deploy to production"
    end

    test "loads command with unicode filename", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Test unicode name
      ---

      Template.
      """

      # Unicode filename (Japanese for "commit")
      File.write!(Path.join(cmd_dir, "コミット.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).name == "コミット"
    end
  end

  describe "list/1 with emoji command names" do
    test "loads command with emoji in filename", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Rocket deploy
      ---

      Launch!
      """

      File.write!(Path.join(cmd_dir, "🚀deploy.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).name == "🚀deploy"
    end

    test "loads command with only emoji as name", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Fire command
      ---

      🔥🔥🔥
      """

      File.write!(Path.join(cmd_dir, "🔥.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).name == "🔥"
    end

    test "can retrieve emoji command by name", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Check status
      ---

      Check it.
      """

      File.write!(Path.join(cmd_dir, "✅check.md"), content)

      cmd = Commands.get(tmp_dir, "✅check")
      assert cmd != nil
      assert cmd.name == "✅check"
    end
  end

  describe "list/1 with file permission errors" do
    test "handles unreadable command file gracefully", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      # Create a readable command
      content = """
      ---
      description: Readable command
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "readable.md"), content)

      # Create an unreadable command
      unreadable_path = Path.join(cmd_dir, "unreadable.md")
      File.write!(unreadable_path, "test")
      File.chmod!(unreadable_path, 0o000)

      # Should still load the readable command
      commands = Commands.list(tmp_dir)

      # Restore permissions for cleanup
      File.chmod!(unreadable_path, 0o644)

      # The readable command should be loaded, unreadable one skipped
      assert length(commands) >= 1
      names = Enum.map(commands, & &1.name)
      assert "readable" in names
    end

    test "handles unreadable directory gracefully", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)
      File.chmod!(cmd_dir, 0o000)

      # Should return empty list, not crash
      commands = Commands.list(tmp_dir)

      # Restore permissions for cleanup
      File.chmod!(cmd_dir, 0o755)

      assert commands == []
    end
  end

  describe "list/1 with invalid frontmatter" do
    test "handles frontmatter with colon in value", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Time: 10:30 AM
      ---

      Template with time.
      """

      File.write!(Path.join(cmd_dir, "time.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      # Simple YAML parser splits on first colon
      assert hd(commands).description == "Time: 10:30 AM"
    end

    test "handles frontmatter with YAML special characters", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Use {braces} and [brackets]
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "special.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Use {braces} and [brackets]"
    end

    test "handles frontmatter with quotes", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Say "hello" and 'goodbye'
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "quotes.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Say \"hello\" and 'goodbye'"
    end

    test "handles frontmatter with hash/comment character", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Item #1 - important
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "hash.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Item #1 - important"
    end

    test "handles frontmatter with ampersand", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Copy & paste helper
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "amp.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Copy & paste helper"
    end

    test "handles frontmatter with asterisk", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Match *.ex files
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "glob.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Match *.ex files"
    end

    test "handles frontmatter with pipe character", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Run cmd1 | cmd2
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "pipe.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "Run cmd1 | cmd2"
    end

    test "handles frontmatter with percent sign", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: 100% complete
      ---

      Template.
      """

      File.write!(Path.join(cmd_dir, "percent.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      assert hd(commands).description == "100% complete"
    end

    test "handles malformed frontmatter without closing delimiter", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Missing closing
      This is not proper frontmatter
      """

      File.write!(Path.join(cmd_dir, "malformed.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      # Should treat the whole thing as template (no valid frontmatter)
      cmd = hd(commands)
      assert cmd.description == ""
    end

    test "handles empty frontmatter", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      ---

      Just a template.
      """

      File.write!(Path.join(cmd_dir, "empty-fm.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
      cmd = hd(commands)
      assert cmd.description == ""
      assert String.contains?(cmd.template, "Just a template")
    end

    test "handles frontmatter with only whitespace lines", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---


      ---

      Template content.
      """

      File.write!(Path.join(cmd_dir, "whitespace-fm.md"), content)

      commands = Commands.list(tmp_dir)
      assert length(commands) == 1
    end
  end

  describe "parse_input/1 with whitespace handling" do
    test "handles tabs in input" do
      assert Commands.parse_input("/cmd\targ1\targ2") == {"cmd", ["arg1", "arg2"]}
    end

    test "handles mixed spaces and tabs" do
      assert Commands.parse_input("/cmd \t arg1  \t  arg2") == {"cmd", ["arg1", "arg2"]}
    end

    test "handles trailing whitespace" do
      assert Commands.parse_input("/cmd arg1   ") == {"cmd", ["arg1"]}
    end

    test "handles newlines (treats as whitespace)" do
      # Newlines in the middle should be treated as separators
      assert Commands.parse_input("/cmd arg1\narg2") == {"cmd", ["arg1", "arg2"]}
    end

    test "handles carriage return" do
      assert Commands.parse_input("/cmd arg1\r\narg2") == {"cmd", ["arg1", "arg2"]}
    end

    test "handles only whitespace after command" do
      assert Commands.parse_input("/cmd   \t   ") == {"cmd", []}
    end

    test "preserves internal spaces in quoted-like content" do
      # Note: parse_input does simple split, doesn't handle quotes
      result = Commands.parse_input("/cmd \"hello world\"")
      assert result == {"cmd", ["\"hello", "world\""]}
    end

    test "unicode whitespace (non-breaking space) is NOT treated as separator" do
      # Non-breaking space (U+00A0) - Elixir's \s+ regex does not match this
      # This documents the actual behavior: non-breaking space becomes part of the command name
      result = Commands.parse_input("/cmd\u00A0arg1")
      assert result == {"cmd\u00A0arg1", []}
    end

    test "unicode whitespace (em space U+2003) is NOT treated as separator" do
      # Em space (U+2003) - Elixir's \s+ regex does not match this
      # This documents the actual behavior: em space becomes part of the command name
      result = Commands.parse_input("/cmd\u2003arg1")
      assert result == {"cmd\u2003arg1", []}
    end
  end

  describe "parse_input/1 with special characters in command name" do
    test "handles hyphen in command name" do
      assert Commands.parse_input("/my-command arg") == {"my-command", ["arg"]}
    end

    test "handles underscore in command name" do
      assert Commands.parse_input("/my_command arg") == {"my_command", ["arg"]}
    end

    test "handles numbers in command name" do
      assert Commands.parse_input("/cmd123 arg") == {"cmd123", ["arg"]}
    end

    test "handles dot in command name" do
      assert Commands.parse_input("/file.ext arg") == {"file.ext", ["arg"]}
    end

    test "handles unicode in command name" do
      assert Commands.parse_input("/コミット arg") == {"コミット", ["arg"]}
    end

    test "handles emoji in command name" do
      assert Commands.parse_input("/🚀deploy arg") == {"🚀deploy", ["arg"]}
    end
  end

  describe "parse_input/1 with special characters in arguments" do
    test "handles dollar signs in arguments" do
      assert Commands.parse_input("/cmd $VAR $100") == {"cmd", ["$VAR", "$100"]}
    end

    test "handles equals sign in arguments" do
      assert Commands.parse_input("/cmd key=value") == {"cmd", ["key=value"]}
    end

    test "handles URL in arguments" do
      result = Commands.parse_input("/open https://example.com/path?q=1&r=2")
      assert result == {"open", ["https://example.com/path?q=1&r=2"]}
    end

    test "handles file path in arguments" do
      assert Commands.parse_input("/edit /path/to/file.ex") == {"edit", ["/path/to/file.ex"]}
    end

    test "handles glob pattern in arguments" do
      assert Commands.parse_input("/find *.ex **/*.exs") == {"find", ["*.ex", "**/*.exs"]}
    end
  end

  describe "format_for_description/1 with unicode" do
    test "formats commands with unicode descriptions", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: 部署到生产环境 🚀
      ---

      Deploy.
      """

      File.write!(Path.join(cmd_dir, "deploy.md"), content)

      result = Commands.format_for_description(tmp_dir)
      assert result == "- /deploy: 部署到生产环境 🚀"
    end

    test "formats commands with emoji names", %{tmp_dir: tmp_dir} do
      cmd_dir = Path.join([tmp_dir, ".lemon", "command"])
      File.mkdir_p!(cmd_dir)

      content = """
      ---
      description: Fire it up
      ---

      Launch.
      """

      File.write!(Path.join(cmd_dir, "🔥launch.md"), content)

      result = Commands.format_for_description(tmp_dir)
      assert result == "- /🔥launch: Fire it up"
    end
  end

  describe "edge cases" do
    test "handles empty template" do
      cmd = %{template: ""}
      result = Commands.expand(cmd, ["arg1", "arg2"])
      assert result == ""
    end

    test "handles template with only placeholders" do
      cmd = %{template: "$1 $2 $ARGUMENTS"}
      result = Commands.expand(cmd, ["a", "b"])
      assert result == "a b a b"
    end

    test "handles double dollar sign in argument" do
      cmd = %{template: "Value: $1"}
      result = Commands.expand(cmd, ["$$VAR"])
      assert result == "Value: $$VAR"
    end

    test "handles argument containing placeholder pattern" do
      cmd = %{template: "Echo: $1"}
      # The argument itself contains $ARGUMENTS
      result = Commands.expand(cmd, ["use $ARGUMENTS here"])
      assert result == "Echo: use $ARGUMENTS here"
    end

    test "handles very deeply nested special characters" do
      cmd = %{template: "$1"}
      arg = "{{${VAR:-$(cmd)}[*]}}"
      result = Commands.expand(cmd, [arg])
      assert result == arg
    end

    test "handles null byte in argument (if passed)", %{tmp_dir: _tmp_dir} do
      cmd = %{template: "Data: $1"}
      # Null bytes might be stripped or cause issues
      result = Commands.expand(cmd, ["test\0data"])
      assert result == "Data: test\0data"
    end

    test "handles BOM character in argument" do
      cmd = %{template: "Text: $1"}
      # UTF-8 BOM
      result = Commands.expand(cmd, ["\uFEFFhello"])
      assert result == "Text: \uFEFFhello"
    end
  end
end
