defmodule CodingAgent.SettingsManager do
  @moduledoc """
  Settings adapter for the coding agent.

  Loads canonical TOML configuration via `LemonCore.Config` and exposes
  a struct that existing coding agent components can consume.
  """

  alias LemonAgent.ModelRuntime.{CustomProviders, ModelRoles}
  alias LemonCore.Config, as: LemonConfig

  @type thinking_level :: :off | :auto | :minimal | :low | :medium | :high | :xhigh

  @type model_config :: %{
          provider: String.t() | nil,
          model_id: String.t(),
          base_url: String.t() | nil
        }

  @typedoc "Native task subagent settings from `[runtime.task]`."
  @type task_settings :: %{
          max_depth: integer(),
          max_runtime_ms: non_neg_integer(),
          idle_ttl_ms: non_neg_integer(),
          worktree_merge: String.t(),
          disabled_agents: [String.t()],
          agent_models: %{optional(String.t()) => String.t()}
        }

  @type t :: %__MODULE__{
          # Model settings
          default_model: model_config() | String.t() | nil,
          model_roles: ModelRoles.roles(),
          default_thinking_level: thinking_level(),

          # Provider settings
          providers: %{
            optional(String.t()) => %{
              optional(:api_key) => String.t() | nil,
              optional(:base_url) => String.t() | nil,
              optional(:api_key_secret) => String.t() | nil,
              optional(:auth_source) => String.t() | nil,
              optional(:oauth_secret) => String.t() | nil,
              optional(:project) => String.t() | nil,
              optional(:project_id) => String.t() | nil,
              optional(:project_secret) => String.t() | nil
            }
          },
          provider_routing: map(),

          # Compaction settings
          compaction_enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer(),
          compaction_threshold_percent: 1..100 | nil,
          compaction_threshold_tokens: pos_integer() | nil,

          # Retry settings
          retry_enabled: boolean(),
          max_retries: non_neg_integer(),
          base_delay_ms: non_neg_integer(),

          # Agent loop settings
          max_tool_turns: pos_integer() | :infinity,
          budgets: map(),

          # Shell settings
          shell_path: String.t() | nil,
          command_prefix: String.t() | nil,

          # Tool settings
          auto_resize_images: boolean(),
          tools: map(),

          # Native task subagent settings ([runtime.task])
          task: task_settings(),

          # Extension settings
          extension_paths: [String.t()],
          extension_auto_load_default_paths: boolean(),

          # Secret obfuscation ([runtime.secret_obfuscation])
          secret_obfuscation_enabled: boolean()
        }

  defstruct [
    # Model settings
    default_model: nil,
    model_roles: %{},
    default_thinking_level: :medium,

    # Provider settings
    providers: %{},
    provider_routing: %{enabled: true, fallback_providers: [], require_credentials: true},

    # Compaction settings
    compaction_enabled: true,
    reserve_tokens: 16_384,
    keep_recent_tokens: 20_000,
    compaction_threshold_percent: nil,
    compaction_threshold_tokens: nil,

    # Retry settings
    retry_enabled: true,
    max_retries: 3,
    base_delay_ms: 1000,

    # Agent loop settings: unlimited tool turns unless configured
    max_tool_turns: :infinity,
    budgets: %{},

    # Shell settings
    shell_path: nil,
    command_prefix: nil,

    # Tool settings
    auto_resize_images: true,
    tools: %{},

    # Extension settings
    extension_paths: [],
    extension_auto_load_default_paths: false,

    # Secret obfuscation: opt-in
    secret_obfuscation_enabled: false,

    # Native task subagent settings
    task: %{
      max_depth: 2,
      max_runtime_ms: 0,
      idle_ttl_ms: 300_000,
      worktree_merge: "none",
      disabled_agents: [],
      agent_models: %{}
    }
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

    case ModelRoles.validate(config.model_roles) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, reason
    end

    compaction = Map.get(agent, :compaction, %{})
    retry = Map.get(agent, :retry, %{})
    provider_routing = Map.get(agent, :provider_routing, %{})
    shell = Map.get(agent, :shell, %{})
    extensions = Map.get(agent, :extensions, %{})
    tools = Map.get(agent, :tools, %{})

    %__MODULE__{
      default_model: default_model,
      model_roles: config.model_roles,
      default_thinking_level: Map.get(agent, :default_thinking_level, :medium),
      providers: config.providers || %{},
      provider_routing:
        Map.merge(
          %{enabled: true, fallback_providers: [], require_credentials: true},
          provider_routing
        ),
      compaction_enabled: Map.get(compaction, :enabled, true),
      reserve_tokens: Map.get(compaction, :reserve_tokens, 16_384),
      keep_recent_tokens: Map.get(compaction, :keep_recent_tokens, 20_000),
      compaction_threshold_percent: threshold_percent(Map.get(compaction, :threshold_percent)),
      compaction_threshold_tokens: threshold_tokens(Map.get(compaction, :threshold_tokens)),
      retry_enabled: Map.get(retry, :enabled, true),
      max_retries: Map.get(retry, :max_retries, 3),
      base_delay_ms: Map.get(retry, :base_delay_ms, 1000),
      max_tool_turns: Map.get(agent, :max_tool_turns) || :infinity,
      budgets: config.budgets,
      shell_path: Map.get(shell, :path),
      command_prefix: Map.get(shell, :command_prefix),
      auto_resize_images: Map.get(tools, :auto_resize_images, true),
      tools: tools,
      extension_paths: Map.get(agent, :extension_paths, []),
      extension_auto_load_default_paths: Map.get(extensions, :auto_load_default_paths, false),
      secret_obfuscation_enabled:
        Map.get(Map.get(agent, :secret_obfuscation) || %{}, :enabled, false) == true,
      task: task_settings(Map.get(agent, :task))
    }
  end

  # Invalid values are reported by `LemonCore.Config.Validator`; runtime
  # consumers keep the documented defaults instead of crashing.
  defp task_settings(task) when is_map(task) do
    defaults = %__MODULE__{}.task

    %{
      max_depth:
        case Map.get(task, :max_depth) do
          depth when is_integer(depth) and depth >= -1 -> depth
          _ -> defaults.max_depth
        end,
      max_runtime_ms:
        case Map.get(task, :max_runtime_ms) do
          ms when is_integer(ms) and ms >= 0 -> ms
          _ -> defaults.max_runtime_ms
        end,
      idle_ttl_ms:
        case Map.get(task, :idle_ttl_ms) do
          ms when is_integer(ms) and ms >= 0 -> ms
          _ -> defaults.idle_ttl_ms
        end,
      worktree_merge:
        case Map.get(task, :worktree_merge) do
          mode when mode in ["none", "patch", "branch"] -> mode
          _ -> defaults.worktree_merge
        end,
      disabled_agents:
        case Map.get(task, :disabled_agents) do
          ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
          _ -> defaults.disabled_agents
        end,
      agent_models:
        case Map.get(task, :agent_models) do
          models when is_map(models) ->
            for {id, model} <- models,
                is_binary(id) and is_binary(model) and String.trim(model) != "",
                into: %{},
                do: {id, String.trim(model)}

          _ ->
            defaults.agent_models
        end
    }
  end

  defp task_settings(_task), do: %__MODULE__{}.task

  @doc """
  Get compaction settings as a map.
  """
  @spec get_compaction_settings(t()) :: %{
          optional(:threshold_percent) => 1..100,
          optional(:threshold_tokens) => pos_integer(),
          enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer()
        }
  def get_compaction_settings(%__MODULE__{} = settings) do
    base = %{
      enabled: settings.compaction_enabled,
      reserve_tokens: settings.reserve_tokens,
      keep_recent_tokens: settings.keep_recent_tokens
    }

    # Thresholds are optional; absent keys keep the reserve-based threshold.
    base
    |> put_unless_nil(:threshold_percent, settings.compaction_threshold_percent)
    |> put_unless_nil(:threshold_tokens, settings.compaction_threshold_tokens)
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # Invalid thresholds are ignored here; `Config.Validator` reports them at load.
  defp threshold_percent(value) when is_integer(value) and value in 1..100, do: value
  defp threshold_percent(_value), do: nil

  defp threshold_tokens(value) when is_integer(value) and value > 0, do: value
  defp threshold_tokens(_value), do: nil

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
          default_model: model_config() | String.t() | nil,
          model_roles: ModelRoles.roles(),
          default_thinking_level: thinking_level()
        }
  def get_model_settings(%__MODULE__{} = settings) do
    %{
      default_model: settings.default_model,
      model_roles: settings.model_roles,
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
  defp parse_model_spec(_provider, "@" <> _role = selector), do: selector

  defp parse_model_spec(provider, model) when is_binary(model) do
    # Try colon separator first (Lemon's current format)
    case String.split(model, ":", parts: 2) do
      [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
        %{provider: normalize_provider(p), model_id: model_id, base_url: nil}

      _ ->
        # Try slash separator (OpenRouter/Pi format)
        case String.split(model, "/", parts: 2) do
          [p, model_id] when provider in [nil, ""] and p != "" and model_id != "" ->
            %{provider: normalize_provider(p), model_id: model_id, base_url: nil}

          _ ->
            # Fall back to treating entire string as model_id
            if model != "" do
              %{provider: normalize_provider(provider), model_id: model, base_url: nil}
            else
              nil
            end
        end
    end
  end

  defp parse_model_spec(provider, model) when is_binary(provider) and provider != "" do
    %{provider: normalize_provider(provider), model_id: to_string(model), base_url: nil}
  end

  defp parse_model_spec(_provider, _model), do: nil

  # Built-in provider names normalize to atoms (lowercase, dashes to
  # underscores). Custom `[providers.<id>]` ids stay binaries so config input
  # never creates atoms.
  defp normalize_provider(p) when is_binary(p) do
    normalized = p |> String.downcase() |> String.replace("-", "_")

    if CustomProviders.builtin?(normalized),
      do: String.to_atom(normalized),
      else: String.trim(p)
  end

  defp normalize_provider(p) when is_atom(p), do: p
  defp normalize_provider(_), do: nil
end
