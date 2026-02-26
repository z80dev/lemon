defmodule CodingAgent.Commands do
  @moduledoc """
  Slash command definitions and loading.

  Commands are user-defined prompts triggered with `/command` syntax.
  They are markdown files with YAML frontmatter stored in:

  - Project: .lemon/command/*.md
  - Global: ~/.lemon/agent/command/*.md

  ## Command File Format

  Each command is a markdown file with frontmatter:

      ---
      description: Commit and push changes
      model: opus
      subtask: true
      ---

      Commit the current changes with a descriptive message.

      Follow these guidelines:
      - Use conventional commit format
      - Be specific about what changed

  ## Fields

  - `description` - Short description shown in command list
  - `model` - Optional model override for this command
  - `subtask` - Whether to run as a subtask (default: false)

  ## Argument Interpolation

  Commands support argument placeholders:
  - `$1`, `$2`, etc. - Positional arguments
  - `$ARGUMENTS` - All arguments as a single string

  ## Example Usage

      user: /commit fix the login bug
      -> Runs commit command with "fix the login bug" as $ARGUMENTS
  """

  alias CodingAgent.Config

  @type command :: %{
          name: String.t(),
          description: String.t(),
          model: String.t() | nil,
          subtask: boolean(),
          template: String.t(),
          path: String.t()
        }

  @doc """
  List all available commands for a working directory.

  Returns a list of command maps.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A list of command maps sorted by name.
  """
  @spec list(String.t()) :: [command()]
  def list(cwd) do
    global_commands = load_commands_from_dir(global_commands_dir())
    project_commands = load_commands_from_dir(project_commands_dir(cwd))

    # Project commands override global ones by name
    global_commands
    |> merge_by_name(project_commands)
  end

  @doc """
  Get a command by name.

  ## Parameters

    * `cwd` - The current working directory
    * `name` - The command name (without leading /)

  ## Returns

  The command map or nil if not found.
  """
  @spec get(String.t(), String.t()) :: command() | nil
  def get(cwd, name) when is_binary(name) do
    list(cwd)
    |> Enum.find(fn cmd -> cmd.name == name end)
  end

  @doc """
  Expand a command with arguments.

  Replaces placeholders in the template with provided arguments.

  ## Parameters

    * `command` - The command map
    * `args` - List of argument strings

  ## Returns

  The expanded template string.

  ## Examples

      command = %{template: "Fix $1 in $2"}
      Commands.expand(command, ["bug", "login.ex"])
      # => "Fix bug in login.ex"

      command = %{template: "Review changes: $ARGUMENTS"}
      Commands.expand(command, ["all", "files"])
      # => "Review changes: all files"
  """
  @spec expand(command(), [String.t()]) :: String.t()
  def expand(command, args) when is_list(args) do
    template = command.template

    # Replace $ARGUMENTS with all args joined
    template = String.replace(template, "$ARGUMENTS", Enum.join(args, " "))

    # Replace positional args $1, $2, etc.
    args
    |> Enum.with_index(1)
    |> Enum.reduce(template, fn {arg, index}, acc ->
      String.replace(acc, "$#{index}", arg)
    end)
  end

  @doc """
  Parse a user input that starts with /.

  Returns the command name and arguments if the input is a command,
  otherwise returns nil.

  ## Parameters

    * `input` - The user input string

  ## Returns

  `{command_name, args}` or nil if not a command.

  ## Examples

      Commands.parse_input("/commit fix bug")
      # => {"commit", ["fix", "bug"]}

      Commands.parse_input("hello world")
      # => nil
  """
  @spec parse_input(String.t()) :: {String.t(), [String.t()]} | nil
  def parse_input(input) when is_binary(input) do
    input = String.trim(input)

    if String.starts_with?(input, "/") do
      # Remove leading /
      rest = String.trim_leading(input, "/")
      parts = String.split(rest, ~r/\s+/, parts: 2)

      case parts do
        [name] -> {name, []}
        [name, args_str] -> {name, String.split(args_str)}
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Format commands for display/description.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  Formatted string listing available commands.
  """
  @spec format_for_description(String.t()) :: String.t()
  def format_for_description(cwd) do
    commands = list(cwd)

    if commands == [] do
      ""
    else
      commands
      |> Enum.map(fn cmd ->
        "- /#{cmd.name}: #{cmd.description}"
      end)
      |> Enum.join("\n")
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_commands_from_dir(nil), do: []

  defp load_commands_from_dir(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.filter(fn name -> String.ends_with?(name, ".md") end)
      |> Enum.map(fn filename ->
        load_command(Path.join(dir, filename))
      end)
      |> Enum.reject(&is_nil/1)
    else
      []
    end
  rescue
    _ -> []
  end

  defp load_command(path) do
    case File.read(path) do
      {:ok, content} ->
        parse_command(content, path)

      {:error, _} ->
        nil
    end
  end

  defp parse_command(content, path) do
    case parse_frontmatter(content) do
      {:ok, frontmatter, body} ->
        # Get name from filename (without .md extension)
        filename = Path.basename(path)
        name = String.replace_suffix(filename, ".md", "")

        %{
          name: name,
          description: frontmatter["description"] || "",
          model: frontmatter["model"],
          subtask: parse_bool(frontmatter["subtask"], false),
          template: String.trim(body),
          path: path
        }

      :error ->
        # If no frontmatter, treat the whole file as template
        filename = Path.basename(path)
        name = String.replace_suffix(filename, ".md", "")

        %{
          name: name,
          description: "",
          model: nil,
          subtask: false,
          template: String.trim(content),
          path: path
        }
    end
  end

  defp parse_frontmatter(content) do
    if String.starts_with?(content, "---\n") do
      case String.split(content, ~r/\n---\n/, parts: 2) do
        [frontmatter_raw, body] ->
          frontmatter_clean = String.trim_leading(frontmatter_raw, "---\n")
          frontmatter = parse_yaml_simple(frontmatter_clean)
          {:ok, frontmatter, body}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp parse_yaml_simple(yaml_text) do
    yaml_text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = String.trim(value)
          Map.put(acc, key, value)

        _ ->
          acc
      end
    end)
  end

  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_, default), do: default

  defp merge_by_name(base, overrides) do
    base_map = Map.new(base, fn cmd -> {cmd.name, cmd} end)
    overrides_map = Map.new(overrides, fn cmd -> {cmd.name, cmd} end)

    merged = Map.merge(base_map, overrides_map)
    merged |> Map.values() |> Enum.sort_by(& &1.name)
  end

  defp global_commands_dir do
    Path.join(Config.agent_dir(), "command")
  end

  defp project_commands_dir(cwd) do
    Path.join(Config.project_config_dir(cwd), "command")
  end
end
