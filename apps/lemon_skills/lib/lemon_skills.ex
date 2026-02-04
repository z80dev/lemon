defmodule LemonSkills do
  @moduledoc """
  LemonSkills - Skill registry, installation, and status management.

  This library provides a centralized skill management system with:
  - Skill registry with GenServer-based caching
  - Manifest parsing (with/without frontmatter)
  - Status checking for missing binaries/configuration
  - Installation and update with approval integration
  - Configuration management

  ## Quick Start

      # List all available skills
      skills = LemonSkills.list()

      # Get a specific skill
      {:ok, skill} = LemonSkills.get("my-skill")

      # Check skill status
      status = LemonSkills.status("my-skill")

      # Install a skill
      {:ok, entry} = LemonSkills.install("https://github.com/user/skill-repo")

  ## Architecture

  The skills system is built on these core components:

  - `LemonSkills.Registry` - GenServer for skill caching and lookup
  - `LemonSkills.Entry` - Skill entry struct with metadata
  - `LemonSkills.Manifest` - Manifest parsing and validation
  - `LemonSkills.Status` - Status checking and gating
  - `LemonSkills.Installer` - Installation and update management
  - `LemonSkills.Config` - Configuration paths and settings
  """

  alias LemonSkills.{Registry, Entry, Status, Installer, Config}

  # ============================================================================
  # Registry Operations
  # ============================================================================

  @doc """
  List all available skills.

  Returns a list of skill entries from both global and project directories.

  ## Options

  - `:cwd` - Project working directory (optional, defaults to current directory)
  - `:refresh` - Force refresh from disk (default: false)

  ## Examples

      skills = LemonSkills.list()
      skills = LemonSkills.list(cwd: "/path/to/project")
  """
  @spec list(keyword()) :: [Entry.t()]
  defdelegate list(opts \\ []), to: Registry

  @doc """
  Get a skill by key.

  ## Parameters

  - `key` - The skill key/identifier

  ## Options

  - `:cwd` - Project working directory (optional)

  ## Examples

      {:ok, skill} = LemonSkills.get("bun-file-io")
      :error = LemonSkills.get("non-existent")
  """
  @spec get(String.t(), keyword()) :: {:ok, Entry.t()} | :error
  defdelegate get(key, opts \\ []), to: Registry

  @doc """
  Refresh the skill registry.

  Forces a reload of all skills from disk.

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec refresh(keyword()) :: :ok
  defdelegate refresh(opts \\ []), to: Registry

  # ============================================================================
  # Status Operations
  # ============================================================================

  @doc """
  Check the status of a skill.

  Returns a status map indicating if the skill is ready to use,
  or what's missing (binaries, configuration, etc.).

  ## Parameters

  - `key` - The skill key/identifier

  ## Options

  - `:cwd` - Project working directory (optional)

  ## Examples

      %{ready: true} = LemonSkills.status("simple-skill")
      %{ready: false, missing_bins: ["kubectl"]} = LemonSkills.status("k8s-skill")
  """
  @spec status(String.t(), keyword()) :: Status.status_result()
  defdelegate status(key, opts \\ []), to: Status, as: :check

  # ============================================================================
  # Installation Operations
  # ============================================================================

  @doc """
  Install a skill from a source.

  Supports installing from:
  - Git repositories (https://github.com/...)
  - Local paths
  - Skill registries

  ## Parameters

  - `source` - The source URL or path

  ## Options

  - `:cwd` - Project working directory for local installation
  - `:global` - Install globally (default: true)
  - `:approve` - Pre-approve installation (default: false)

  ## Examples

      {:ok, entry} = LemonSkills.install("https://github.com/user/skill")
      {:ok, entry} = LemonSkills.install("/local/path/to/skill", global: false)
  """
  @spec install(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  defdelegate install(source, opts \\ []), to: Installer

  @doc """
  Update an installed skill.

  ## Parameters

  - `key` - The skill key to update

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec update(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  defdelegate update(key, opts \\ []), to: Installer

  @doc """
  Uninstall a skill.

  ## Parameters

  - `key` - The skill key to uninstall

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec uninstall(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate uninstall(key, opts \\ []), to: Installer

  # ============================================================================
  # Configuration Operations
  # ============================================================================

  @doc """
  Get the global skills directory.
  """
  @spec global_skills_dir() :: String.t()
  defdelegate global_skills_dir(), to: Config

  @doc """
  Get the project skills directory.

  ## Parameters

  - `cwd` - The project working directory
  """
  @spec project_skills_dir(String.t()) :: String.t()
  defdelegate project_skills_dir(cwd), to: Config

  @doc """
  Enable a skill.

  ## Parameters

  - `key` - The skill key to enable

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec enable(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate enable(key, opts \\ []), to: Config

  @doc """
  Disable a skill.

  ## Parameters

  - `key` - The skill key to disable

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec disable(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate disable(key, opts \\ []), to: Config
end
