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
  4. Default values (lowest priority)

  ## Example Usage

      # Load full configuration using modular approach
      config = LemonCore.Config.Modular.load()

      # Access specific sections
      config.agent.default_model
      config.gateway.enable_telegram
      config.providers.providers["anthropic"].api_key

  ## Sub-modules

  - `LemonCore.Config.Agent` - Agent behavior settings
  - `LemonCore.Config.Tools` - Web tools and WASM configuration
  - `LemonCore.Config.Gateway` - Telegram, SMS, and engine bindings
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

  @global_config_path "~/.lemon/config.toml"

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

    # Load, check deprecated sections (hard-fail), and resolve
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

    # Check deprecated sections via tuple-returning variant instead of raising
    deprecated_errors =
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

    case deprecated_errors ++ validation_errors do
      [] -> {:ok, config}
      errors -> {:error, errors}
    end
  end

  @doc """
  Returns the path to the global config file.
  """
  @spec global_path() :: String.t()
  def global_path do
    case System.get_env("HOME") do
      nil -> Path.expand(@global_config_path)
      home -> Path.join([home, ".lemon", "config.toml"])
    end
  end

  @doc """
  Returns the path to the project config file for the given directory.
  """
  @spec project_path(String.t()) :: String.t()
  def project_path(dir) do
    Path.join([dir, ".lemon", "config.toml"])
  end

  @doc """
  Checks for deprecated TOML sections and raises ValidationError if found.

  Deprecated sections:
  - `[agent]` - use `[defaults]` and `[runtime]` instead
  - `[agents]` - use `[profiles.<id>]` instead
  - `[agent.tools]` - use `[runtime.tools.*]` instead
  - `[tools]` - use `[runtime.tools.*]` instead
  """
  @spec check_deprecated_sections!(map()) :: :ok
  def check_deprecated_sections!(settings) when is_map(settings) do
    errors = collect_deprecated_errors(settings)

    case errors do
      [] -> :ok
      _ -> raise ValidationError, message: "Configuration uses deprecated sections", errors: errors
    end
  end

  defp collect_deprecated_errors(settings) do
    errors = []

    errors =
      if is_map(settings["agent"]) do
        ["[agent] is deprecated. Move fields to [defaults] (provider, model, thinking_level) and [runtime] (other settings)." | errors]
      else
        errors
      end

    errors =
      if is_map(settings["agents"]) do
        ["[agents.<id>] is deprecated. Use [profiles.<id>] instead." | errors]
      else
        errors
      end

    errors =
      if is_map(settings["agent"]) and is_map(settings["agent"]["tools"]) do
        ["[agent.tools.*] is deprecated. Use [runtime.tools.*] instead." | errors]
      else
        errors
      end

    errors =
      if is_map(settings["tools"]) do
        ["[tools.*] is deprecated. Use [runtime.tools.*] instead." | errors]
      else
        errors
      end

    Enum.reverse(errors)
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
    deep_merge(global_settings, project_settings)
  end

  defp load_toml_file(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, settings} -> settings
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

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      deep_merge(base_val, override_val)
    end)
  end

  defp deep_merge(_base, override), do: override
end
