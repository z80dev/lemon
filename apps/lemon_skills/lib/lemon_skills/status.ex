defmodule LemonSkills.Status do
  @moduledoc """
  Status checking for skills.

  Checks if a skill is ready to use by verifying:
  - Required binaries are available (via `which`)
  - Required configuration/environment variables are set
  - Required tools are installed (`requires_tools` v2 field)
  - The skill is enabled and not administratively disabled
  - The current platform is supported (`platforms` v2 field)

  ## Activation states

  Each entry resolves to one of:

  - `:active` — ready to use; all requirements met
  - `:not_ready` — enabled and platform-compatible but one or more deps missing
  - `:hidden` — disabled via `enabled: false` or per-skill config
  - `:platform_incompatible` — the `platforms` field excludes the current OS
  - `:blocked` — audit verdict blocks use (set by M4-02 audit engine)

  ## Status result

  `check_entry/2` returns a map with:

  - `activation_state` — one of the atoms above
  - `ready` — shorthand boolean (`activation_state == :active`)
  - `platform_compatible` — whether the current OS matches `platforms`
  - `missing_bins` — binaries declared in `requires.bins` that are missing
  - `missing_config` — legacy `requires.config` keys missing from env
  - `missing_env_vars` — v2 `required_environment_variables` missing from env
  - `missing_tools` — v2 `requires_tools` binaries not found on PATH
  - `disabled` — true when activation_state is :hidden
  - `error` — error string (only for skill-not-found results from `check/2`)
  """

  alias LemonSkills.{Config, Entry, Manifest, Registry}

  @type activation_state :: :active | :not_ready | :hidden | :platform_incompatible | :blocked

  @type status_result :: %{
          activation_state: activation_state(),
          ready: boolean(),
          platform_compatible: boolean(),
          missing_bins: [String.t()],
          missing_config: [String.t()],
          missing_env_vars: [String.t()],
          missing_tools: [String.t()],
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

      %{activation_state: :active} = LemonSkills.Status.check("simple-skill")
      %{activation_state: :not_ready, missing_bins: ["kubectl"]} = LemonSkills.Status.check("k8s-skill")
  """
  @spec check(String.t(), keyword()) :: status_result()
  def check(key, opts \\ []) do
    case Registry.get(key, opts) do
      {:ok, entry} ->
        check_entry(entry, opts)

      :error ->
        %{
          activation_state: :not_ready,
          ready: false,
          platform_compatible: true,
          missing_bins: [],
          missing_config: [],
          missing_env_vars: [],
          missing_tools: [],
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
    disabled = not entry.enabled or Config.skill_disabled?(entry.key, cwd)

    if disabled do
      %{
        activation_state: :hidden,
        ready: false,
        platform_compatible: true,
        missing_bins: [],
        missing_config: [],
        missing_env_vars: [],
        missing_tools: [],
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
  Return `true` when the current OS is listed in the manifest's `platforms` field.

  Always returns `true` when `platforms` is absent or contains `"any"`.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec platform_compatible?(Entry.t()) :: boolean()
  def platform_compatible?(%Entry{manifest: nil}), do: true

  def platform_compatible?(%Entry{manifest: manifest}) do
    platforms = Manifest.platforms(manifest)
    platform = current_platform()
    "any" in platforms or platform in platforms
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

  @doc """
  Get all missing environment variables for a skill (v2 `required_environment_variables`).

  Falls back to `required_config/1` for legacy manifests that use `requires.config`.
  Returns `[]` for entries with no manifest.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec missing_env_vars(Entry.t()) :: [String.t()]
  def missing_env_vars(%Entry{manifest: nil}), do: []

  def missing_env_vars(%Entry{manifest: manifest}) do
    manifest
    |> Manifest.required_environment_variables()
    |> Enum.reject(&config_available?/1)
  end

  @doc """
  Get all missing tools for a skill (v2 `requires_tools` field).

  `requires_tools` is a list of tool binary names that must be present on PATH.
  Returns `[]` for entries with no manifest.

  ## Parameters

  - `entry` - The skill entry to check
  """
  @spec missing_tools(Entry.t()) :: [String.t()]
  def missing_tools(%Entry{manifest: nil}), do: []

  def missing_tools(%Entry{manifest: manifest}) do
    manifest
    |> Manifest.requires_tools()
    |> Enum.reject(&binary_available?/1)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp check_requirements(%Entry{} = entry) do
    platform_ok = platform_compatible?(entry)
    missing_bins = missing_binaries(entry)
    missing_cfg = missing_config(entry)
    # Use v2 env vars when present; falls back to requires.config via Manifest accessor
    missing_env = missing_env_vars(entry)
    missing_t = missing_tools(entry)

    # Deduplicate: missing_env may overlap missing_cfg for legacy manifests.
    # Keep both lists so callers can see exactly which field was missing.
    any_missing = missing_bins != [] or missing_cfg != [] or missing_env != [] or missing_t != []

    activation_state =
      cond do
        not platform_ok -> :platform_incompatible
        entry.audit_status == :block -> :blocked
        any_missing -> :not_ready
        true -> :active
      end

    %{
      activation_state: activation_state,
      ready: activation_state == :active,
      platform_compatible: platform_ok,
      missing_bins: missing_bins,
      missing_config: missing_cfg,
      missing_env_vars: missing_env,
      missing_tools: missing_t,
      disabled: false,
      error: nil
    }
  end

  defp current_platform do
    case :os.type() do
      {:win32, _} -> "win32"
      {:unix, :darwin} -> "darwin"
      {:unix, _} -> "linux"
    end
  end
end
