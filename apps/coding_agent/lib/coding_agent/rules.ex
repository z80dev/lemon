defmodule CodingAgent.Rules do
  @moduledoc """
  Discovers rule files written for other coding agents (Cursor, Windsurf,
  Cline, GitHub Copilot, `.agents`) and Lemon's own `.lemon/rules`, and
  renders them as system-prompt sections.

  ## Sources

  Project rules, in precedence order:

  - `.lemon/rules/*.{md,mdc}`, then `.agent/rules/*.{md,mdc}` and
    `.agents/rules/*.{md,mdc}`, each walking from cwd up to the Git root
    (or the home directory, which itself is skipped); nearer directories first
  - `.cursor/rules/**/*.{mdc,md}` and legacy `.cursorrules` in cwd
  - `.windsurf/rules/*.md` and legacy `.windsurfrules` in cwd
  - the nearest `.clinerules` on the same walk: a file, or a directory of `*.md`
  - `.github/instructions/**/*.instructions.md` in cwd

  Global rules: `<agent_dir>/rules/*.{md,mdc}`, `~/.agent/rules` and
  `~/.agents/rules`, and `~/.codeium/windsurf/memories/global_rules.md`.

  Rule names come from the file path relative to its rules directory without
  the extension (`.instructions.md` for GitHub files). The legacy single files
  are named `cursorrules`, `windsurfrules`, `clinerules` and `global_rules`.
  The first rule with a name wins: project rules shadow global ones.

  ## Frontmatter

  `description`, `globs` (a list, or a comma-separated string), `alwaysApply`
  and `enabled` (`false` drops the rule). Windsurf's `trigger` is honoured:
  `always_on` applies always, `manual` keeps the rule out of the prompt, and
  `glob`/`model_decision` use `globs`/`description`. GitHub `applyTo` becomes
  `globs`; `*`, `**` and `**/*` make the rule always apply. Legacy single
  files always apply. Invalid YAML falls back to plain `key: value` lines, so
  Cursor's unquoted `globs: *.ts` parses.

  ## Prompt

  Always-apply rules are injected in full. Other rules with a description or
  globs are listed in a rulebook index (name, description, globs, absolute
  path) for the model to `read` when they apply. Rules with neither are not
  surfaced. Rule files are repository data with the same trust as
  `AGENTS.md`. Output is sorted by name, so prompt bytes are stable.
  """

  alias CodingAgent.Config

  @type rule :: %{
          name: String.t(),
          path: String.t(),
          content: String.t(),
          description: String.t() | nil,
          globs: [String.t()],
          always_apply: boolean(),
          manual: boolean(),
          level: :project | :global
        }

  @type section :: %{category: atom(), label: String.t(), text: String.t()}

  @rule_exts [".md", ".mdc"]
  @agent_dirs [".agent", ".agents"]
  @github_always_globs ["*", "**", "**/*"]
  @max_rule_dir_depth 8

  @doc """
  Discover enabled rules for `cwd`: project rules first, deduplicated by name,
  sorted by name.
  """
  @spec discover(String.t()) :: [rule()]
  def discover(cwd) do
    cwd = Path.expand(cwd)
    home = Config.home_dir()

    (project_rules(cwd, home) ++ global_rules(home))
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Split rules into `:always_apply` (bodies injected) and `:rulebook` (indexed
  for on-demand reading). Manual rules and rules with neither description nor
  globs are dropped.
  """
  @spec buckets([rule()]) :: %{always_apply: [rule()], rulebook: [rule()]}
  def buckets(rules) do
    always = Enum.filter(rules, &(&1.always_apply and not &1.manual))

    rulebook =
      Enum.filter(rules, fn rule ->
        not rule.always_apply and not rule.manual and
          (rule.description != nil or rule.globs != [])
      end)

    %{always_apply: always, rulebook: rulebook}
  end

  @doc """
  Labelled system-prompt sections for the rules discovered from `cwd`: an
  always-apply header (category `:system_prompt`) and one `:context_files`
  section per always-apply rule, then one `:context_files` rulebook index.
  Labels carry the rule name and scope, never an absolute path.
  """
  @spec sections(String.t()) :: [section()]
  def sections(cwd) do
    %{always_apply: always, rulebook: rulebook} = cwd |> discover() |> buckets()
    always_sections(always) ++ rulebook_sections(rulebook)
  end

  # ============================================================================
  # Rendering
  # ============================================================================

  defp always_sections([]), do: []

  defp always_sections(rules) do
    header = %{
      category: :system_prompt,
      label: "Always-apply rules",
      text:
        "## Always-apply rules\n" <>
          "These rules come from project and global rule files. Follow them for all work " <>
          "in this session; a project rule replaces a global rule of the same name."
    }

    [
      header
      | Enum.map(rules, fn rule ->
          %{
            category: :context_files,
            label: "rule #{rule.name} (#{rule.level})",
            text: "<!-- Rule: #{rule.name} (from: #{rule.path}) -->\n#{rule.content}"
          }
        end)
    ]
  end

  defp rulebook_sections([]), do: []

  defp rulebook_sections(rules) do
    entries = Enum.map_join(rules, "\n", &rulebook_entry/1)

    [
      %{
        category: :context_files,
        label: "Rulebook (#{length(rules)} #{if length(rules) == 1, do: "rule", else: "rules"})",
        text:
          "## Rulebook\n" <>
            "These rules are not loaded here. Before working on files that match a rule's " <>
            "globs, or when its description applies to the task, `read` the rule file and " <>
            "follow it.\n" <> entries
      }
    ]
  end

  defp rulebook_entry(rule) do
    head = if rule.description, do: "- #{rule.name}: #{rule.description}", else: "- #{rule.name}"
    globs = if rule.globs == [], do: [], else: ["  Globs: " <> Enum.join(rule.globs, ", ")]
    Enum.join([head | globs] ++ ["  File: #{rule.path}"], "\n")
  end

  # ============================================================================
  # Discovery
  # ============================================================================

  defp project_rules(cwd, home) do
    dirs = project_dirs(cwd, home)

    Enum.concat([
      Enum.flat_map(dirs, &rule_dir(Path.join([&1, ".lemon", "rules"]), :project)),
      Enum.flat_map(dirs, fn dir ->
        Enum.flat_map(@agent_dirs, &rule_dir(Path.join([dir, &1, "rules"]), :project))
      end),
      rule_dir(Path.join([cwd, ".cursor", "rules"]), :project, recursive: true),
      legacy_rule(Path.join(cwd, ".cursorrules"), "cursorrules", :project),
      rule_dir(Path.join([cwd, ".windsurf", "rules"]), :project, exts: [".md"]),
      legacy_rule(Path.join(cwd, ".windsurfrules"), "windsurfrules", :project),
      clinerules(dirs),
      github_instructions(Path.join([cwd, ".github", "instructions"]))
    ])
  end

  defp global_rules(home) do
    Enum.concat([
      rule_dir(Path.join(Path.expand(Config.agent_dir()), "rules"), :global),
      Enum.flat_map(@agent_dirs, &rule_dir(Path.join([home, &1, "rules"]), :global)),
      legacy_rule(
        Path.join([home, ".codeium", "windsurf", "memories", "global_rules.md"]),
        "global_rules",
        :global
      )
    ])
  end

  # cwd and its ancestors up to and including the Git root, or the home
  # directory when no Git root is closer. The home directory itself holds
  # global (not project) configuration and is skipped.
  defp project_dirs(cwd, home) do
    {inside, rest} =
      cwd
      |> ancestors([])
      |> Enum.split_while(&(&1 != home and not File.exists?(Path.join(&1, ".git"))))

    Enum.reject(inside ++ Enum.take(rest, 1), &(&1 == home))
  end

  defp ancestors(dir, acc) do
    parent = Path.dirname(dir)
    if parent == dir, do: Enum.reverse([dir | acc]), else: ancestors(parent, [dir | acc])
  end

  defp clinerules(dirs) do
    dirs
    |> Enum.map(&Path.join(&1, ".clinerules"))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil ->
        []

      path ->
        if File.dir?(path),
          do: rule_dir(path, :project, exts: [".md"]),
          else: legacy_rule(path, "clinerules", :project)
    end
  end

  defp github_instructions(dir) do
    dir
    |> list_files([".md"], true, 0)
    |> Enum.filter(&String.ends_with?(&1, ".instructions.md"))
    |> Enum.flat_map(fn path ->
      name = path |> Path.relative_to(dir) |> String.replace_suffix(".instructions.md", "")
      load_rule(path, name, :project, :github)
    end)
  end

  defp rule_dir(dir, level, opts \\ []) do
    exts = Keyword.get(opts, :exts, @rule_exts)

    dir
    |> list_files(exts, Keyword.get(opts, :recursive, false), 0)
    |> Enum.flat_map(fn path ->
      name = path |> Path.relative_to(dir) |> Path.rootname()
      load_rule(path, name, level, :standard)
    end)
  end

  defp legacy_rule(path, name, level) do
    if File.regular?(path), do: load_rule(path, name, level, :legacy), else: []
  end

  # Sorted regular files with one of `exts`; hidden entries and symlinked
  # directories are skipped.
  defp list_files(_dir, _exts, _recursive, depth) when depth > @max_rule_dir_depth, do: []

  defp list_files(dir, exts, recursive, depth) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %{type: :directory}} when recursive ->
              list_files(path, exts, true, depth + 1)

            {:ok, %{type: type}} when type in [:regular, :symlink] ->
              if Path.extname(name) in exts and File.regular?(path), do: [path], else: []

            _ ->
              []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # ============================================================================
  # Parsing
  # ============================================================================

  defp load_rule(path, name, level, kind) do
    with {:ok, content} <- File.read(path),
         true <- String.valid?(content),
         {frontmatter, body} = parse_frontmatter(content),
         true <- parse_boolean(frontmatter["enabled"]) != false,
         body when body != "" <- String.trim(body) do
      [build_rule(kind, frontmatter, %{name: name, path: path, content: body, level: level})]
    else
      _ -> []
    end
  end

  defp build_rule(:legacy, frontmatter, base) do
    frontmatter
    |> standard_fields()
    |> Map.merge(%{always_apply: true, manual: false})
    |> Map.merge(base)
  end

  defp build_rule(:github, frontmatter, base) do
    fields = standard_fields(frontmatter)
    apply_to = parse_globs(frontmatter["applyTo"])

    fields =
      cond do
        Enum.any?(apply_to, &(&1 in @github_always_globs)) ->
          %{fields | always_apply: true, globs: []}

        apply_to == [] ->
          %{
            fields
            | always_apply: false,
              description:
                fields.description || "GitHub Copilot instructions without applyTo metadata"
          }

        true ->
          %{
            fields
            | always_apply: false,
              globs: apply_to,
              description:
                fields.description ||
                  "GitHub Copilot instructions for " <> Enum.join(apply_to, ", ")
          }
      end

    Map.merge(fields, base)
  end

  defp build_rule(:standard, frontmatter, base) do
    Map.merge(standard_fields(frontmatter), base)
  end

  defp standard_fields(frontmatter) do
    trigger = frontmatter["trigger"]

    %{
      description: parse_description(frontmatter["description"]),
      globs: parse_globs(frontmatter["globs"]),
      always_apply: parse_boolean(frontmatter["alwaysApply"]) == true or trigger == "always_on",
      manual: trigger == "manual"
    }
  end

  defp parse_description(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      description -> description
    end
  end

  defp parse_description(_value), do: nil

  defp parse_globs(value) when is_binary(value), do: parse_globs([value])

  defp parse_globs(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&split_globs/1)
    |> Enum.uniq()
  end

  defp parse_globs(_value), do: []

  # Split on commas outside `{...}`/`[...]` groups, so `src/*.{ts,tsx}` stays
  # one glob.
  defp split_globs(value) do
    {tokens, current, _depth} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", 0}, fn
        ",", {tokens, current, 0} ->
          {[current | tokens], "", 0}

        char, {tokens, current, depth} when char in ["{", "["] ->
          {tokens, current <> char, depth + 1}

        char, {tokens, current, depth} when char in ["}", "]"] ->
          {tokens, current <> char, max(depth - 1, 0)}

        char, {tokens, current, depth} ->
          {tokens, current <> char, depth}
      end)

    [current | tokens]
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_boolean(value) when is_boolean(value), do: value

  defp parse_boolean(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "true" -> true
      "false" -> false
      _ -> nil
    end
  end

  defp parse_boolean(_value), do: nil

  defp parse_frontmatter(content) do
    content = String.replace(content, "\r\n", "\n")

    case Regex.run(~r/\A---[ \t]*\n(?:(.*?)\n)?---[ \t]*(?:\n|\z)(.*)\z/s, content) do
      [_, meta, body] -> {parse_metadata(meta), body}
      nil -> {%{}, content}
    end
  end

  defp parse_metadata(""), do: %{}

  defp parse_metadata(meta) do
    case YamlElixir.read_from_string(meta) do
      {:ok, map} when is_map(map) -> normalize_keys(map)
      {:ok, _other} -> %{}
      {:error, _reason} -> fallback_metadata(meta)
    end
  end

  # Line-by-line `key: value` parse for frontmatter that is not valid YAML.
  # Each value is parsed on its own and kept as the raw string when that fails.
  defp fallback_metadata(meta) do
    meta
    |> String.split("\n")
    |> Enum.reduce(%{}, fn line, acc ->
      case Regex.run(~r/^([\w-]+):\s*(.*)$/, line) do
        [_, key, raw] -> Map.put(acc, normalize_key(key), fallback_value(String.trim(raw)))
        nil -> acc
      end
    end)
  end

  defp fallback_value(""), do: nil

  defp fallback_value(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, value} when is_binary(value) or is_boolean(value) or is_number(value) -> value
      {:ok, value} when is_list(value) -> value
      _ -> raw
    end
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {normalize_key(key), value}
      pair -> pair
    end)
  end

  # Kebab-case keys (`always-apply`) are read as camelCase (`alwaysApply`).
  defp normalize_key(key) do
    Regex.replace(~r/-([a-z])/, key, fn _, char -> String.upcase(char) end)
  end
end
