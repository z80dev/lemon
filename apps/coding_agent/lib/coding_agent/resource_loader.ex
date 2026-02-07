defmodule CodingAgent.ResourceLoader do
  @moduledoc """
  Loads resources like CLAUDE.md, AGENTS.md, and prompt files.

  Resources are loaded from:
  - Project directory (cwd) and parent directories up to root
  - Home directory (`~/.claude/`, `~/.lemon/`)
  - Extension paths

  ## Instruction Files

  Instruction files (CLAUDE.md, AGENTS.md) provide context and guidelines
  for the coding agent. They are loaded in order from most specific
  (project-local) to most general (global), allowing for hierarchical
  configuration.

  ## Resource Priorities

  When loading resources, the following priority order is used:
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

  # Standard instruction file names
  @instruction_files ["CLAUDE.md", "AGENTS.md"]

  # Subdirectories to check within each directory
  @config_subdirs [".claude", ".lemon"]

  # ============================================================================
  # Instruction Loading
  # ============================================================================

  @doc """
  Load CLAUDE.md and similar instruction files.

  Searches for instruction files in:
  1. The cwd and its `.claude/` and `.lemon/` subdirectories
  2. All parent directories up to the filesystem root
  3. Home directory locations (`~/.claude/`, `~/.lemon/agent/`)

  Files are returned in order from most specific to most general,
  with their content combined.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A string containing the combined content of all found instruction files,
  with file headers indicating the source of each section.

  ## Examples

      instructions = CodingAgent.ResourceLoader.load_instructions("/home/user/project")
      # Returns combined content with headers like:
      # <!-- From: /home/user/project/CLAUDE.md -->
      # ... file content ...
      # <!-- From: ~/.claude/CLAUDE.md -->
      # ... global content ...
  """
  @spec load_instructions(String.t()) :: String.t()
  def load_instructions(cwd) do
    cwd
    |> find_instruction_files()
    |> load_and_combine_files()
  end

  @doc """
  Load instruction files and return as a list with metadata.

  Similar to `load_instructions/1` but returns structured data
  instead of combined content.

  ## Parameters

    * `cwd` - The current working directory

  ## Returns

  A list of maps with `:path` and `:content` keys.

  ## Examples

      files = CodingAgent.ResourceLoader.load_instructions_list("/home/user/project")
      # => [%{path: "/home/user/project/CLAUDE.md", content: "..."}]
  """
  @spec load_instructions_list(String.t()) :: [%{path: String.t(), content: String.t()}]
  def load_instructions_list(cwd) do
    cwd
    |> find_instruction_files()
    |> Enum.map(fn path ->
      %{path: path, content: read_file_safe(path)}
    end)
    |> Enum.reject(fn %{content: content} -> content == "" end)
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

  A string containing the combined content of all found AGENTS.md files.

  ## Examples

      agents = CodingAgent.ResourceLoader.load_agents("/home/user/project")
  """
  @spec load_agents(String.t()) :: String.t()
  def load_agents(cwd) do
    cwd
    |> find_specific_files(["AGENTS.md"])
    |> load_and_combine_files()
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
    dirs = [
      Path.join([cwd, ".lemon", "skill"]),
      Path.join([Config.agent_dir(), "skill"])
    ]

    dirs
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
      for dir <- [Path.join([cwd, ".lemon", "skill"]), Path.join([Config.agent_dir(), "skill"])],
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
    find_specific_files(cwd, @instruction_files)
  end

  # Find specific files in all search locations
  @spec find_specific_files(String.t(), [String.t()]) :: [String.t()]
  defp find_specific_files(cwd, filenames) do
    local_files = find_in_directory_tree(cwd, filenames)
    home_files = find_in_home_directories(filenames)

    (local_files ++ home_files) |> Enum.uniq()
  end

  # Find files in directory tree from cwd to root
  @spec find_in_directory_tree(String.t(), [String.t()]) :: [String.t()]
  defp find_in_directory_tree(cwd, filenames) do
    cwd
    |> Path.expand()
    |> walk_to_root()
    |> Enum.flat_map(fn dir ->
      find_in_directory(dir, filenames)
    end)
  end

  # Find files in a single directory (including subdirs)
  @spec find_in_directory(String.t(), [String.t()]) :: [String.t()]
  defp find_in_directory(dir, filenames) do
    # Check root of directory
    root_files =
      filenames
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.regular?/1)

    # Check subdirectories
    subdir_files =
      @config_subdirs
      |> Enum.flat_map(fn subdir ->
        subdir_path = Path.join(dir, subdir)

        filenames
        |> Enum.map(&Path.join(subdir_path, &1))
        |> Enum.filter(&File.regular?/1)
      end)

    root_files ++ subdir_files
  end

  # Find files in home directory locations
  @spec find_in_home_directories([String.t()]) :: [String.t()]
  defp find_in_home_directories(filenames) do
    home = System.user_home!()

    home_dirs = [
      Path.join(home, ".claude"),
      Path.join(home, ".lemon"),
      Config.agent_dir()
    ]

    home_dirs
    |> Enum.flat_map(fn dir ->
      filenames
      |> Enum.map(&Path.join(dir, &1))
      |> Enum.filter(&File.regular?/1)
    end)
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

  # Load files and combine their content with headers
  @spec load_and_combine_files([String.t()]) :: String.t()
  defp load_and_combine_files(paths) do
    paths
    |> Enum.map(fn path ->
      content = read_file_safe(path)

      if content != "" do
        "<!-- From: #{path} -->\n#{content}"
      else
        ""
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # Safely read a file, returning empty string on error
  @spec read_file_safe(String.t()) :: String.t()
  defp read_file_safe(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      {:error, _} -> ""
    end
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
