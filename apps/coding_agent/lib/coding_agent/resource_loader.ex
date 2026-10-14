defmodule CodingAgent.ResourceLoader do
  @moduledoc """
  Loads resources like CLAUDE.md, AGENTS.md, and prompt files.

  Resources are loaded from:
  - Project directory (cwd) and parent directories up to root
  - Home directory (`~/.claude/`, `~/.lemon/`, and other agent tools' homes)
  - Extension paths

  ## Instruction Files

  Instruction files provide context and guidelines for the coding agent.
  Each directory from the filesystem root to cwd contributes, in order:

  - root files `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `CLAUDE.local.md`
  - `.claude/{CLAUDE,AGENTS}.md`, `.lemon/{CLAUDE,AGENTS}.md`,
    `.gemini/GEMINI.md`, `.agents/AGENTS.md`, `.agent/AGENTS.md`,
    `.omp/AGENTS.md` and `.github/copilot-instructions.md`

  Global files come first: `~/.claude/{CLAUDE,AGENTS}.md`,
  `~/.gemini/GEMINI.md`, `~/.codex/AGENTS.md`,
  `~/.config/opencode/AGENTS.md`, `~/.agents/AGENTS.md`, `~/.agent/AGENTS.md`,
  `$COPILOT_HOME/copilot-instructions.md` (default `~/.copilot`),
  `~/.lemon/{CLAUDE,AGENTS}.md` and the agent directory's `{CLAUDE,AGENTS}.md`.
  The home directory comes from `CodingAgent.Config.home_dir/0`.

  Global instructions are rendered first, followed by ancestors from
  filesystem root to cwd. Directory instructions apply to that directory's
  subtree (a config subdirectory such as `.github/` scopes to its parent);
  more specific instructions override broader ones. Each physical file is
  loaded once, including symlink or hard-link aliases. `@path` imports are
  expanded by `CodingAgent.ResourceLoader.AtImports`.

  ## Resource Priorities

  For prompts, themes and skills, the following priority order is used:
  1. Project-local files (`.claude/`, `.lemon/`, or root)
  2. Parent directories walking up to filesystem root
  3. Home directory files (`~/.claude/`, `~/.lemon/agent/`)

  ## Example

      # Load all instruction files for a project
      instructions = CodingAgent.ResourceLoader.load_instructions("/path/to/project")

      # Load agent definitions
      agents = CodingAgent.ResourceLoader.load_agents("/path/to/project")
  """

  alias CodingAgent.Config
  alias CodingAgent.ResourceLoader.AtImports
  alias LemonSkills.Config, as: SkillConfig

  # Instruction file names read from each directory itself
  @root_instruction_files ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "CLAUDE.local.md"]

  # Instruction files read from config subdirectories of each directory. An
  # explicit map: each tool's directory only holds its own file names.
  @subdir_instruction_files [
    {".claude", ["CLAUDE.md", "AGENTS.md"]},
    {".lemon", ["CLAUDE.md", "AGENTS.md"]},
    {".gemini", ["GEMINI.md"]},
    {".agents", ["AGENTS.md"]},
    {".agent", ["AGENTS.md"]},
    {".omp", ["AGENTS.md"]},
    {".github", ["copilot-instructions.md"]}
  ]

  @config_subdirs Enum.map(@subdir_instruction_files, &elem(&1, 0))

  # ============================================================================
  # Instruction Loading
  # ============================================================================

  @doc """
  Load CLAUDE.md, AGENTS.md and the other instruction files.

  Searches global home locations first, then ancestors from filesystem root
  to cwd. Each ancestor includes its root instruction files and those in its
  config subdirectories (see the module documentation).

  Files are combined from general to specific, with source and scope headers
  and an explicit scoped-precedence rule. Duplicate physical files appear once.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A string containing the combined content of all found instruction files,
  with file headers indicating the source of each section.

  ## Examples

      instructions = CodingAgent.ResourceLoader.load_instructions("/home/user/project")
      # Returns combined content with headers like:
      # <!-- From: /home/user/.claude/CLAUDE.md -->
      # ... global content ...
      # <!-- From: /home/user/project/CLAUDE.md -->
      # ... project content ...
  """
  @spec load_instructions(String.t()) :: String.t()
  def load_instructions(cwd) do
    cwd
    |> instruction_sections()
    |> Enum.map_join("\n\n", & &1.text)
  end

  @doc """
  The pieces `load_instructions/1` joins with blank lines, each labelled for
  context-usage accounting: the precedence header (category `:system_prompt`)
  followed by one `:context_files` section per instruction file. Labels carry
  only the file name and a coarse scope (`global`, `project`, `parent`), never
  the absolute path.
  """
  @spec instruction_sections(String.t()) :: [
          %{category: atom(), label: String.t(), text: String.t()}
        ]
  def instruction_sections(cwd) do
    cwd
    |> find_instruction_files()
    |> combined_sections(Path.expand(cwd))
  end

  @doc """
  Load instruction files and return as a list with metadata.

  Similar to `load_instructions/1` but returns structured data
  instead of combined content.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A list of maps with `:path` and `:content` keys, in the same global-first,
  ancestor-root-to-cwd order as `load_instructions/1`, deduplicated by file
  identity. Content has `@path` imports expanded.

  ## Examples

      files = CodingAgent.ResourceLoader.load_instructions_list("/home/user/project")
      # => [%{path: "/home/user/project/CLAUDE.md", content: "..."}]
  """
  @spec load_instructions_list(String.t()) :: [%{path: String.t(), content: String.t()}]
  def load_instructions_list(cwd) do
    home = Config.home_dir()

    cwd
    |> find_instruction_files()
    |> Enum.map(fn path ->
      %{path: path, content: read_instruction_file(path, home)}
    end)
    |> Enum.reject(fn %{content: content} -> content == "" end)
  end

  @doc """
  Whether `path` (absolute or relative) names an instruction file this loader
  reads from a directory: a root instruction file name, or a file name inside
  its matching config subdirectory (for example `.github/copilot-instructions.md`).
  Used to index descendant guides that are not loaded into the prompt.
  """
  @spec instruction_guide?(String.t()) :: boolean()
  def instruction_guide?(path) do
    name = Path.basename(path)

    name in @root_instruction_files or
      Enum.any?(@subdir_instruction_files, fn {subdir, names} ->
        name in names and Path.basename(Path.dirname(path)) == subdir
      end)
  end

  # ============================================================================
  # Agent Definitions
  # ============================================================================

  @doc """
  Load AGENTS.md for agent definitions.

  AGENTS.md files can define custom agent personas, tool configurations,
  and workflow instructions.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A string containing all found AGENTS.md files, global first and then
  ancestors from root to cwd, with the same scope and deduplication semantics
  as `load_instructions/1`.

  ## Examples

      agents = CodingAgent.ResourceLoader.load_agents("/home/user/project")
  """
  @spec load_agents(String.t()) :: String.t()
  def load_agents(cwd) do
    cwd
    |> find_specific_files(["AGENTS.md"])
    |> combined_sections(Path.expand(cwd))
    |> Enum.map_join("\n\n", & &1.text)
  end

  # ============================================================================
  # Prompt Loading
  # ============================================================================

  @doc """
  Load prompt files from standard locations.

  Prompts are loaded from:
  - Project-local prompts (`.lemon/prompts/`)
  - Global prompts (`~/.lemon/agent/prompts/`)

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A map where keys are prompt names (filename without extension)
  and values are the prompt content.

  ## Examples

      prompts = CodingAgent.ResourceLoader.load_prompts("/home/user/project")
      # => %{"review" => "...", "refactor" => "..."}
  """
  @spec load_prompts(String.t()) :: %{String.t() => String.t()}
  def load_prompts(cwd) do
    prompt_dirs = [
      Path.join([cwd, ".lemon", "prompts"]),
      Path.join([cwd, ".claude", "prompts"]),
      Config.prompts_dir()
    ]

    prompt_dirs
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(&list_prompt_files/1)
    |> Enum.reduce(%{}, fn path, acc ->
      name = Path.basename(path, Path.extname(path))
      # First found wins (project-local takes precedence)
      Map.put_new(acc, name, read_file_safe(path))
    end)
  end

  @doc """
  Load a specific prompt by name.

  Searches for a prompt file matching the given name in:
  - Project-local prompts (`.lemon/prompts/`)
  - Global prompts (`~/.lemon/agent/prompts/`)

  ## Parameters

    * `cwd` - The current working directory
    * `name` - The prompt name (without extension)

  ## Returns

    * `{:ok, content}` - The prompt content if found
    * `{:error, :not_found}` - If the prompt doesn't exist

  ## Examples

      {:ok, prompt} = CodingAgent.ResourceLoader.load_prompt("/path/to/project", "review")
  """
  @spec load_prompt(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_prompt(cwd, name) do
    prompt_dirs = [
      Path.join([cwd, ".lemon", "prompts"]),
      Path.join([cwd, ".claude", "prompts"]),
      Config.prompts_dir()
    ]

    extensions = [".md", ".txt", ""]

    result =
      for dir <- prompt_dirs,
          ext <- extensions,
          path = Path.join(dir, "#{name}#{ext}"),
          File.regular?(path) do
        path
      end
      |> List.first()

    case result do
      nil -> {:error, :not_found}
      path -> {:ok, read_file_safe(path)}
    end
  end

  # ============================================================================
  # Theme Loading
  # ============================================================================

  @doc """
  Load theme configuration by name.

  Themes define UI colors and styling. They are loaded from:
  - Project-local themes (`.lemon/themes/`)
  - Global themes (`~/.lemon/agent/themes/`)

  ## Parameters

    * `name` - The theme name

  ## Returns

    * `{:ok, theme_config}` - The parsed theme configuration
    * `{:error, :not_found}` - If the theme doesn't exist
    * `{:error, reason}` - If parsing fails

  ## Examples

      {:ok, theme} = CodingAgent.ResourceLoader.load_theme("dark")
  """
  @spec load_theme(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def load_theme(name) do
    theme_dirs = [
      Path.join(Config.agent_dir(), "themes")
    ]

    result =
      for dir <- theme_dirs,
          path = Path.join(dir, "#{name}.json"),
          File.regular?(path) do
        path
      end
      |> List.first()

    case result do
      nil ->
        {:error, :not_found}

      path ->
        case File.read(path) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, theme} -> {:ok, theme}
              {:error, reason} -> {:error, {:parse_error, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # ============================================================================
  # Skills Loading
  # ============================================================================

  @doc """
  Load skill definitions from standard locations.

  Skills are reusable agent capabilities defined in markdown files.
  They are loaded from:
  - Project-local skills (`.lemon/skill/*/SKILL.md`)
  - Global skills (`~/.lemon/agent/skill/*/SKILL.md`)
  - Harness-compatible global skills (`~/.agents/skills/*/SKILL.md`)

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A map where keys are skill names and values are skill content.

  ## Examples

      skills = CodingAgent.ResourceLoader.load_skills("/home/user/project")
      # => %{"commit" => "...", "review-pr" => "..."}
  """
  @spec load_skills(String.t()) :: %{String.t() => String.t()}
  def load_skills(cwd) do
    cwd
    |> skill_dirs()
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir ->
      dir
      |> File.ls!()
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.join(&1, "SKILL.md"))
      |> Enum.filter(&File.regular?/1)
    end)
    |> Enum.reduce(%{}, fn path, acc ->
      key = Path.basename(Path.dirname(path))
      Map.put_new(acc, key, read_file_safe(path))
    end)
  end

  @doc """
  Load a specific skill by name.

  ## Parameters

    * `cwd` - The current working directory
    * `name` - The skill name

  ## Returns

    * `{:ok, content}` - The skill content if found
    * `{:error, :not_found}` - If the skill doesn't exist

  ## Examples

      {:ok, skill} = CodingAgent.ResourceLoader.load_skill("/path/to/project", "commit")
  """
  @spec load_skill(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def load_skill(cwd, name) do
    result =
      for dir <- skill_dirs(cwd),
          path = Path.join([dir, name, "SKILL.md"]),
          File.regular?(path) do
        path
      end
      |> List.first()

    case result do
      nil -> {:error, :not_found}
      path -> {:ok, read_file_safe(path)}
    end
  end

  # ============================================================================
  # Utility Functions
  # ============================================================================

  @doc """
  Check if a resource file exists.

  ## Parameters

    * `cwd` - The current working directory
    * `filename` - The filename to look for

  ## Returns

  `true` if the file exists in any of the searched locations.
  """
  @spec resource_exists?(String.t(), String.t()) :: boolean()
  def resource_exists?(cwd, filename) do
    cwd
    |> find_specific_files([filename])
    |> Enum.any?()
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Find all instruction files for a cwd
  @spec find_instruction_files(String.t()) :: [String.t()]
  defp find_instruction_files(cwd) do
    find_files(cwd, @root_instruction_files, nil)
  end

  # Find specific file names in all search locations
  @spec find_specific_files(String.t(), [String.t()]) :: [String.t()]
  defp find_specific_files(cwd, filenames) do
    find_files(cwd, filenames, filenames)
  end

  # Global sources first, then each ancestor from root to cwd: its root files,
  # then its config subdirectories. `only` (when given) restricts the config
  # subdirectory and global candidates to those file names.
  defp find_files(cwd, root_names, only) do
    global = candidate_paths(global_instruction_sources(Config.home_dir()), only)

    local =
      cwd
      |> Path.expand()
      |> walk_to_root()
      |> Enum.reverse()
      |> Enum.flat_map(fn dir ->
        subdirs =
          Enum.map(@subdir_instruction_files, fn {subdir, names} ->
            {Path.join(dir, subdir), names}
          end)

        Enum.map(root_names, &Path.join(dir, &1)) ++ candidate_paths(subdirs, only)
      end)

    {files, _seen} = deduplicate_files(Enum.filter(global ++ local, &File.regular?/1))
    files
  end

  defp candidate_paths(sources, only) do
    for {dir, names} <- sources, name <- names, only == nil or name in only do
      Path.join(dir, name)
    end
  end

  # Keep the most specific spelling of a physical file, not an earlier global
  # alias that would change its precedence relative to other local guides.
  defp deduplicate_files([]), do: {[], MapSet.new()}

  defp deduplicate_files([path | rest]) do
    {files, seen} = deduplicate_files(rest)
    identity = file_identity(path)

    if MapSet.member?(seen, identity) do
      {files, seen}
    else
      {[path | files], MapSet.put(seen, identity)}
    end
  end

  # Global instruction files, broad external tools first and Lemon's own last.
  defp global_instruction_sources(home) do
    [
      {Path.join(home, ".claude"), ["CLAUDE.md", "AGENTS.md"]},
      {Path.join(home, ".gemini"), ["GEMINI.md"]},
      {Path.join(home, ".codex"), ["AGENTS.md"]},
      {Path.join([home, ".config", "opencode"]), ["AGENTS.md"]},
      {Path.join(home, ".agents"), ["AGENTS.md"]},
      {Path.join(home, ".agent"), ["AGENTS.md"]},
      {copilot_home(home), ["copilot-instructions.md"]},
      {Path.join(home, ".lemon"), ["CLAUDE.md", "AGENTS.md"]},
      {Path.expand(Config.agent_dir()), ["CLAUDE.md", "AGENTS.md"]}
    ]
  end

  # GitHub Copilot CLI relocates its user config with COPILOT_HOME.
  defp copilot_home(home) do
    case String.trim(System.get_env("COPILOT_HOME") || "") do
      "" -> Path.join(home, ".copilot")
      dir -> Path.expand(dir)
    end
  end

  defp global_instruction_dirs(home) do
    home |> global_instruction_sources() |> Enum.map(&elem(&1, 0))
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %{inode: inode, major_device: major, minor_device: minor}} when inode != 0 ->
        {major, minor, inode}

      _ ->
        Path.expand(path)
    end
  end

  defp instruction_scope(path, global_dirs) do
    dir = Path.dirname(path)

    if dir in global_dirs do
      "global"
    else
      scope = if Path.basename(dir) in @config_subdirs, do: Path.dirname(dir), else: dir
      "#{scope} (this directory and its descendants)"
    end
  end

  # Walk from a directory up to the filesystem root
  @spec walk_to_root(String.t()) :: [String.t()]
  defp walk_to_root(path) do
    do_walk_to_root(path, [])
  end

  defp do_walk_to_root("/", acc), do: Enum.reverse(["/"] ++ acc)

  defp do_walk_to_root(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path] ++ acc)
    else
      do_walk_to_root(parent, [path | acc])
    end
  end

  # Load files and split them into the header plus one labelled section per
  # file; joining the texts with blank lines gives the combined instructions.
  defp combined_sections(paths, cwd) do
    home = Config.home_dir()
    global_dirs = global_instruction_dirs(home)

    files =
      Enum.flat_map(paths, fn path ->
        case read_instruction_file(path, home) do
          "" ->
            []

          content ->
            [
              %{
                category: :context_files,
                label: "#{Path.basename(path)} (#{scope_label(path, global_dirs, cwd)})",
                text:
                  "<!-- From: #{path} -->\nScope: #{instruction_scope(path, global_dirs)}\n\n#{content}"
              }
            ]
        end
      end)

    case files do
      [] ->
        []

      _ ->
        [
          %{
            category: :system_prompt,
            label: "Repository instruction rules",
            text:
              "## Repository instructions\n" <>
                "Global instructions apply generally. Directory instructions apply only within " <>
                "their stated subtree. More specific directory instructions override conflicting " <>
                "broader instructions; read applicable descendant guides before editing there. " <>
                "Sources are ordered global first, then ancestors from root to working directory."
          }
          | files
        ]
    end
  end

  defp scope_label(path, global_dirs, cwd) do
    dir = Path.dirname(path)
    scope = if Path.basename(dir) in @config_subdirs, do: Path.dirname(dir), else: dir

    cond do
      dir in global_dirs -> "global"
      scope == cwd -> "project"
      true -> "parent"
    end
  end

  # Safely read a file, returning empty string on error
  @spec read_file_safe(String.t()) :: String.t()
  defp read_file_safe(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> ""
    end
  end

  # Read an instruction file with its `@path` imports expanded.
  defp read_instruction_file(path, home) do
    case File.read(path) do
      {:ok, content} -> content |> AtImports.expand(path, home: home) |> String.trim()
      {:error, _} -> ""
    end
  end

  # Skill directories in precedence order.
  @spec skill_dirs(String.t()) :: [String.t()]
  defp skill_dirs(cwd) do
    [
      Path.join([cwd, ".lemon", "skill"]),
      Path.join([Config.agent_dir(), "skill"]),
      SkillConfig.harness_global_skills_dir()
    ]
    |> Enum.uniq()
  end

  # List prompt files in a directory
  @spec list_prompt_files(String.t()) :: [String.t()]
  defp list_prompt_files(dir) do
    patterns = [
      Path.join(dir, "*.md"),
      Path.join(dir, "*.txt")
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
  end
end
