defmodule CodingAgent.Config do
  @moduledoc """
  Configuration module for the coding agent.

  Handles path resolution, environment configuration, and asset locations.
  This module provides functions to locate configuration directories, session
  storage, extensions, skills, prompts, and context files.

  ## Directory Structure

  The agent uses a hierarchical directory structure:

      ~/.lemon/agent/
      ├── sessions/          # Session storage (encoded by cwd)
      │   └── --path-to-project--/
      ├── extensions/        # Global extensions
      ├── skills/            # Skill definitions
      └── prompts/           # Custom prompts

  Projects can also have local configuration in `.lemon/` directories.
  """

  # ============================================================================
  # Path Resolution
  # ============================================================================

  @doc """
  Get the agent configuration directory.

  Returns the path to `~/.lemon/agent` where global agent configuration is stored.

  ## Examples

      iex> CodingAgent.Config.agent_dir()
      "/home/user/.lemon/agent"
  """
  @spec agent_dir() :: String.t()
  def agent_dir, do: Path.join(System.user_home!(), ".lemon/agent")

  @doc """
  Get the global settings file path.

  Returns the path to the agent settings file under `~/.lemon/agent`.

  ## Examples

      iex> CodingAgent.Config.settings_file()
      "/home/user/.lemon/agent/settings.json"
  """
  @spec settings_file() :: String.t()
  def settings_file, do: Path.join(agent_dir(), "settings.json")

  @doc """
  Get the sessions directory for a working directory.

  Sessions are stored in an encoded directory name based on the working directory
  path to avoid conflicts and allow easy lookup.

  ## Parameters

    * `cwd` - The current working directory path

  ## Examples

      iex> CodingAgent.Config.sessions_dir("/home/user/project")
      "/home/user/.lemon/agent/sessions/--home-user-project--"
  """
  @spec sessions_dir(String.t()) :: String.t()
  def sessions_dir(cwd) do
    encoded = encode_cwd(cwd)
    Path.join([agent_dir(), "sessions", encoded])
  end

  @doc """
  Get the global extensions directory.

  Extensions in this directory are available to all projects.

  ## Examples

      iex> CodingAgent.Config.extensions_dir()
      "/home/user/.lemon/agent/extensions"
  """
  @spec extensions_dir() :: String.t()
  def extensions_dir, do: Path.join(agent_dir(), "extensions")

  @doc """
  Get the skills directory.

  Skills are reusable agent capabilities that can be loaded on demand.

  ## Examples

      iex> CodingAgent.Config.skills_dir()
      "/home/user/.lemon/agent/skills"
  """
  @spec skills_dir() :: String.t()
  def skills_dir, do: Path.join(agent_dir(), "skills")

  @doc """
  Get the prompts directory.

  Custom prompts can be stored here for reuse across sessions.

  ## Examples

      iex> CodingAgent.Config.prompts_dir()
      "/home/user/.lemon/agent/prompts"
  """
  @spec prompts_dir() :: String.t()
  def prompts_dir, do: Path.join(agent_dir(), "prompts")

  @doc """
  Get the global workspace directory for agent identity/memory files.

  Returns the path to `~/.lemon/agent/workspace`.
  """
  @spec workspace_dir() :: String.t()
  def workspace_dir, do: Path.join(agent_dir(), "workspace")

  @doc """
  Get project-local config directory.

  Each project can have its own `.lemon` directory for local configuration.

  ## Parameters

    * `cwd` - The project's root directory

  ## Examples

      iex> CodingAgent.Config.project_config_dir("/home/user/project")
      "/home/user/project/.lemon"
  """
  @spec project_config_dir(String.t()) :: String.t()
  def project_config_dir(cwd), do: Path.join(cwd, ".lemon")

  @doc """
  Get project-local extensions directory.

  Extensions specific to a project can be stored here.

  ## Parameters

    * `cwd` - The project's root directory

  ## Examples

      iex> CodingAgent.Config.project_extensions_dir("/home/user/project")
      "/home/user/project/.lemon/extensions"
  """
  @spec project_extensions_dir(String.t()) :: String.t()
  def project_extensions_dir(cwd), do: Path.join(project_config_dir(cwd), "extensions")

  # ============================================================================
  # Path Encoding
  # ============================================================================

  @doc """
  Encode a cwd path for use as directory name.

  Transforms a file system path into a safe directory name by replacing
  path separators with dashes and wrapping with `--` markers.

  ## Parameters

    * `cwd` - The path to encode

  ## Examples

      iex> CodingAgent.Config.encode_cwd("/home/user/project")
      "--home-user-project--"

      iex> CodingAgent.Config.encode_cwd("/")
      "------"
  """
  @spec encode_cwd(String.t()) :: String.t()
  def encode_cwd(cwd) do
    encoded =
      cwd
      |> String.replace(~r{^[/\\]}, "")
      |> String.replace(~r{[/\\:]+}, "-")

    encoded = if encoded == "", do: "--", else: encoded

    "--#{encoded}--"
  end

  @doc """
  Decode an encoded cwd back to original path.

  Reverses the encoding done by `encode_cwd/1`.

  ## Parameters

    * `encoded` - The encoded directory name

  ## Examples

      iex> CodingAgent.Config.decode_cwd("--home-user-project--")
      "/home/user/project"
  """
  @spec decode_cwd(String.t()) :: String.t()
  def decode_cwd(encoded) do
    inner =
      encoded
      |> String.trim_leading("--")
      |> String.trim_trailing("--")

    case inner do
      "" -> "/"
      "--" -> "/"
      _ -> "/" <> String.replace(inner, "-", "/")
    end
  end

  # ============================================================================
  # Environment
  # ============================================================================

  @doc """
  Get environment variable with fallback.

  ## Parameters

    * `key` - The environment variable name
    * `default` - The default value if not set (defaults to `nil`)

  ## Examples

      iex> CodingAgent.Config.get_env("HOME")
      "/home/user"

      iex> CodingAgent.Config.get_env("NONEXISTENT", "default")
      "default"
  """
  @spec get_env(String.t(), String.t() | nil) :: String.t() | nil
  def get_env(key, default \\ nil), do: System.get_env(key, default)

  @doc """
  Check if running in debug mode.

  Returns `true` if either `PI_DEBUG` or `DEBUG` environment variable is set to `"1"`.

  ## Examples

      iex> System.put_env("PI_DEBUG", "1")
      iex> CodingAgent.Config.debug?()
      true
  """
  @spec debug?() :: boolean()
  def debug?, do: get_env("PI_DEBUG") == "1" or get_env("DEBUG") == "1"

  @doc """
  Get the temp directory for bash output.

  Returns the system's temporary directory path.

  ## Examples

      iex> CodingAgent.Config.temp_dir()
      "/tmp"
  """
  @spec temp_dir() :: String.t()
  def temp_dir, do: System.tmp_dir!()

  # ============================================================================
  # Directory Setup
  # ============================================================================

  @doc """
  Ensure the agent directory structure exists.

  Creates all necessary directories for the agent to function:
  - Agent root directory
  - Sessions directory
  - Extensions directory
  - Skills directory
  - Prompts directory

  ## Examples

      iex> CodingAgent.Config.ensure_dirs!()
      :ok
  """
  @spec ensure_dirs!() :: :ok
  def ensure_dirs! do
    for dir <- [
          agent_dir(),
          sessions_dir("."),
          extensions_dir(),
          skills_dir(),
          prompts_dir(),
          workspace_dir()
        ] do
      File.mkdir_p!(dir)
    end

    :ok
  end

  # ============================================================================
  # Context Files
  # ============================================================================

  @doc """
  Find AGENTS.md or CLAUDE.md files from cwd up to root and global.

  Walks the directory tree from the current working directory up to the
  filesystem root, collecting any `AGENTS.md` or `CLAUDE.md` files found.
  Also checks the global agent directory.

  ## Parameters

    * `cwd` - The starting directory to search from

  ## Returns

  A list of absolute paths to context files that exist, ordered from
  deepest (most specific) to shallowest (most general), with global
  context files at the end.

  ## Examples

      iex> CodingAgent.Config.find_context_files("/home/user/project")
      ["/home/user/project/AGENTS.md", "/home/user/CLAUDE.md", "~/.lemon/agent/AGENTS.md"]
  """
  @spec find_context_files(String.t()) :: [String.t()]
  def find_context_files(cwd) do
    context_filenames = ["AGENTS.md", "CLAUDE.md"]

    # Walk from cwd to root, collecting context files
    local_files =
      cwd
      |> walk_to_root()
      |> Enum.flat_map(fn dir ->
        context_filenames
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.exists?/1)
      end)

    # Check global agent directory
    global_files =
      context_filenames
      |> Enum.map(&Path.join(agent_dir(), &1))
      |> Enum.filter(&File.exists?/1)

    local_files ++ global_files
  end

  # Walk from a directory up to the filesystem root
  @spec walk_to_root(String.t()) :: [String.t()]
  defp walk_to_root(path) do
    abs_path = Path.expand(path)
    do_walk_to_root(abs_path, [])
  end

  defp do_walk_to_root("/", acc), do: Enum.reverse(["/"] ++ acc)

  defp do_walk_to_root(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      # Reached root (handles edge cases)
      Enum.reverse([path] ++ acc)
    else
      do_walk_to_root(parent, [path | acc])
    end
  end
end
