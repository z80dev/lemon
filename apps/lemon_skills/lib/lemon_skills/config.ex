defmodule LemonSkills.Config do
  @moduledoc """
  Configuration management for skills.

  Handles:
  - Skills directory paths (global and project)
  - Skill enable/disable state
  - Per-skill configuration

  ## Directory Structure

      ~/.lemon/agent/
      ├── skill/              # Global skills
      │   ├── bun-file-io/
      │   │   └── SKILL.md
      │   └── git-workflow/
      │       └── SKILL.md
      └── skills.json         # Global skill configuration

      <project>/.lemon/
      ├── skill/              # Project-specific skills
      │   └── my-custom-skill/
      │       └── SKILL.md
      └── skills.json         # Project skill configuration

  ## Overrides

  The global agent directory defaults to `~/.lemon/agent` but can be overridden via:
  - `LEMON_AGENT_DIR` environment variable
  - `config :lemon_skills, :agent_dir, "/path"`

  If `:lemon_skills` doesn't specify `:agent_dir`, this module will fall back to
  `config :coding_agent, :agent_dir, ...` so the skill registry and coding agent
  share a single on-disk location by default.
  """

  @skills_config_filename "skills.json"

  @doc """
  Get the global agent directory used for skills/config.

  Returns a path like `~/.lemon/agent` unless overridden.
  """
  @spec agent_dir() :: String.t()
  def agent_dir do
    System.get_env("LEMON_AGENT_DIR") ||
      Application.get_env(:lemon_skills, :agent_dir) ||
      Application.get_env(:coding_agent, :agent_dir) ||
      Path.join(System.user_home!(), ".lemon/agent")
  end

  @doc """
  Get the global skills directory.

  Returns `~/.lemon/agent/skill`.
  """
  @spec global_skills_dir() :: String.t()
  def global_skills_dir do
    Path.join(agent_dir(), "skill")
  end

  @doc """
  Get all global skills directories.

  Directories are returned in precedence order (first wins on key collisions):
  1. Lemon global skills (`~/.lemon/agent/skill` or `LEMON_AGENT_DIR/skill`)
  2. Harness-compatible skills (`~/.agents/skills`)
  """
  @spec global_skills_dirs() :: [String.t()]
  def global_skills_dirs do
    [
      global_skills_dir(),
      Path.join([System.user_home!(), ".agents", "skills"])
    ]
    |> Enum.uniq()
  end

  @doc """
  Get the project skills directory.

  Returns `<cwd>/.lemon/skill`.

  ## Parameters

  - `cwd` - The project working directory
  """
  @spec project_skills_dir(String.t()) :: String.t()
  def project_skills_dir(cwd) do
    Path.join([cwd, ".lemon", "skill"])
  end

  @doc """
  Get all project skills directories including `.agents/skills` paths.

  Discovers skills in `.agents/skills` directories from cwd up to git repo root
  (or filesystem root if not in a git repo), following Pi's package-manager pattern.

  Directories are returned in precedence order (first wins on key collisions):
  1. Project `.lemon/skill` (highest precedence)
  2. `.agents/skills` directories from cwd up to git root

  ## Parameters

  - `cwd` - The project working directory

  ## Examples

      # In a git repo at /home/user/myrepo with cwd at /home/user/myrepo/packages/feature
      # and skills in:
      #   - /home/user/myrepo/packages/.agents/skills/nested-skill
      #   - /home/user/myrepo/.agents/skills/repo-skill
      # Returns: ["/home/user/myrepo/packages/.lemon/skill",
      #           "/home/user/myrepo/packages/.agents/skills",
      #           "/home/user/myrepo/.agents/skills"]

      # Outside a git repo at /home/user/project with cwd at /home/user/project/a/b
      # Returns: ["/home/user/project/a/b/.lemon/skill",
      #           "/home/user/project/a/b/.agents/skills",
      #           "/home/user/project/a/.agents/skills",
      #           "/home/user/project/.agents/skills"]
  """
  @spec project_skills_dirs(String.t()) :: [String.t()]
  def project_skills_dirs(cwd) do
    resolved_cwd = Path.expand(cwd)
    git_root = find_git_root(resolved_cwd)

    # Start with the primary project skills directory
    dirs = [project_skills_dir(cwd)]

    # Collect .agents/skills directories from cwd up to git root or filesystem root
    dirs = dirs ++ collect_ancestor_agents_skill_dirs(resolved_cwd, git_root)

    dirs
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
  end

  # ============================================================================
  # Private Functions - Ancestor Skills Discovery
  # ============================================================================

  # Find the git repository root starting from the given directory.
  # Returns nil if not in a git repository.
  defp find_git_root(start_dir) do
    dir = Path.expand(start_dir)
    find_git_root_recursive(dir)
  end

  defp find_git_root_recursive(dir) do
    git_dir = Path.join(dir, ".git")

    cond do
      File.dir?(git_dir) or File.regular?(git_dir) ->
        dir

      Path.dirname(dir) == dir ->
        nil

      true ->
        find_git_root_recursive(Path.dirname(dir))
    end
  end

  # Collect .agents/skills directories from start_dir up to git_root (or filesystem root).
  # Returns a list of paths in order from closest to farthest from start_dir.
  defp collect_ancestor_agents_skill_dirs(start_dir, git_root) do
    start_dir
    |> collect_ancestors(git_root)
    |> Enum.map(fn dir -> Path.join([dir, ".agents", "skills"]) end)
  end

  # Collect ancestor directories from start_dir up to git_root or filesystem root.
  defp collect_ancestors(start_dir, git_root) do
    collect_ancestors_recursive(Path.expand(start_dir), git_root, [])
  end

  defp collect_ancestors_recursive(dir, git_root, acc) do
    new_acc = [dir | acc]

    cond do
      # Stop if we've reached the git repo root
      git_root && dir == git_root ->
        Enum.reverse(new_acc)

      # Stop if we've reached the filesystem root
      Path.dirname(dir) == dir ->
        Enum.reverse(new_acc)

      # Continue to parent
      true ->
        collect_ancestors_recursive(Path.dirname(dir), git_root, new_acc)
    end
  end

  @doc """
  Get the global skills configuration file path.
  """
  @spec global_config_file() :: String.t()
  def global_config_file do
    Path.join(agent_dir(), @skills_config_filename)
  end

  @doc """
  Get the project skills configuration file path.

  ## Parameters

  - `cwd` - The project working directory
  """
  @spec project_config_file(String.t()) :: String.t()
  def project_config_file(cwd) do
    Path.join([cwd, ".lemon", @skills_config_filename])
  end

  @doc """
  Load the skills configuration.

  Merges global and project configuration, with project taking precedence.

  ## Parameters

  - `cwd` - The project working directory (optional)
  """
  @spec load_config(String.t() | nil) :: map()
  def load_config(cwd \\ nil) do
    global_config = load_config_file(global_config_file())

    if cwd do
      project_config = load_config_file(project_config_file(cwd))
      deep_merge(global_config, project_config)
    else
      global_config
    end
  end

  @doc """
  Save skill configuration.

  ## Parameters

  - `config` - The configuration map to save
  - `global` - Whether to save to global config (default: true)
  - `cwd` - Project directory for project config
  """
  @spec save_config(map(), boolean(), String.t() | nil) :: :ok | {:error, term()}
  def save_config(config, global \\ true, cwd \\ nil) do
    path =
      if global do
        global_config_file()
      else
        project_config_file(cwd)
      end

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(path))

    case Jason.encode(config, pretty: true) do
      {:ok, json} ->
        File.write(path, json)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if a skill is disabled.

  ## Parameters

  - `key` - The skill key
  - `cwd` - Project directory (optional)
  """
  @spec skill_disabled?(String.t(), String.t() | nil) :: boolean()
  def skill_disabled?(key, cwd \\ nil) do
    config = load_config(cwd)
    disabled = get_in(config, ["disabled"]) || []
    key in disabled
  end

  @doc """
  Enable a skill.

  ## Parameters

  - `key` - The skill key to enable

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec enable(String.t(), keyword()) :: :ok | {:error, term()}
  def enable(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    disabled = Map.get(config, "disabled", [])
    disabled = List.delete(disabled, key)

    config = Map.put(config, "disabled", disabled)
    save_config(config, global, cwd)
  end

  @doc """
  Disable a skill.

  ## Parameters

  - `key` - The skill key to disable

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec disable(String.t(), keyword()) :: :ok | {:error, term()}
  def disable(key, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    disabled = Map.get(config, "disabled", [])
    disabled = if key in disabled, do: disabled, else: [key | disabled]

    config = Map.put(config, "disabled", disabled)
    save_config(config, global, cwd)
  end

  @doc """
  Get skill-specific configuration.

  ## Parameters

  - `key` - The skill key
  - `cwd` - Project directory (optional)
  """
  @spec get_skill_config(String.t(), String.t() | nil) :: map()
  def get_skill_config(key, cwd \\ nil) do
    config = load_config(cwd)
    get_in(config, ["skills", key]) || %{}
  end

  @doc """
  Set skill-specific configuration.

  ## Parameters

  - `key` - The skill key
  - `skill_config` - The configuration to set

  ## Options

  - `:cwd` - Project directory (optional)
  - `:global` - Whether to modify global config (default: true)
  """
  @spec set_skill_config(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def set_skill_config(key, skill_config, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)
    global = Keyword.get(opts, :global, true)

    config_path = if global, do: global_config_file(), else: project_config_file(cwd)
    config = load_config_file(config_path)

    skills = Map.get(config, "skills", %{})
    skills = Map.put(skills, key, skill_config)

    config = Map.put(config, "skills", skills)
    save_config(config, global, cwd)
  end

  @doc """
  Ensure skills directories exist.
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    File.mkdir_p!(global_skills_dir())
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp load_config_file(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} when is_map(config) -> config
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn
      _key, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _key, _v1, v2 -> v2
    end)
  end
end
