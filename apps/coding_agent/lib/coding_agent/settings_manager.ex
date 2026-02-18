defmodule CodingAgent.SettingsManager do
  @moduledoc """
  Settings adapter for the coding agent.

  Loads canonical TOML configuration via `LemonCore.Config` and exposes
  a struct that existing coding agent components can consume.
  """

  alias LemonCore.Config, as: LemonConfig

  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

  @type model_config :: %{
          provider: String.t() | nil,
          model_id: String.t(),
          base_url: String.t() | nil
        }

  @type t :: %__MODULE__{
          # Model settings
          default_model: model_config() | nil,
          default_thinking_level: thinking_level(),

          # Provider settings
          providers: %{
            optional(String.t()) => %{
              optional(:api_key) => String.t() | nil,
              optional(:base_url) => String.t() | nil,
              optional(:api_key_secret) => String.t() | nil
            }
          },

          # Compaction settings
          compaction_enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer(),

          # Retry settings
          retry_enabled: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),

          # Shell settings
          shell_path: String.t() | nil,
          command_prefix: String.t() | nil,

          # Tool settings
          auto_resize_images: boolean(),
          tools: map(),

          # Extension settings
          extension_paths: [String.t()],

          # Display settings
          theme: String.t(),

          # CLI settings
          codex: map(),
          kimi: map(),
          claude: map(),
          opencode: map(),
          pi: map()
        }

  defstruct [
    # Model settings
    default_model: nil,
    default_thinking_level: :medium,

    # Provider settings
    providers: %{},

    # Compaction settings
    compaction_enabled: true,
    reserve_tokens: 16_384,
    keep_recent_tokens: 20_000,

    # Retry settings
    retry_enabled: true,
    max_retries: 3,
    base_delay_ms: 1000,

    # Shell settings
    shell_path: nil,
    command_prefix: nil,

    # Tool settings
    auto_resize_images: true,
    tools: %{},

    # Extension settings
    extension_paths: [],

    # Display settings
    theme: "default",

    # CLI settings
    codex: %{},
    kimi: %{},
    claude: %{},
    opencode: %{},
    pi: %{}
  ]

  @doc """
  Load settings for a project directory.
  """
  @spec load(String.t()) :: t()
  def load(cwd) do
    cwd
    |> LemonConfig.load()
    |> from_config()
  end

  @doc """
  Convert a LemonCore.Config struct to SettingsManager struct.
  """
  @spec from_config(LemonConfig.t()) :: t()
  def from_config(%LemonConfig{} = config) do
    agent = config.agent || %{}
    provider = Map.get(agent, :default_provider)
    model = Map.get(agent, :default_model)

    default_model = parse_model_spec(provider, model)

    compaction = Map.get(agent, :compaction, %{})
    retry = Map.get(agent, :retry, %{})
    shell = Map.get(agent, :shell, %{})
    tools = Map.get(agent, :tools, %{})
    cli = Map.get(agent, :cli, %{})

    %__MODULE__{
      default_model: default_model,
      default_thinking_level: Map.get(agent, :default_thinking_level, :medium),
      providers: config.providers || %{},
      compaction_enabled: Map.get(compaction, :enabled, true),
      reserve_tokens: Map.get(compaction, :reserve_tokens, 16_384),
      keep_recent_tokens: Map.get(compaction, :keep_recent_tokens, 20_000),
      retry_enabled: Map.get(retry, :enabled, true),
      max_retries: Map.get(retry, :max_retries, 3),
      base_delay_ms: Map.get(retry, :base_delay_ms, 1000),
      shell_path: Map.get(shell, :path),
      command_prefix: Map.get(shell, :command_prefix),
      auto_resize_images: Map.get(tools, :auto_resize_images, true),
      tools: tools,
      extension_paths: Map.get(agent, :extension_paths, []),
      theme: Map.get(agent, :theme, "default"),
      codex: Map.get(cli, :codex, %{}),
      kimi: Map.get(cli, :kimi, %{}),
      claude: Map.get(cli, :claude, %{}),
      opencode: Map.get(cli, :opencode, %{}),
      pi: Map.get(cli, :pi, %{})
    }
  end

  @doc """
  Get compaction settings as a map.
  """
  @spec get_compaction_settings(t()) :: %{
          enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer()
        }
  def get_compaction_settings(%__MODULE__{} = settings) do
    %{
      enabled: settings.compaction_enabled,
      reserve_tokens: settings.reserve_tokens,
      keep_recent_tokens: settings.keep_recent_tokens
    }
  end

  @doc """
  Get retry settings as a map.
  """
  @spec get_retry_settings(t()) :: %{
          enabled: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer()
        }
  def get_retry_settings(%__MODULE__{} = settings) do
    %{
      enabled: settings.retry_enabled,
      max_retries: settings.max_retries,
      base_delay_ms: settings.base_delay_ms
    }
  end

  @doc """
  Get model settings as a map.
  """
  @spec get_model_settings(t()) :: %{
          default_model: model_config() | nil,
          default_thinking_level: thinking_level()
        }
  def get_model_settings(%__MODULE__{} = settings) do
    %{
      default_model: settings.default_model,
      default_thinking_level: settings.default_thinking_level
    }
  end

  @doc """
  Get shell settings as a map.
  """
  @spec get_shell_settings(t()) :: %{
          shell_path: String.t() | nil,
          command_prefix: String.t() | nil
        }
  def get_shell_settings(%__MODULE__{} = settings) do
    %{
      shell_path: settings.shell_path,
      command_prefix: settings.command_prefix
    }
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_model_spec(nil, nil), do: nil

  defp parse_model_spec(provider, model) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
        %{provider: p, model_id: model_id, base_url: nil}

      [model_id] ->
        if model_id != "" do
          %{provider: provider, model_id: model_id, base_url: nil}
        else
          nil
        end

      _ ->
        if model != "" do
          %{provider: provider, model_id: model, base_url: nil}
        else
          nil
        end
    end
  end

  defp parse_model_spec(provider, model) when is_binary(provider) and provider != "" do
    %{provider: provider, model_id: to_string(model), base_url: nil}
  end

  defp parse_model_spec(_provider, _model), do: nil
end
