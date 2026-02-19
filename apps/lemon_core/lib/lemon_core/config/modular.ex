defmodule LemonCore.Config.Modular do
  @moduledoc """
  Modular configuration interface for Lemon.

  This module provides a new, modular approach to configuration that delegates
  to specialized sub-modules for specific domains. It can be used alongside
  the existing `LemonCore.Config` module during the transition period.

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
    Gateway,
    Logging,
    Providers,
    Tools,
    TUI
  }

  @global_config_path "~/.lemon/config.toml"

  defstruct [
    :agent,
    :tools,
    :gateway,
    :logging,
    :tui,
    :providers
  ]

  @type t :: %__MODULE__{
          agent: Agent.t(),
          tools: Tools.t(),
          gateway: Gateway.t(),
          logging: Logging.t(),
          tui: TUI.t(),
          providers: Providers.t()
        }

  @doc """
  Loads the full configuration from all sources using the modular approach.

  Merges global config, project config, and environment variables.

  ## Options

    * `:project_dir` - Project directory to load config from (default: current directory)

  ## Examples

      config = LemonCore.Config.Modular.load()
      config = LemonCore.Config.Modular.load(project_dir: "~/my-project")
  """
  @spec load(keyword()) :: t()
  def load(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    # Load and merge configs
    settings = load_merged_settings(project_dir)

    # Resolve each section using modular config modules
    %__MODULE__{
      agent: Agent.resolve(settings),
      tools: Tools.resolve(settings),
      gateway: Gateway.resolve(settings),
      logging: Logging.resolve(settings),
      tui: TUI.resolve(settings),
      providers: Providers.resolve(settings)
    }
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
