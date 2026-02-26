defmodule LemonSkills.Status do
  @moduledoc """
  Status checking for skills.

  Checks if a skill is ready to use by verifying:
  - Required binaries are available (via `which`)
  - Required configuration/environment variables are set
  - The skill is enabled

  ## Status Results

  The status check returns a map with:
  - `ready` - Boolean indicating if skill is ready
  - `missing_bins` - List of missing required binaries
  - `missing_config` - List of missing configuration keys
  - `disabled` - Boolean if skill is disabled
  - `error` - Error message if check failed
  """

  alias LemonSkills.{Registry, Entry, Manifest, Config}

  @type status_result :: %{
          ready: boolean(),
          missing_bins: [String.t()],
          missing_config: [String.t()],
          disabled: boolean(),
          error: String.t() | nil
        }

  @doc """
  Check the status of a skill by key.

  ## Parameters

  - `key` - The skill key/identifier

  ## Options

  - `:cwd` - Project working directory (optional)

  ## Returns

  A status result map.

  ## Examples

      %{ready: true} = LemonSkills.Status.check("simple-skill")
      %{ready: false, missing_bins: ["kubectl"]} = LemonSkills.Status.check("k8s-skill")
  """
  @spec check(String.t(), keyword()) :: status_result()
  def check(key, opts \\ []) do
    case Registry.get(key, opts) do
      {:ok, entry} ->
        check_entry(entry, opts)

      :error ->
        %{
          ready: false,
          missing_bins: [],
          missing_config: [],
          disabled: false,
          error: "Skill not found: #{key}"
        }
    end
  end

  @doc """
  Check the status of a skill entry directly.

  ## Parameters

  - `entry` - The skill entry to check

  ## Options

  - `:cwd` - Project working directory (optional)
  """
  @spec check_entry(Entry.t(), keyword()) :: status_result()
  def check_entry(%Entry{} = entry, opts \\ []) do
    cwd = Keyword.get(opts, :cwd)

    # Check if disabled
    disabled = not entry.enabled or Config.skill_disabled?(entry.key, cwd)

    if disabled do
      %{
        ready: false,
        missing_bins: [],
        missing_config: [],
        disabled: true,
        error: nil
      }
    else
      check_requirements(entry)
    end
  end

  @doc """
  Check if a binary is available on the system.

  ## Parameters

  - `binary` - The binary name to check
  """
  @spec binary_available?(String.t()) :: boolean()
  def binary_available?(binary) when is_binary(binary) do
    case System.find_executable(binary) do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Check if a configuration key is set.

  Checks environment variables.

  ## Parameters

  - `key` - The configuration key to check
  """
  @spec config_available?(String.t()) :: boolean()
  def config_available?(key) when is_binary(key) do
    case System.get_env(key) do
      nil -> false
      "" -> false
      _value -> true
    end
  end

  @doc """
  Get all missing binaries for a skill.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec missing_binaries(Entry.t()) :: [String.t()]
  def missing_binaries(%Entry{manifest: nil}), do: []

  def missing_binaries(%Entry{manifest: manifest}) do
    manifest
    |> Manifest.required_bins()
    |> Enum.reject(&binary_available?/1)
  end

  @doc """
  Get all missing configuration for a skill.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec missing_config(Entry.t()) :: [String.t()]
  def missing_config(%Entry{manifest: nil}), do: []

  def missing_config(%Entry{manifest: manifest}) do
    manifest
    |> Manifest.required_config()
    |> Enum.reject(&config_available?/1)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp check_requirements(%Entry{} = entry) do
    missing_bins = missing_binaries(entry)
    missing_cfg = missing_config(entry)

    ready = Enum.empty?(missing_bins) and Enum.empty?(missing_cfg)

    %{
      ready: ready,
      missing_bins: missing_bins,
      missing_config: missing_cfg,
      disabled: false,
      error: nil
    }
  end
end
