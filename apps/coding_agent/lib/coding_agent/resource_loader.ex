defmodule CodingAgent.ResourceLoader do
  @moduledoc """
  Loads resources like CLAUDE.md, AGENTS.md, and prompt files.

  Resources are loaded from:
  - The trusted directory (the session's `config_cwd`) and its ancestors up to
    its `LemonCore.TrustedRoot` (the Git root, else the directory itself)
  - Home directory (`~/.lemon/`, and other agent tools' homes in coding sessions)
  - Extension paths

  ## Instruction Files

  Instruction files provide context and guidelines for the coding agent.
  Each directory from the trusted root down to cwd contributes, in order:

  - root files `CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `CLAUDE.local.md`
  - `.claude/{CLAUDE,AGENTS}.md`, `.lemon/{CLAUDE,AGENTS}.md`,
    `.gemini/GEMINI.md`, `.agents/AGENTS.md`, `.agent/AGENTS.md`,
    `.omp/AGENTS.md` and `.github/copilot-instructions.md`

  Directories above the trusted root are never read. A directory file must
  resolve (after symlinks) to a regular, single-linked file inside the root.

  Global files come first: `~/.lemon/{CLAUDE,AGENTS}.md` and the agent
  directory's `{CLAUDE,AGENTS}.md`, preceded, only when `foreign_globals: true`
  (coding sessions), by other tools' files: `~/.claude/{CLAUDE,AGENTS}.md`,
  `~/.gemini/GEMINI.md`, `~/.codex/AGENTS.md`,
  `~/.config/opencode/AGENTS.md`, `~/.agents/AGENTS.md`, `~/.agent/AGENTS.md`,
  `$COPILOT_HOME/copilot-instructions.md` (default `~/.copilot`).
  The home directory comes from `CodingAgent.Config.home_dir/0`.

  Global instructions are rendered first, followed by ancestors from
  the trusted root to cwd. Directory instructions apply to that directory's
  subtree (a config subdirectory such as `.github/` scopes to its parent);
  more specific instructions override broader ones. Each physical file is
  loaded once, including symlink aliases. `@path` imports are expanded by
  `CodingAgent.ResourceLoader.AtImports`: unconfined for global files,
  confined to the trusted root for directory files.

  ## Example

      sections = CodingAgent.ResourceLoader.instruction_sections("/path/to/project")
  """

  alias CodingAgent.Config
  alias LemonCore.TrustedRoot
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

  `cwd` must be the session's trusted directory (`config_cwd`), never a Bot
  folder.

  Options:

    * `:foreign_globals` - also read other coding tools' global instruction
      files (`~/.claude`, `~/.gemini`, `~/.codex`, ...). Default `false`;
      only coding sessions pass `true`.
  """
  @spec instruction_sections(String.t(), keyword()) :: [
          %{category: atom(), label: String.t(), text: String.t()}
        ]
  def instruction_sections(cwd, opts \\ []) do
    root = TrustedRoot.resolve(cwd)
    dirs = TrustedRoot.ancestors(cwd, root)

    dirs
    |> find_instruction_files(root, Keyword.get(opts, :foreign_globals, false) == true)
    |> combined_sections(List.first(dirs) || Path.expand(cwd))
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
    root = TrustedRoot.resolve(cwd)

    # Project prompts must stay inside the trusted root; the user-global
    # prompts directory is home-owned.
    prompt_dirs = [
      {Path.join([cwd, ".lemon", "prompts"]), root},
      {Path.join([cwd, ".claude", "prompts"]), root},
      {Config.prompts_dir(), :unconfined}
    ]

    extensions = [".md", ".txt", ""]

    result =
      Enum.find_value(prompt_dirs, fn {dir, dir_root} ->
        Enum.find_value(extensions, &prompt_file(Path.join(dir, "#{name}#{&1}"), dir_root))
      end)

    case result do
      nil -> {:error, :not_found}
      path -> {:ok, read_file_safe(path)}
    end
  end

  defp prompt_file(path, :unconfined), do: if(File.regular?(path), do: path)

  defp prompt_file(path, root) do
    case TrustedRoot.file(path, root) do
      {:ok, real} -> real
      :error -> nil
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Global sources first, then each directory from the trusted root down to
  # cwd: its root files, then its config subdirectories. Directory files must
  # stay inside the root after symlink resolution. Returns `{path, read_path,
  # import_root}`: global files import unconfined, directory files inside root.
  defp find_instruction_files(dirs, root, foreign_globals?) do
    global =
      Config.home_dir()
      |> global_instruction_sources(foreign_globals?)
      |> candidate_paths()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&{&1, &1, :unconfined})

    local =
      dirs
      |> Enum.reverse()
      |> Enum.flat_map(fn dir ->
        subdirs =
          Enum.map(@subdir_instruction_files, fn {subdir, names} ->
            {Path.join(dir, subdir), names}
          end)

        Enum.map(@root_instruction_files, &Path.join(dir, &1)) ++ candidate_paths(subdirs)
      end)
      |> Enum.flat_map(fn path ->
        case TrustedRoot.file(path, root) do
          {:ok, real} -> [{path, real, root}]
          :error -> []
        end
      end)

    {files, _seen} = deduplicate_files(global ++ local)
    files
  end

  defp candidate_paths(sources) do
    for {dir, names} <- sources, name <- names, do: Path.join(dir, name)
  end

  # Keep the most specific spelling of a physical file, not an earlier global
  # alias that would change its precedence relative to other local guides.
  defp deduplicate_files([]), do: {[], MapSet.new()}

  defp deduplicate_files([{_path, read_path, _root} = file | rest]) do
    {files, seen} = deduplicate_files(rest)
    identity = file_identity(read_path)

    if MapSet.member?(seen, identity) do
      {files, seen}
    else
      {[file | files], MapSet.put(seen, identity)}
    end
  end

  # Global instruction files, broad external tools first and Lemon's own last.
  # Other tools' files are read only for coding sessions.
  defp global_instruction_sources(home, foreign_globals?) do
    foreign =
      if foreign_globals? do
        [
          {Path.join(home, ".claude"), ["CLAUDE.md", "AGENTS.md"]},
          {Path.join(home, ".gemini"), ["GEMINI.md"]},
          {Path.join(home, ".codex"), ["AGENTS.md"]},
          {Path.join([home, ".config", "opencode"]), ["AGENTS.md"]},
          {Path.join(home, ".agents"), ["AGENTS.md"]},
          {Path.join(home, ".agent"), ["AGENTS.md"]},
          {copilot_home(home), ["copilot-instructions.md"]}
        ]
      else
        []
      end

    foreign ++
      [
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

  # Load files and split them into the header plus one labelled section per
  # file; joining the texts with blank lines gives the combined instructions.
  defp combined_sections(files, cwd) do
    home = Config.home_dir()

    global_dirs =
      home |> global_instruction_sources(true) |> Enum.map(&elem(&1, 0))

    files =
      Enum.flat_map(files, fn {path, read_path, import_root} ->
        case read_instruction_file(read_path, home, import_root) do
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
  defp read_instruction_file(path, home, import_root) do
    case read_source(path, import_root) do
      {:ok, content} ->
        content |> AtImports.expand(path, home: home, root: import_root) |> String.trim()

      _ ->
        ""
    end
  end

  # Directory files are read through `TrustedRoot.read/3` (validated realpath,
  # identity re-checked); home-owned globals are read directly.
  defp read_source(path, :unconfined), do: File.read(path)

  defp read_source(path, root) do
    case TrustedRoot.read(path, root) do
      {:ok, content, _real} -> {:ok, content}
      :error -> :error
    end
  end
end
