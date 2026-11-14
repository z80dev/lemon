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

  ## Example

      sections = CodingAgent.ResourceLoader.instruction_sections("/path/to/project")
  """

  alias CodingAgent.Config
  alias CodingAgent.ResourceLoader.AtImports

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
  Instruction sections, each labelled for
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
  # Private Functions
  # ============================================================================

  # Find all instruction files for a cwd
  @spec find_instruction_files(String.t()) :: [String.t()]
  defp find_instruction_files(cwd) do
    find_files(cwd, @root_instruction_files, nil)
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

end
