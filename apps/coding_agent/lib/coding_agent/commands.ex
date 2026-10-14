defmodule CodingAgent.Commands do
  @moduledoc """
  File-defined slash commands: discovery, argument parsing and expansion.

  A user prompt of the form `/name args` whose `name` matches a discovered
  command is replaced by the command's expanded template before it reaches the
  model (see `expand_input/3`). Native surfaces route prompts through
  `CodingAgent.Executor`, which performs that replacement once per user prompt;
  internal subagent prompts are never expanded.

  ## Roots

  Project roots (relative to the session cwd) are searched before user-global
  roots. Within one scope, Lemon-native roots win over other tools' roots, and
  the first command with a given name wins:

  | Scope | Root | Format |
  | --- | --- | --- |
  | project | `.lemon/command/`, `.lemon/commands/` | `*.md` |
  | project | `.omp/commands/` | `*.md` |
  | project | `.agents/commands/`, `.agent/commands/` | `*.md` |
  | project | `.claude/commands/` | `**/*.md`, nested `a/b.md` → `a:b` |
  | project | `.codex/prompts/`, `.codex/commands/` | `*.md` |
  | project | `.github/prompts/` | `*.prompt.md` (name drops `.prompt.md`) |
  | project | `.gemini/commands/` | `**/*.toml`, nested `a/b.toml` → `a:b` |
  | global | `<agent_dir>/command/`, `<agent_dir>/commands/` | `*.md` |
  | global | `~/.omp/agent/commands/` | `*.md` |
  | global | `~/.agents/commands/`, `~/.agent/commands/` | `*.md` |
  | global | `~/.claude/commands/` | `**/*.md` |
  | global | `~/.codex/prompts/`, `~/.codex/commands/` | `*.md` |
  | global | `~/.gemini/commands/` | `**/*.toml` |

  `<agent_dir>` is `CodingAgent.Config.agent_dir/0` (`~/.lemon/agent`). The home
  directory is `HOME` unless the `:home` option overrides it.

  ## Markdown command format

      ---
      description: Commit and push changes
      argument-hint: [message]
      model: opus
      subtask: true
      ---

      Commit the current changes. Message: $ARGUMENTS

  Files without frontmatter use the whole file as the template. `model` and
  `subtask` are parsed into the command map; expansion does not apply them.
  User guide: `docs/user-guide/slash-commands.md`.

  ## Gemini TOML command format

      description = "Review a file"
      prompt = "Review {{args}} for bugs."

  Gemini shell (`!{...}`) and file (`@{...}`) injections are not evaluated.

  ## Argument interpolation

  Arguments are parsed shell-style (single or double quotes group words):

  - `$1`, `$2`, … — positional arguments (missing ones become empty)
  - `$ARGUMENTS`, `$@`, `{{args}}` — the full argument text

  Substitution is single-pass: argument values are never re-expanded. When a
  template has no placeholder and arguments were given, they are appended after
  a blank line.
  """

  require Logger
  alias CodingAgent.Config

  @max_file_bytes 64 * 1024
  @max_expanded_bytes 256 * 1024
  @max_depth 4
  @max_files_per_root 500

  @placeholder ~r/\$ARGUMENTS|\$@|\$(\d+)|\{\{\s*(?:args|arguments|ARGUMENTS)\s*\}\}/

  @type format :: :markdown | :markdown_nested | :github_prompt | :gemini_toml
  @type scope :: :project | :global

  @type command :: %{
          name: String.t(),
          description: String.t(),
          argument_hint: String.t() | nil,
          model: String.t() | nil,
          subtask: boolean(),
          template: String.t(),
          path: String.t(),
          source: String.t(),
          scope: scope()
        }

  @doc """
  List all file commands available for `cwd`, sorted by name.

  ## Options

    * `:home` - home directory for user-global roots (default: `HOME`)
  """
  @spec list(String.t(), keyword()) :: [command()]
  def list(cwd, opts \\ []) do
    cwd
    |> roots(opts)
    |> Enum.reduce({%{}, []}, fn {dir, format, source, scope}, acc ->
      dir
      |> load_root(format, source, scope)
      |> Enum.reduce(acc, fn command, {seen, commands} ->
        if Map.has_key?(seen, command.name) do
          {seen, commands}
        else
          {Map.put(seen, command.name, true), [command | commands]}
        end
      end)
    end)
    |> elem(1)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Get a command by exact name (without the leading `/`), or `nil`.
  """
  @spec get(String.t(), String.t(), keyword()) :: command() | nil
  def get(cwd, name, opts \\ []) when is_binary(name) do
    cwd
    |> list(opts)
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Expand a command template with arguments.

  `args` is either the raw argument text typed after the command name, or an
  already-split list of arguments (joined with spaces for `$ARGUMENTS`).

  ## Examples

      iex> CodingAgent.Commands.expand(%{template: "Fix $1 in $2"}, ["bug", "login.ex"])
      "Fix bug in login.ex"

      iex> CodingAgent.Commands.expand(%{template: "Review: $ARGUMENTS"}, ~s(all "the files"))
      ~s(Review: all "the files")

      iex> CodingAgent.Commands.expand(%{template: "Summarize the diff."}, "briefly")
      "Summarize the diff.\\n\\nbriefly"
  """
  @spec expand(
          %{required(:template) => String.t(), optional(atom()) => term()},
          [String.t()] | String.t()
        ) ::
          String.t()
  def expand(command, args) when is_binary(args) do
    render(command.template, parse_args(args), String.trim(args))
  end

  def expand(command, args) when is_list(args) do
    render(command.template, args, Enum.join(args, " "))
  end

  @doc """
  Expand `text` when it is `/name args` and `name` is a discovered command.

  Returns `{:ok, expanded, command}`, `:nomatch` when the text is not a file
  command invocation, or `{:error, :too_large}` when the expansion would exceed
  #{div(@max_expanded_bytes, 1024)} KiB.
  """
  @spec expand_input(String.t(), String.t(), keyword()) ::
          {:ok, String.t(), command()} | :nomatch | {:error, :too_large}
  def expand_input(cwd, text, opts \\ []) when is_binary(cwd) and is_binary(text) do
    with {name, raw_args} <- split_invocation(text),
         %{} = command <- get(cwd, name, opts) do
      expanded = expand(command, raw_args)

      if byte_size(expanded) > @max_expanded_bytes do
        {:error, :too_large}
      else
        {:ok, expanded, command}
      end
    else
      _ -> :nomatch
    end
  end

  @doc """
  Prepare a user-origin prompt for a local native run or live steer/redirect.
  Internal followups and named-node requests stay literal: remote discovery
  must happen on the destination, with that submission's origin preserved.
  """
  @spec prepare_prompt(String.t() | nil, term(), map()) :: term()
  def prepare_prompt(cwd, prompt, meta)
      when is_binary(cwd) and is_binary(prompt) and is_map(meta) do
    origin = meta[:origin] || meta["origin"]
    node = meta[:node] || meta["node"]
    local? = is_nil(node) or (is_binary(node) and String.trim(node) in ["", "local"])
    followups = meta[:async_followups] || meta["async_followups"]

    if local? and origin in [:channel, :control_plane, "channel", "control_plane"] and
         followups in [nil, []] do
      case expand_input(cwd, prompt) do
        {:ok, expanded, _command} ->
          expanded

        {:error, :too_large} ->
          Logger.warning("File command expansion too large; sent as typed")
          prompt

        :nomatch ->
          prompt
      end
    else
      prompt
    end
  end

  def prepare_prompt(_cwd, prompt, _meta), do: prompt

  @doc """
  Parse user input that starts with `/` into `{name, args}`, or `nil`.

  Arguments are split on whitespace; single or double quotes group words.

  ## Examples

      iex> CodingAgent.Commands.parse_input(~s(/commit fix "the bug"))
      {"commit", ["fix", "the bug"]}

      iex> CodingAgent.Commands.parse_input("hello world")
      nil
  """
  @spec parse_input(String.t()) :: {String.t(), [String.t()]} | nil
  def parse_input(input) when is_binary(input) do
    case split_invocation(input) do
      {name, raw_args} -> {name, parse_args(raw_args)}
      nil -> nil
    end
  end

  @doc """
  Split argument text shell-style: whitespace separates, quotes group.
  """
  @spec parse_args(String.t()) :: [String.t()]
  def parse_args(text) when is_binary(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", nil, false}, fn
      char, {args, current, quote, _started} when char == quote ->
        {args, current, nil, true}

      char, {args, current, nil, _started} when char in ["\"", "'"] ->
        {args, current, char, true}

      char, {args, current, nil, started} ->
        split_char(char, args, current, started)

      char, {args, current, quote, _started} ->
        {args, current <> char, quote, true}
    end)
    |> then(fn {args, current, _quote, started} ->
      Enum.reverse(push_arg(args, current, started))
    end)
  end

  # ============================================================================
  # Expansion
  # ============================================================================

  defp split_char(char, args, current, started) do
    if String.match?(char, ~r/\A\s+\z/),
      do: {push_arg(args, current, started), "", nil, false},
      else: {args, current <> char, nil, true}
  end

  defp push_arg(args, _current, false), do: args
  defp push_arg(args, current, true), do: [current | args]

  defp split_invocation(text) do
    case String.trim(text) do
      "/" <> rest ->
        case String.split(rest, ~r/\s+/, parts: 2) do
          [name | maybe_args] when name != "" ->
            if String.contains?(name, "/"), do: nil, else: {name, Enum.at(maybe_args, 0, "")}

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp render(template, args, args_text) do
    if Regex.match?(@placeholder, template) do
      Regex.replace(@placeholder, template, fn
        _match, "" -> args_text
        _match, index -> Enum.at(args, String.to_integer(index) - 1, "")
      end)
    else
      append_args(template, args_text)
    end
  end

  defp append_args(template, ""), do: template
  defp append_args("", args_text), do: args_text
  defp append_args(template, args_text), do: template <> "\n\n" <> args_text

  # ============================================================================
  # Discovery
  # ============================================================================

  defp roots(cwd, opts) do
    home = Keyword.get_lazy(opts, :home, &default_home/0)
    project = Config.project_config_dir(cwd)
    agent_dir = Config.agent_dir()

    project_roots = [
      {Path.join(project, "command"), :markdown, "lemon"},
      {Path.join(project, "commands"), :markdown, "lemon"},
      {Path.join(cwd, ".omp/commands"), :markdown, "omp"},
      {Path.join(cwd, ".agents/commands"), :markdown, "agents"},
      {Path.join(cwd, ".agent/commands"), :markdown, "agents"},
      {Path.join(cwd, ".claude/commands"), :markdown_nested, "claude"},
      {Path.join(cwd, ".codex/prompts"), :markdown, "codex"},
      {Path.join(cwd, ".codex/commands"), :markdown, "codex"},
      {Path.join(cwd, ".github/prompts"), :github_prompt, "github"},
      {Path.join(cwd, ".gemini/commands"), :gemini_toml, "gemini"}
    ]

    global_roots = [
      {Path.join(agent_dir, "command"), :markdown, "lemon"},
      {Path.join(agent_dir, "commands"), :markdown, "lemon"},
      {Path.join(home, ".omp/agent/commands"), :markdown, "omp"},
      {Path.join(home, ".agents/commands"), :markdown, "agents"},
      {Path.join(home, ".agent/commands"), :markdown, "agents"},
      {Path.join(home, ".claude/commands"), :markdown_nested, "claude"},
      {Path.join(home, ".codex/prompts"), :markdown, "codex"},
      {Path.join(home, ".codex/commands"), :markdown, "codex"},
      {Path.join(home, ".gemini/commands"), :gemini_toml, "gemini"}
    ]

    for({dir, format, source} <- project_roots, do: {dir, format, source, :project}) ++
      for({dir, format, source} <- global_roots, do: {dir, format, source, :global})
  end

  defp default_home, do: System.get_env("HOME") || System.user_home!()

  defp load_root(dir, format, source, scope) do
    dir
    |> command_files(format)
    |> Enum.sort()
    |> Enum.flat_map(fn {relative, path} ->
      with name when is_binary(name) <- command_name(relative, format),
           {:ok, content} <- read_bounded(path),
           %{} = command <- parse_command(content, format) do
        [Map.merge(command, %{name: name, path: path, source: source, scope: scope})]
      else
        _ -> []
      end
    end)
  end

  defp command_files(dir, format) do
    depth = if format in [:markdown_nested, :gemini_toml], do: @max_depth, else: 0
    ext = if format == :gemini_toml, do: ".toml", else: ".md"

    dir
    |> walk([], depth, ext)
    |> Enum.take(@max_files_per_root)
  end

  defp walk(dir, segments, depth, ext) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.regular?(path) and String.ends_with?(entry, ext) ->
              [{Enum.reverse([entry | segments]), path}]

            depth > 0 and File.dir?(path) ->
              walk(path, [entry | segments], depth - 1, ext)

            true ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp command_name(segments, format) do
    {dirs, [file]} = Enum.split(segments, -1)

    base =
      case format do
        :github_prompt -> trim_suffix(file, ".prompt.md")
        :gemini_toml -> trim_suffix(file, ".toml")
        _ -> trim_suffix(file, ".md")
      end

    name = Enum.join(dirs ++ [base || ""], ":")

    if is_binary(base) and base != "" and not String.match?(name, ~r/\s/u), do: name
  end

  defp trim_suffix(file, suffix) do
    if String.ends_with?(file, suffix), do: String.replace_suffix(file, suffix, "")
  end

  defp read_bounded(path) do
    with {:ok, %File.Stat{size: size}} when size <= @max_file_bytes <- File.stat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      {:ok, String.replace(content, "\r\n", "\n")}
    else
      _ -> :error
    end
  end

  defp parse_command(content, :gemini_toml) do
    case Toml.decode(content) do
      {:ok, %{"prompt" => prompt} = doc} when is_binary(prompt) ->
        %{
          description: string_field(doc["description"]) || "",
          argument_hint: nil,
          model: nil,
          subtask: false,
          template: String.trim(prompt)
        }

      _ ->
        nil
    end
  end

  defp parse_command(content, _markdown) do
    {frontmatter, body} =
      case parse_frontmatter(content) do
        {:ok, frontmatter, body} -> {frontmatter, body}
        :error -> {%{}, content}
      end

    %{
      description: frontmatter["description"] || "",
      argument_hint: frontmatter["argument-hint"] || frontmatter["argumentHint"],
      model: frontmatter["model"],
      subtask: parse_bool(frontmatter["subtask"], false),
      template: String.trim(body)
    }
  end

  defp string_field(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_field(_value), do: nil

  defp parse_frontmatter("---\n" <> _ = content) do
    case String.split(content, ~r/\n---(?:\n|\z)/, parts: 2) do
      [frontmatter_raw, body] ->
        frontmatter_raw
        |> String.replace_prefix("---\n", "")
        |> parse_yaml_simple()
        |> then(&{:ok, &1, body})

      _ ->
        :error
    end
  end

  defp parse_frontmatter(_content), do: :error

  defp parse_yaml_simple(yaml_text) do
    yaml_text
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          case unquote_value(String.trim(value)) do
            "" -> acc
            value -> Map.put(acc, String.trim(key), value)
          end

        _ ->
          acc
      end
    end)
  end

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if String.ends_with?(rest, <<q>>) and rest != "",
      do: String.slice(rest, 0..-2//1),
      else: value
  end

  defp unquote_value(value), do: value

  defp parse_bool("true", _default), do: true
  defp parse_bool("false", _default), do: false
  defp parse_bool(_, default), do: default
end
