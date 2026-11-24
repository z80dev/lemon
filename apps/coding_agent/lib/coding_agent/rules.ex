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
  files always apply. Frontmatter is parsed by `LemonSkills.Frontmatter`;
  invalid YAML falls back to plain `key: value` lines, so Cursor's unquoted
  `globs: *.ts` parses. A repeated key (also `always-apply` next to
  `alwaysApply`) or frontmatter over 16 KiB rejects the rule with a warning;
  it still shadows lower-priority rules of the same name.

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

  Always-apply rules are injected in full, up to the limits below. Other rules
  with a description or globs are listed in a rulebook index (name,
  description, globs, absolute path) for the model to `read` when they apply.
  Rules with neither are not surfaced. Rule files are repository data with the
  same trust as `AGENTS.md`. Output is sorted by name, so prompt bytes are
  stable.

  ## Limits

  At most 256 rule files are read per discovery, in precedence order (project
  sources first); when more exist, `sections/1` adds a note that the rest were
  ignored. Each rule file is read up to 64 KiB, and a longer body ends with a
  marker naming its path. Always-apply bodies share a 128 KiB budget; a body
  past it is cut or replaced by a marker naming its path. Rulebook
  descriptions are collapsed to one line of at most 300 characters. Reads go
  through `CodingAgent.ResourceLoader.SourceReader`, which caches them per
  session by file stat; parsed rules are cached by content.
  """

  require Logger

  alias CodingAgent.Config
  alias CodingAgent.ResourceLoader.SourceReader
  alias LemonCore.TrustedRoot
  alias LemonSkills.Frontmatter

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
  @max_frontmatter_bytes 16 * 1024
  # Prompt limits. A rule file is read up to 64 KiB, the per-file limit of
  # `@` imports and command files; always-apply bodies share 128 KiB (half the
  # 256 KiB instruction-file budget); at most 256 rule files are read per
  # discovery, so a monorepo rule set cannot flood the rulebook; a rulebook
  # description is one line of at most 300 characters.
  @max_rule_bytes 64 * 1024
  @max_always_apply_bytes 128 * 1024
  @max_rule_files 256
  @max_description_chars 300

  @doc """
  Discover enabled, valid rules for `cwd`: project rules first, deduplicated
  by name, sorted by name. Invalid stream declarations still shadow namesakes.
  Project stream rules are dropped unless the operator allows them for this
  trusted root. At most #{@max_rule_files} rule files are read, in precedence
  order.
  """
  @spec discover(String.t()) :: [rule()]
  def discover(cwd), do: cwd |> discover_limited() |> elem(0)

  # `{rules, limited?}`: `limited?` when more than `@max_rule_files` files exist.
  defp discover_limited(cwd) do
    SourceReader.span(:rules, fn ->
      home = Config.home_dir()

      {project_root, project_candidates} =
        case TrustedRoot.project(cwd) do
          {root, ancestors} -> {root, project_rules(ancestors, root, home)}
          :none -> {nil, []}
        end

      candidates =
        project_candidates |> Stream.concat(global_rules(home)) |> Enum.take(@max_rule_files + 1)

      limited? = length(candidates) > @max_rule_files

      {project, global} =
        candidates
        |> Enum.take(@max_rule_files)
        |> Enum.flat_map(&load_rule/1)
        |> Enum.split_with(&(&1.level == :project))

      rules =
        (gate_project_stream_rules(project, project_root) ++ global)
        |> Enum.uniq_by(& &1.name)
        |> Enum.reject(
          &(Map.has_key?(&1, :rejected) or &1.stream_pattern == :invalid or
              &1.injection_limit == :invalid)
        )
        |> Enum.sort_by(& &1.name)

      {rules, limited?}
    end)
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
  section per always-apply rule, then one `:context_files` rulebook index and,
  when more than #{@max_rule_files} rule files exist, a `:system_prompt` note
  that the rest were not loaded. Always-apply bodies share a
  #{div(@max_always_apply_bytes, 1024)} KiB budget. Labels carry the rule name
  and scope, never an absolute path.
  """
  @spec sections(String.t()) :: [section()]
  def sections(cwd) do
    {rules, limited?} = discover_limited(cwd)
    %{always_apply: always, rulebook: rulebook} = buckets(rules)
    always_sections(always) ++ rulebook_sections(rulebook) ++ limit_sections(limited?)
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

    {sections, _remaining} =
      Enum.map_reduce(rules, @max_always_apply_bytes, fn rule, remaining ->
        {body, remaining} = always_body(rule, remaining)

        {%{
           category: :context_files,
           label: "rule #{rule.name} (#{rule.level})",
           text: "<!-- Rule: #{rule.name} (from: #{rule.path}) -->\n#{body}"
         }, remaining}
      end)

    [header | sections]
  end

  defp always_body(rule, remaining) when byte_size(rule.content) <= remaining,
    do: {rule.content, remaining - byte_size(rule.content)}

  defp always_body(rule, remaining) do
    budget = "the #{div(@max_always_apply_bytes, 1024)} KiB always-apply rule budget is exhausted"

    body =
      case SourceReader.truncate_utf8(rule.content, remaining) do
        "" -> "[... rule not loaded: #{budget}; read #{rule.path} and follow it]"
        kept -> kept <> "\n\n[... rule truncated: #{budget}; read #{rule.path} for the rest]"
      end

    {body, 0}
  end

  defp limit_sections(false), do: []

  defp limit_sections(true) do
    [
      %{
        category: :system_prompt,
        label: "Rule limit",
        text:
          "Note: only the first #{@max_rule_files} rule files were loaded (project rules " <>
            "first, in precedence order); the remaining rule files were ignored."
      }
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
    head =
      case rule.description && one_line(rule.description) do
        nil -> "- #{rule.name}"
        description -> "- #{rule.name}: #{description}"
      end

    globs = if rule.globs == [], do: [], else: ["  Globs: " <> Enum.join(rule.globs, ", ")]
    Enum.join([head | globs] ++ ["  File: #{rule.path}"], "\n")
  end

  defp one_line(text) do
    text = text |> String.split() |> Enum.join(" ")

    if String.length(text) > @max_description_chars,
      do: String.slice(text, 0, @max_description_chars - 1) <> "…",
      else: text
  end

  # ============================================================================
  # Discovery
  # ============================================================================

  # Sources yield candidates `{path, name, level, kind, root}` lazily in
  # precedence order, so discovery stops listing once the file limit is met.
  #
  # `ancestors` is cwd and its ancestors up to the trusted root (realpaths,
  # nearest first); empty when cwd does not resolve inside the root.
  defp project_rules([], _root, _home), do: []

  defp project_rules([cwd | _] = ancestors, root, home) do
    dirs = project_dirs(ancestors, home)

    Stream.concat([
      Stream.flat_map(dirs, &rule_dir(Path.join([&1, ".lemon", "rules"]), :project, root)),
      Stream.flat_map(dirs, fn dir ->
        Stream.flat_map(@agent_dirs, &rule_dir(Path.join([dir, &1, "rules"]), :project, root))
      end),
      rule_dir(Path.join([cwd, ".cursor", "rules"]), :project, root, recursive: true),
      legacy_rule(Path.join(cwd, ".cursorrules"), "cursorrules", :project, root),
      rule_dir(Path.join([cwd, ".windsurf", "rules"]), :project, root, exts: [".md"]),
      legacy_rule(Path.join(cwd, ".windsurfrules"), "windsurfrules", :project, root),
      lazy(fn -> clinerules(dirs, root) end),
      github_instructions(Path.join([cwd, ".github", "instructions"]), root)
    ])
  end

  defp global_rules(home) do
    Stream.concat([
      rule_dir(Path.join(Path.expand(Config.agent_dir()), "rules"), :global, :unconfined),
      Stream.flat_map(
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

  defp lazy(fun), do: Stream.flat_map([nil], fn nil -> fun.() end)

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
    lazy(fn ->
      if admit_dir?(dir, root) do
        dir
        |> list_files([".md"], true, 0, root)
        |> Stream.filter(&String.ends_with?(&1, ".instructions.md"))
        |> Stream.map(fn path ->
          name = path |> Path.relative_to(dir) |> String.replace_suffix(".instructions.md", "")
          {path, name, :project, :github, root}
        end)
      else
        []
      end
    end)
  end

  defp rule_dir(dir, level, root, opts \\ []) do
    exts = Keyword.get(opts, :exts, @rule_exts)

    lazy(fn ->
      if admit_dir?(dir, root) do
        dir
        |> list_files(exts, Keyword.get(opts, :recursive, false), 0, root)
        |> Stream.map(fn path ->
          {path, path |> Path.relative_to(dir) |> Path.rootname(), level, :standard, root}
        end)
      else
        []
      end
    end)
  end

  defp legacy_rule(path, name, level, root) do
    lazy(fn -> if admit_file?(path, root), do: [{path, name, level, :legacy, root}], else: [] end)
  end

  # Project files and directories must resolve inside the trusted root (a
  # symlink pointing out of it is ignored) and files must be single-linked.
  # Global rule locations are home-owned.
  defp admit_file?(path, :unconfined), do: File.regular?(path)
  defp admit_file?(path, root), do: match?({:ok, _}, TrustedRoot.file(path, root))

  defp admit_dir?(_dir, :unconfined), do: true
  defp admit_dir?(dir, root), do: match?({:ok, _}, TrustedRoot.dir(dir, root))

  # Sorted admitted files with one of `exts`, lazily; hidden entries and
  # symlinked directories are skipped.
  defp list_files(_dir, _exts, _recursive, depth, _root) when depth > @max_rule_dir_depth,
    do: []

  defp list_files(dir, exts, recursive, depth, root) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()
        |> Stream.flat_map(fn name ->
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

  # Project rules are read from the validated realpath, never the original
  # spelling, so a link swapped in after discovery is re-checked. Reads are
  # bounded and the parsed rule is cached while the file is unchanged.
  defp load_rule({path, name, level, kind, root}) do
    case SourceReader.read(path, root, max_bytes: @max_rule_bytes) do
      {:ok, %{content: content, truncated: truncated}} ->
        SourceReader.memo({:rule, path, name, level, kind, root}, {content, truncated}, fn ->
          parse_rule(content, truncated, %{name: name, path: path, level: level}, kind)
        end)

      :error ->
        []
    end
  end

  defp parse_rule(content, truncated, base, kind) do
    case parse_frontmatter(content, truncated) do
      {:ok, frontmatter, body} ->
        body =
          if truncated,
            do:
              body <>
                "\n\n[... rule truncated at #{div(@max_rule_bytes, 1024)} KiB; read " <>
                "#{base.path} for the rest]",
            else: body

        build_enabled_rule(kind, frontmatter, base, body)

      {:error, reason} ->
        Logger.warning("Ignored rule #{base.name}: #{rejection_reason(reason)}")
        [rejected_rule(base, reason)]
    end
  end

  defp build_enabled_rule(kind, frontmatter, base, body) do
    with true <- parse_boolean(frontmatter["enabled"]) != false,
         body when body != "" <- String.trim(body) do
      [build_rule(kind, frontmatter, Map.put(base, :content, body))]
    else
      _ -> []
    end
  end

  # A rule whose frontmatter is refused still shadows lower-priority rules of
  # the same name; `discover/1` drops it after deduplication.
  defp rejected_rule(base, reason) do
    %{}
    |> standard_fields()
    |> Map.merge(base)
    |> Map.merge(%{content: "", rejected: reason})
  end

  defp rejection_reason(:too_large),
    do: "frontmatter exceeds #{div(@max_frontmatter_bytes, 1024)} KiB"

  defp rejection_reason(reason), do: Frontmatter.describe_error(reason)

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

  # A truncated read that starts a frontmatter block but never closes it had
  # frontmatter longer than the whole read limit.
  defp parse_frontmatter(content, truncated) do
    content = String.replace(content, "\r\n", "\n")

    case Regex.run(~r/\A---[ \t]*\n(?:(.*?)\n)?---[ \t]*(?:\n|\z)(.*)\z/s, content) do
      [_, meta, body] ->
        with {:ok, frontmatter} <- parse_metadata(meta), do: {:ok, frontmatter, body}

      nil ->
        if truncated and Regex.match?(~r/\A---[ \t]*\n/, content),
          do: {:error, :too_large},
          else: {:ok, %{}, content}
    end
  end

  defp parse_metadata(""), do: {:ok, %{}}

  defp parse_metadata(meta) do
    case Frontmatter.parse_yaml(meta, max_bytes: @max_frontmatter_bytes) do
      {:ok, map} -> map |> Enum.to_list() |> normalize_pairs()
      {:error, :malformed} -> meta |> fallback_pairs() |> normalize_pairs()
      {:error, :not_a_mapping} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Line-by-line `key: value` parse for frontmatter that is not valid YAML.
  # Each value is parsed on its own and kept as the raw string when that fails.
  defp fallback_pairs(meta) do
    meta
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([\w-]+):\s*(.*)$/, line) do
        [_, key, raw] -> [{key, fallback_value(String.trim(raw))}]
        nil -> []
      end
    end)
  end

  defp fallback_value(""), do: nil

  defp fallback_value(raw) do
    case Frontmatter.parse_yaml("value: " <> raw) do
      {:ok, %{"value" => value}}
      when is_binary(value) or is_boolean(value) or is_number(value) or is_list(value) ->
        value

      _ ->
        raw
    end
  end

  # Kebab-case keys (`always-apply`) are read as camelCase (`alwaysApply`).
  # Keys that repeat, also after that normalization, are refused as in
  # subagent definitions.
  defp normalize_pairs(pairs) do
    pairs = Enum.map(pairs, fn {key, value} -> {normalize_key(key), value} end)

    if length(Enum.uniq_by(pairs, &elem(&1, 0))) == length(pairs),
      do: {:ok, Map.new(pairs)},
      else: {:error, :duplicate_key}
  end

  defp normalize_key(key) do
    Regex.replace(~r/-([a-z])/, key, fn _, char -> String.upcase(char) end)
  end
end
