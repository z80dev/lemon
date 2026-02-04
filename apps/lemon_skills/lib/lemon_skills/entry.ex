defmodule LemonSkills.Entry do
  @moduledoc """
  Skill entry struct representing a registered skill.

  Contains all metadata about a skill including its manifest,
  source, status, and configuration.

  ## Fields

  - `key` - Unique identifier for the skill (typically the directory name)
  - `name` - Human-readable display name
  - `description` - Brief description of what the skill does
  - `source` - Where the skill was installed from (:global, :project, or URL)
  - `path` - Absolute path to the skill directory
  - `enabled` - Whether the skill is currently enabled
  - `manifest` - Parsed manifest data (see `LemonSkills.Manifest`)
  - `status` - Current status (:ready, :missing_deps, :error, etc.)

  ## Examples

      %LemonSkills.Entry{
        key: "bun-file-io",
        name: "Bun File I/O",
        description: "Patterns for file operations in Bun",
        source: :global,
        path: "/Users/me/.lemon/agent/skill/bun-file-io",
        enabled: true,
        manifest: %{...},
        status: :ready
      }
  """

  @type source :: :global | :project | String.t()
  @type status :: :ready | :missing_deps | :missing_config | :disabled | :error

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          description: String.t(),
          source: source(),
          path: String.t(),
          enabled: boolean(),
          manifest: map() | nil,
          status: status()
        }

  @enforce_keys [:key, :path]
  defstruct [
    :key,
    :name,
    :description,
    :source,
    :path,
    :manifest,
    enabled: true,
    status: :ready
  ]

  @doc """
  Create a new skill entry from a path.

  ## Parameters

  - `path` - Absolute path to the skill directory
  - `opts` - Additional options

  ## Options

  - `:source` - The source type (:global, :project, or URL)
  - `:enabled` - Whether the skill is enabled (default: true)

  ## Examples

      entry = LemonSkills.Entry.new("/path/to/skill", source: :global)
  """
  @spec new(String.t(), keyword()) :: t()
  def new(path, opts \\ []) do
    key = Path.basename(path)
    source = Keyword.get(opts, :source, :global)
    enabled = Keyword.get(opts, :enabled, true)

    %__MODULE__{
      key: key,
      name: key,
      description: "",
      source: source,
      path: path,
      enabled: enabled,
      manifest: nil,
      status: :ready
    }
  end

  @doc """
  Update entry with parsed manifest data.

  ## Parameters

  - `entry` - The skill entry to update
  - `manifest` - Parsed manifest data from `LemonSkills.Manifest`

  ## Examples

      entry = LemonSkills.Entry.with_manifest(entry, manifest)
  """
  @spec with_manifest(t(), map()) :: t()
  def with_manifest(%__MODULE__{} = entry, manifest) when is_map(manifest) do
    %{
      entry
      | name: Map.get(manifest, "name", entry.key),
        description: Map.get(manifest, "description", ""),
        manifest: manifest
    }
  end

  @doc """
  Update entry with status information.

  ## Parameters

  - `entry` - The skill entry to update
  - `status` - The new status

  ## Examples

      entry = LemonSkills.Entry.with_status(entry, :missing_deps)
  """
  @spec with_status(t(), status()) :: t()
  def with_status(%__MODULE__{} = entry, status) do
    %{entry | status: status}
  end

  @doc """
  Check if the skill is ready for use.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec ready?(t()) :: boolean()
  def ready?(%__MODULE__{enabled: false}), do: false
  def ready?(%__MODULE__{status: :ready}), do: true
  def ready?(_), do: false

  @doc """
  Get the skill file path (SKILL.md).

  ## Parameters

  - `entry` - The skill entry
  """
  @spec skill_file(t()) :: String.t()
  def skill_file(%__MODULE__{path: path}) do
    Path.join(path, "SKILL.md")
  end

  @doc """
  Get the content of the skill file.

  ## Parameters

  - `entry` - The skill entry
  """
  @spec content(t()) :: {:ok, String.t()} | {:error, term()}
  def content(%__MODULE__{} = entry) do
    entry
    |> skill_file()
    |> File.read()
  end
end
