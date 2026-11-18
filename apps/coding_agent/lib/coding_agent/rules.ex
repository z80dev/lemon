defmodule CodingAgent.Rules do
  @moduledoc """
  Discovers rule files written for other coding agents (Cursor, Windsurf,
  Cline, GitHub Copilot, `.agents`) and Lemon's own `.lemon/rules`, and
  separates prompt rules from dormant streaming rules.

  ## Sources

  Project rules, in precedence order. `cwd` is the session's trusted directory
  (`config_cwd`, never a Bot folder); walks stop at its `LemonCore.TrustedRoot`
  (the Git root, else cwd itself):

  - `.lemon/rules/*.{md,mdc}`, then `.agent/rules/*.{md,mdc}` and
    `.agents/rules/*.{md,mdc}`, each walking from cwd up to the trusted root
    (the home directory itself is skipped); nearer directories first
  - `.cursor/rules/**/*.{mdc,md}` and legacy `.cursorrules` in cwd
  - `.windsurf/rules/*.md` and legacy `.windsurfrules` in cwd
  - the nearest `.clinerules` on the same walk: a file, or a directory of `*.md`
  - `.github/instructions/**/*.instructions.md` in cwd

  Every project rule file and rules directory must resolve (after symlinks)
  inside the trusted root, and files must be regular and single-linked; a
  symlink such as `.cursorrules -> ~/.ssh/id_ed25519` is ignored.

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

  `streamPattern` is a non-empty, byte-oriented regex source (no UTF mode).
  `injectionLimit` is a positive integer, defaulting to 1. A stream rule is
  never included in prompt sections, regardless of the other frontmatter.
  Invalid patterns or limits disable the rule without exposing a lower-priority
  rule with the same name. `stream_rules/1` returns these rules for the bounded
  runtime matcher; no matching or injection accounting happens here.

  A matching stream rule injects its body as a `<system-interrupt>`, which is
  operator authority. Global rules may declare `streamPattern`; a project rule
  may only when the operator lists the project's trusted root in the global
  config file (`~/.lemon/config.toml`; a project `.lemon/config.toml` cannot
  grant it):

      [rules]
      allow_project_stream_rules = ["/path/to/project"]

  Unapproved project stream rules are dropped with a warning naming them.

  ## Prompt

  Always-apply rules are injected in full. Other rules with a description or
  globs are listed in a rulebook index (name, description, globs, absolute
  path) for the model to `read` when they apply. Rules with neither are not
  surfaced. Rule files are repository data with the same trust as
  `AGENTS.md`. Output is sorted by name, so prompt bytes are stable.
  """

  require Logger

  alias CodingAgent.Config
  alias LemonCore.TrustedRoot

  @type rule :: %{
          name: String.t(),
          path: String.t(),
          content: String.t(),
          description: String.t() | nil,
          globs: [String.t()],
          always_apply: boolean(),
          manual: boolean(),
          level: :project | :global,
          stream_pattern: String.t() | nil,
          injection_limit: pos_integer()
        }

  @type section :: %{category: atom(), label: String.t(), text: String.t()}

  @rule_exts [".md", ".mdc"]
  @agent_dirs [".agent", ".agents"]
  @github_always_globs ["*", "**", "**/*"]
  @max_rule_dir_depth 8

  @doc """
  Discover enabled, valid rules for `cwd`: project rules first, deduplicated
  by name, sorted by name. Invalid stream declarations still shadow namesakes.
  Project stream rules are dropped unless the operator allows them for this
  trusted root.
  """
  @spec discover(String.t()) :: [rule()]
  def discover(cwd) do
    home = Config.home_dir()
    root = TrustedRoot.resolve(cwd)

    project =
      cwd
      |> TrustedRoot.ancestors(root)
      |> project_rules(root, home)
      |> gate_project_stream_rules(root)

    (project ++ global_rules(home))
    |> Enum.uniq_by(& &1.name)
    |> Enum.reject(&(&1.stream_pattern == :invalid or &1.injection_limit == :invalid))
    |> Enum.sort_by(& &1.name)
  end

  defp gate_project_stream_rules(rules, root) do
    {stream, prompt} = Enum.split_with(rules, &(&1.stream_pattern != nil))

    cond do
      stream == [] ->
        rules

      project_stream_rules_allowed?(root) ->
        rules

      true ->
        Logger.warning(
          "Ignored project stream rules #{Enum.map_join(stream, ", ", & &1.name)} under " <>
            "#{root}: add the root to [rules] allow_project_stream_rules in the global config"
        )

        prompt
    end
  end

  # Operator-only: read the global config file directly so a project
  # `.lemon/config.toml` can never grant itself interrupt authority.
  defp project_stream_rules_allowed?(root) do
    allowed =
      try do
        LemonCore.Config.global_path()
        |> LemonCore.Config.load_file()
        |> get_in(["rules", "allow_project_stream_rules"])
      rescue
        _ -> nil
      end

    is_list(allowed) and
      Enum.any?(allowed, fn
        entry when is_binary(entry) and entry != "" ->
          match?({:ok, ^root}, TrustedRoot.realpath(Path.expand(entry)))

        _ ->
          false
      end)
  end

  @doc """
  Discover dormant stream rules for `cwd`, in name order.

  Each rule includes its `:name`, `:content`, regex source `:stream_pattern`
  and positive `:injection_limit`. Prompt-only rules are excluded. The runtime
  matcher enforces its own caller-policy size and execution limits.
  """
  @spec stream_rules(String.t()) :: [rule()]
  def stream_rules(cwd) do
    cwd
    |> discover()
    |> Enum.filter(&(&1.stream_pattern != nil))
  end

  @doc """
  Split rules into `:always_apply` (bodies injected) and `:rulebook` (indexed
  for on-demand reading). Stream rules, manual rules and rules with neither
  description nor globs are dropped.
  """
  @spec buckets([rule()]) :: %{always_apply: [rule()], rulebook: [rule()]}
  def buckets(rules) do
    always =
      Enum.filter(rules, &(&1.stream_pattern == nil and &1.always_apply and not &1.manual))

    rulebook =
      Enum.filter(rules, fn rule ->
        rule.stream_pattern == nil and not rule.always_apply and not rule.manual and
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

  # `ancestors` is cwd and its ancestors up to the trusted root (realpaths,
  # nearest first); empty when cwd does not resolve inside the root.
  defp project_rules([], _root, _home), do: []

  defp project_rules([cwd | _] = ancestors, root, home) do
    dirs = project_dirs(ancestors, home)

    Enum.concat([
      Enum.flat_map(dirs, &rule_dir(Path.join([&1, ".lemon", "rules"]), :project, root)),
      Enum.flat_map(dirs, fn dir ->
        Enum.flat_map(@agent_dirs, &rule_dir(Path.join([dir, &1, "rules"]), :project, root))
      end),
      rule_dir(Path.join([cwd, ".cursor", "rules"]), :project, root, recursive: true),
      legacy_rule(Path.join(cwd, ".cursorrules"), "cursorrules", :project, root),
      rule_dir(Path.join([cwd, ".windsurf", "rules"]), :project, root, exts: [".md"]),
      legacy_rule(Path.join(cwd, ".windsurfrules"), "windsurfrules", :project, root),
      clinerules(dirs, root),
      github_instructions(Path.join([cwd, ".github", "instructions"]), root)
    ])
  end

  defp global_rules(home) do
    Enum.concat([
      rule_dir(Path.join(Path.expand(Config.agent_dir()), "rules"), :global, :unconfined),
      Enum.flat_map(
        @agent_dirs,
        &rule_dir(Path.join([home, &1, "rules"]), :global, :unconfined)
      ),
      legacy_rule(
        Path.join([home, ".codeium", "windsurf", "memories", "global_rules.md"]),
        "global_rules",
        :global,
        :unconfined
      )
    ])
  end

  # The home directory itself holds global (not project) configuration and is
  # skipped even when it lies inside the trusted root.
  defp project_dirs(ancestors, home) do
    real_home =
      case TrustedRoot.realpath(home) do
        {:ok, real} -> real
        {:error, _} -> Path.expand(home)
      end

    Enum.reject(ancestors, &(&1 == real_home))
  end

  defp clinerules(dirs, root) do
    dirs
    |> Enum.map(&Path.join(&1, ".clinerules"))
    |> Enum.find(&match?({:ok, _}, File.lstat(&1)))
    |> case do
      nil ->
        []

      path ->
        if File.dir?(path),
          do: rule_dir(path, :project, root, exts: [".md"]),
          else: legacy_rule(path, "clinerules", :project, root)
    end
  end

  defp github_instructions(dir, root) do
    if admit_dir?(dir, root) do
      dir
      |> list_files([".md"], true, 0, root)
      |> Enum.filter(&String.ends_with?(&1, ".instructions.md"))
      |> Enum.flat_map(fn path ->
        name = path |> Path.relative_to(dir) |> String.replace_suffix(".instructions.md", "")
        load_rule(path, name, :project, :github, root)
      end)
    else
      []
    end
  end

  defp rule_dir(dir, level, root, opts \\ []) do
    exts = Keyword.get(opts, :exts, @rule_exts)

    if admit_dir?(dir, root) do
      dir
      |> list_files(exts, Keyword.get(opts, :recursive, false), 0, root)
      |> Enum.flat_map(fn path ->
        name = path |> Path.relative_to(dir) |> Path.rootname()
        load_rule(path, name, level, :standard, root)
      end)
    else
      []
    end
  end

  defp legacy_rule(path, name, level, root) do
    if admit_file?(path, root), do: load_rule(path, name, level, :legacy, root), else: []
  end

  # Project rules are read from the validated realpath, never the original
  # spelling, so a link swapped in after discovery is re-checked.
  defp read_rule(path, :unconfined), do: File.read(path)

  defp read_rule(path, root) do
    case TrustedRoot.read(path, root) do
      {:ok, content, _real} -> {:ok, content}
      :error -> :error
    end
  end

  # Project files and directories must resolve inside the trusted root (a
  # symlink pointing out of it is ignored) and files must be single-linked.
  # Global rule locations are home-owned.
  defp admit_file?(path, :unconfined), do: File.regular?(path)
  defp admit_file?(path, root), do: match?({:ok, _}, TrustedRoot.file(path, root))

  defp admit_dir?(_dir, :unconfined), do: true
  defp admit_dir?(dir, root), do: match?({:ok, _}, TrustedRoot.dir(dir, root))

  # Sorted admitted files with one of `exts`; hidden entries and symlinked
  # directories are skipped.
  defp list_files(_dir, _exts, _recursive, depth, _root) when depth > @max_rule_dir_depth,
    do: []

  defp list_files(dir, exts, recursive, depth, root) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          case File.lstat(path) do
            {:ok, %{type: :directory}} when recursive ->
              list_files(path, exts, true, depth + 1, root)

            {:ok, %{type: type}} when type in [:regular, :symlink] ->
              if Path.extname(name) in exts and admit_file?(path, root), do: [path], else: []

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

  defp load_rule(path, name, level, kind, root) do
    with {:ok, content} <- read_rule(path, root),
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
      manual: trigger == "manual",
      stream_pattern: parse_stream_pattern(Map.fetch(frontmatter, "streamPattern")),
      injection_limit: parse_injection_limit(Map.fetch(frontmatter, "injectionLimit"))
    }
  end

  defp parse_stream_pattern(:error), do: nil

  defp parse_stream_pattern({:ok, pattern}) when is_binary(pattern) do
    if String.trim(pattern) == "" do
      :invalid
    else
      case :re.compile(pattern, [:never_utf]) do
        {:ok, _compiled} -> pattern
        {:error, _reason} -> :invalid
      end
    end
  end

  defp parse_stream_pattern(_value), do: :invalid

  defp parse_injection_limit(:error), do: 1
  defp parse_injection_limit({:ok, limit}) when is_integer(limit) and limit > 0, do: limit
  defp parse_injection_limit(_value), do: :invalid

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
