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
end
