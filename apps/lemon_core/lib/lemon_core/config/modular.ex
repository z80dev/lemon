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
  - `LemonCore.Config.Memory` - Memory behaviour (`[memory]`)
  - `LemonCore.Config.Automation` - Opt-in proactive automation (daily brief)

  See `LemonCore.Config` for the legacy configuration interface.
  """

  alias LemonCore.Config.{
    Agent,
    Automation,
    Features,
    Gateway,
    LegacyAgentMigration,
    Logging,
    Memory,
    Providers,
    Secrets,
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
    :secrets,
    :features,
    :memory,
    :automation,
    budgets: %{},
    model_roles: %{}
  ]

  @type t :: %__MODULE__{
          agent: Agent.t(),
          tools: Tools.t(),
          gateway: Gateway.t(),
          logging: Logging.t(),
          tui: TUI.t(),
          providers: Providers.t(),
          model_roles: %{optional(String.t()) => String.t()},
          budgets: map(),
          secrets: Secrets.t(),
          features: Features.t(),
          memory: Memory.t(),
          automation: Automation.t()
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

    # Load, map the legacy `[agent]` alias, reject removed settings, and resolve.
    settings = load_merged_settings(project_dir)
    warn_deprecated(settings)
    settings = LegacyAgentMigration.migrate_settings(settings)
    check_deprecated_sections!(settings)
    config = resolve_settings(settings)
    check_model_roles!(config.model_roles)

    case Validator.validate_budgets(config.budgets) do
      :ok -> :ok
      {:error, errors} -> raise ValidationError, message: "Invalid budgets", errors: errors
    end

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
  rescue
    error in ValidationError -> {:error, [Exception.message(error)]}
  end

  @doc """
  Resolve and validate an already-decoded configuration map.

  Comment-preserving editors use this before replacing a TOML file: they can
  validate the exact merged candidate without first making it visible at the
  canonical global or project path. A legacy `[agent]` table is read as its
  canonical sections, exactly as `load/1` does; see `deprecation_warnings/1`.
  """
  @spec validate_settings(map()) :: {:ok, t()} | {:error, [String.t()]}
  def validate_settings(settings) when is_map(settings) do
    settings = LegacyAgentMigration.migrate_settings(settings)

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
  Non-fatal warnings for legacy settings in the merged global and project
  config, such as an `[agent]` table that still loads as an alias.

  ## Options

    * `:project_dir` - Project directory to load config from (default: current directory)
  """
  @spec deprecation_warnings(keyword()) :: [String.t()]
  def deprecation_warnings(opts \\ []) do
    opts
    |> Keyword.get(:project_dir, File.cwd!())
    |> load_merged_settings()
    |> Validator.deprecation_warnings()
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

  Removed settings include `[agents.<id>]`, `[tools.*]` and engine-routing
  configuration, including `[runtime.cli]`. Map a legacy `[agent]` table with
  `LemonCore.Config.LegacyAgentMigration.migrate_settings/1` first.
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

  defp warn_deprecated(settings) do
    case Validator.deprecation_warnings(settings) do
      [] ->
        :ok

      warnings ->
        require Logger
        Enum.each(warnings, &Logger.warning("Lemon config: #{&1}"))
    end
  end

  defp check_model_roles!(roles) do
    case Validator.validate_model_roles(roles) do
      :ok ->
        :ok

      {:error, errors} ->
        raise ValidationError, message: "Invalid model roles", errors: errors
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
      model_roles: Map.get(settings, "model_roles", %{}),
      budgets: resolve_budgets(Map.get(settings, "budgets", %{})),
      secrets: Secrets.resolve(settings),
      features: Features.resolve(settings),
      memory: Memory.resolve(settings),
      automation: Automation.resolve(settings)
    }
  end

  @doc false
  def resolve_budgets(budgets) when is_map(budgets) do
    Map.new(
      [:max_run_tokens, :max_run_cost_usd, :max_session_tokens, :max_session_cost_usd],
      fn key -> {key, Map.get(budgets, Atom.to_string(key), Map.get(budgets, key))} end
    )
  end

  def resolve_budgets(budgets), do: budgets

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

          {:error, {:invalid_toml, reason}} ->
            raise ValidationError,
              message:
                "#{path}: invalid TOML: #{reason}. Run `lemon config validate --verbose` after fixing the syntax.",
              errors: []

          {:error, reason} when is_binary(reason) ->
            raise ValidationError,
              message:
                "#{path}: invalid TOML: #{reason}. Run `lemon config validate --verbose` after fixing the syntax.",
              errors: []
        end

      {:error, :enoent} ->
        # File doesn't exist, return empty
        %{}

      {:error, reason} ->
        raise ValidationError,
          message:
            "#{path}: cannot read configuration: #{:file.format_error(reason)}. Run `lemon config validate --verbose` after checking file permissions.",
          errors: []
    end
  end
end
