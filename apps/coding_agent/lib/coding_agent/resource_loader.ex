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
  An assistant home is never a project (`LemonCore.TrustedRoot.project_root/1`):
  a session there reads only global instruction files and prompts.

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
  loaded once, including symlink and hard-link aliases. `@path` imports are
  expanded by `CodingAgent.ResourceLoader.AtImports`: unconfined for global
  files, confined to the trusted root for directory files. An import never
  re-inlines another loaded instruction file, a file an earlier instruction
  file already imported, or an `:exclude`d file.

  ## Limits

  Instruction files are read through `CodingAgent.ResourceLoader.SourceReader`
  (bounded, and cached per session by file stat). Each file contributes at
  most 64 KiB of its own text and all instruction sections together at most
  256 KiB: the per-file and total limits `AtImports` applies to imports and
  `CodingAgent.Commands` to command files. The system prompt cannot be
  compacted, so a generated or oversized guide must not crowd out the
  conversation. Text beyond a limit is replaced by a marker naming the file so
  the model can `read` the rest; a truncated read is logged.

  ## Example

      sections = CodingAgent.ResourceLoader.instruction_sections("/path/to/project")
  """

  alias CodingAgent.Config
  alias CodingAgent.ResourceLoader.{AtImports, SourceReader}
  alias LemonCore.TrustedRoot

  @max_instruction_file_bytes 64 * 1024
  @max_instruction_total_bytes 256 * 1024

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
    * `:exclude` - paths of files owned by another prompt source (the
      assistant-home bootstrap files, see `CodingAgent.Workspace`). They are
      neither loaded as instruction files nor importable, so that source's
      gating stays authoritative when cwd is the assistant home.
  """
  @spec instruction_sections(String.t(), keyword()) :: [
          %{category: atom(), label: String.t(), text: String.t()}
        ]
  def instruction_sections(cwd, opts \\ []) do
    SourceReader.span(:instructions, fn ->
      {root, dirs} =
        case TrustedRoot.project(cwd) do
          :none -> {nil, []}
          project -> project
        end

      excluded = opts |> Keyword.get(:exclude, []) |> MapSet.new(&AtImports.identity/1)

      dirs
      |> find_instruction_files(
        root,
        Keyword.get(opts, :foreign_globals, false) == true,
        excluded
      )
      |> combined_sections(List.first(dirs) || Path.expand(cwd), excluded)
    end)
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
    # Project prompts must stay inside the trusted root; the user-global
    # prompts directory is home-owned. An assistant home has no project prompts.
    project_dirs =
      case TrustedRoot.project_root(cwd) do
        {:ok, root} ->
          [
            {Path.join([cwd, ".lemon", "prompts"]), root},
            {Path.join([cwd, ".claude", "prompts"]), root}
          ]

        :none ->
          []
      end

    prompt_dirs = project_dirs ++ [{Config.prompts_dir(), :unconfined}]

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
  defp find_instruction_files(dirs, root, foreign_globals?, excluded) do
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

    {files, _seen} = deduplicate_files(global ++ local, excluded)
    files
  end

  defp candidate_paths(sources) do
    for {dir, names} <- sources, name <- names, do: Path.join(dir, name)
  end

  # Keep the most specific spelling of a physical file, not an earlier global
  # alias that would change its precedence relative to other local guides.
  # Files whose identity is in `excluded` are dropped.
  defp deduplicate_files([], excluded), do: {[], excluded}

  defp deduplicate_files([{_path, read_path, _root} = file | rest], excluded) do
    {files, seen} = deduplicate_files(rest, excluded)
    identity = AtImports.identity(read_path)

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
  # The import skip set starts with every loaded and excluded file and grows
  # with each file's imports, so no physical file is inlined twice.
  defp combined_sections(files, cwd, excluded) do
    home = Config.home_dir()

    global_dirs =
      home |> global_instruction_sources(true) |> Enum.map(&elem(&1, 0))

    skip =
      Enum.reduce(files, excluded, fn {_path, read_path, _root}, acc ->
        MapSet.put(acc, AtImports.identity(read_path))
      end)

    {files, _acc} =
      Enum.flat_map_reduce(files, {skip, @max_instruction_total_bytes}, fn
        {path, read_path, import_root}, {skip, remaining} ->
          case read_instruction_file(read_path, home, import_root, skip) do
            {"", skip} ->
              {[], {skip, remaining}}

            {content, skip} ->
              {content, remaining} = within_budget(content, path, remaining)

              {[
                 %{
                   category: :context_files,
                   label: "#{Path.basename(path)} (#{scope_label(path, global_dirs, cwd)})",
                   text:
                     "<!-- From: #{path} -->\nScope: #{instruction_scope(path, global_dirs)}\n\n#{content}"
                 }
               ], {skip, remaining}}
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

  # Read an instruction file (at most the per-file limit of its own text) with
  # its `@path` imports expanded.
  defp read_instruction_file(path, home, import_root, skip) do
    case SourceReader.read(path, import_root, max_bytes: @max_instruction_file_bytes) do
      {:ok, %{content: content, truncated: truncated}} ->
        {text, skip} = AtImports.expand(content, path, home: home, root: import_root, skip: skip)
        text = String.trim(text)

        text =
          if truncated,
            do:
              text <>
                "\n\n[... #{path} truncated at #{div(@max_instruction_file_bytes, 1024)} KiB; " <>
                "read the file for the rest]",
            else: text

        {text, skip}

      :error ->
        {"", skip}
    end
  end

  # All instruction sections share one byte budget; a file past it is cut (or
  # replaced) by a marker naming it, so the model can still read it.
  defp within_budget(content, _path, remaining) when byte_size(content) <= remaining,
    do: {content, remaining - byte_size(content)}

  defp within_budget(content, path, remaining) do
    kept = SourceReader.truncate_utf8(content, remaining)

    marker =
      "[... #{path} " <>
        if(kept == "", do: "not loaded", else: "truncated") <>
        ": the #{div(@max_instruction_total_bytes, 1024)} KiB instruction budget is " <>
        "exhausted; read the file for the rest]"

    {if(kept == "", do: marker, else: kept <> "\n\n" <> marker), 0}
  end
end
