defmodule LemonCore.Config.Modular do
  @moduledoc """
  Modular configuration interface for Lemon.

  This module is the canonical runtime configuration loader for Lemon.
  It delegates to specialized sub-modules for each config domain and is the
  source of truth behind `LemonCore.Config`.

  ## Configuration Priority

  Configuration values are resolved in the following priority:

  1. Environment variables (highest priority)
  2. Project config (`.lemon/config.toml`)
  3. Global config (`~/.lemon/config.toml`)

  Both config locations are configurable; see `LemonCore.Paths`.
  4. Default values (lowest priority)

  ## Example Usage

      # Load full configuration using modular approach
      config = LemonCore.Config.Modular.load()

      # Access specific sections
      config.agent.default_model
      config.gateway.max_concurrent_runs
      config.providers.providers["anthropic"].api_key

  ## Sub-modules

  - `LemonCore.Config.Agent` - Agent behavior settings
  - `LemonCore.Config.Tools` - Web tools and WASM configuration
  - `LemonCore.Config.Gateway` - Engine bindings, queueing, channel sections
  - `LemonCore.Config.Logging` - Log file and rotation settings
  - `LemonCore.Config.TUI` - Terminal UI theme and debug
  - `LemonCore.Config.Providers` - LLM provider configurations

  See `LemonCore.Config` for the legacy configuration interface.
  """

  alias LemonCore.Config.{
    Agent,
    Features,
    Gateway,
    Logging,
    Providers,
    Tools,
    TUI,
    ValidationError,
    Validator
  }

  defstruct [
    :agent,
    :tools,
    :gateway,
    :logging,
    :tui,
    :providers,
    :features
  ]

  @type t :: %__MODULE__{
          agent: Agent.t(),
          tools: Tools.t(),
          gateway: Gateway.t(),
          logging: Logging.t(),
          tui: TUI.t(),
          providers: Providers.t(),
          features: Features.t()
        }

  @doc """
  Loads the full configuration from all sources using the modular approach.

  Merges global config, project config, and environment variables.

  ## Options

    * `:project_dir` - Project directory to load config from (default: current directory)
    * `:validate` - Whether to validate the config (default: false)

  ## Examples

      config = LemonCore.Config.Modular.load()
      config = LemonCore.Config.Modular.load(project_dir: "~/my-project")
      config = LemonCore.Config.Modular.load(validate: true)
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    validate? = Keyword.get(opts, :validate, false)

    # Load, reject removed settings, and resolve.
    settings = load_merged_settings(project_dir)
    check_deprecated_sections!(settings)
    config = resolve_settings(settings)

    # Validate if requested
    if validate? do
      case Validator.validate(config) do
        :ok ->
          config

        {:error, errors} ->
          require Logger

          Logger.warning("""
          Configuration validation failed:
          #{Enum.map_join(errors, "\n", &"  - #{&1}")}
          """)

          config
      end
    else
      config
    end
  end

  @doc """
  Loads and validates configuration, raising on validation errors.

  ## Options

    * `:project_dir` - Project directory to load config from (default: current directory)

  ## Examples

      config = LemonCore.Config.Modular.load!()

  ## Raises

    * `LemonCore.Config.ValidationError` - If configuration is invalid
  """
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    config = load(opts)

    case Validator.validate(config) do
      :ok ->
        config

      {:error, errors} ->
        raise LemonCore.Config.ValidationError,
          message: "Configuration validation failed",
          errors: errors
    end
  end

  @doc """
  Loads configuration with validation, returning ok/error tuple.

  ## Options

    * `:project_dir` - Project directory to load config from (default: current directory)

  ## Examples

      case LemonCore.Config.Modular.load_with_validation() do
        {:ok, config} -> use_config(config)
        {:error, errors} -> handle_errors(errors)
      end
  """
  @spec load_with_validation(keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def load_with_validation(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    settings = load_merged_settings(project_dir)

    validate_settings(settings)
  end

  @doc """
  Resolve and validate an already-decoded configuration map.

  Comment-preserving editors use this before replacing a TOML file: they can
  validate the exact merged candidate without first making it visible at the
  canonical global or project path.
  """
  @spec validate_settings(map()) :: {:ok, t()} | {:error, [String.t()]}
  def validate_settings(settings) when is_map(settings) do
    # Return removed-setting errors alongside resolved-config validation errors.
    removed_setting_errors =
      case Validator.validate_deprecated_sections(settings) do
        :ok -> []
        {:error, errs} -> errs
      end

    config = resolve_settings(settings)

    validation_errors =
      case Validator.validate(config) do
        :ok -> []
        {:error, errs} -> errs
      end

    case removed_setting_errors ++ validation_errors do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  @doc """
  Returns the path to the global config file.
  """
  @spec global_path() :: String.t()
  def global_path, do: LemonCore.Paths.global_config()

  @doc """
  Returns the path to the project config file for the given directory.
  """
  @spec project_path(String.t()) :: String.t()
  def project_path(dir), do: LemonCore.Paths.project_config(dir)

  @doc """
  Checks for removed TOML sections and engine-routing settings, raising
  `ValidationError` when found.

  Removed settings include legacy agent/tool sections and engine-routing
  configuration, including `[runtime.cli]`.
  """
  @spec check_deprecated_sections!(map()) :: :ok
  def check_deprecated_sections!(settings) when is_map(settings) do
    case Validator.validate_deprecated_sections(settings) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ValidationError, message: "Configuration uses removed settings", errors: errors
    end
  end

  # Normalizes settings and resolves each section into the modular config struct.
  defp resolve_settings(settings) do
    settings = normalize_tools_settings(settings)

    %__MODULE__{
      agent: Agent.resolve(settings),
      tools: Tools.resolve(settings),
      gateway: Gateway.resolve(settings),
      logging: Logging.resolve(settings),
      tui: TUI.resolve(settings),
      providers: Providers.resolve(settings),
      features: Features.resolve(settings)
    }
  end

  # Normalizes canonical `runtime.tools` into the internal top-level `tools`
  # shape consumed by the modular Tools resolver.
  defp normalize_tools_settings(settings) do
    runtime = settings["runtime"] || %{}
    runtime_tools = runtime["tools"]

    cond do
      is_map(runtime_tools) ->
        settings
        |> Map.put("tools", runtime_tools)
        |> Map.update("runtime", %{}, &Map.delete(&1, "tools"))

      true ->
        settings
    end
  end

  # Private functions

  defp load_merged_settings(project_dir) do
    global_settings = load_toml_file(global_path())
    project_settings = load_toml_file(project_path(project_dir))

    # Merge: project overrides global
    LemonCore.MapHelpers.deep_merge(global_settings, project_settings)
  end

  defp load_toml_file(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, settings} ->
            settings

          {:error, reason} ->
            require Logger
            Logger.warning("Failed to parse config file #{path}: #{inspect(reason)}")
            %{}
        end

      {:error, :enoent} ->
        # File doesn't exist, return empty
        %{}

      {:error, reason} ->
        require Logger
        Logger.warning("Failed to read config file #{path}: #{inspect(reason)}")
        %{}
    end
  end
end
