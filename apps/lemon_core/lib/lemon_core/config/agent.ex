defmodule LemonCore.Config.Agent do
  @moduledoc """
  Agent behavior configuration.

  Inspired by Ironclaw's config/agent.rs, this module handles
  agent-specific configuration like retry behavior, compaction settings,
  and shell configuration.

  ## Configuration

  Configuration is loaded from `[defaults]` + `[runtime]`. A legacy `[agent]`
  table is mapped onto those sections by `LemonCore.Config.Modular` before this
  module resolves them (see `LemonCore.Config.LegacyAgentMigration`).

      [defaults]
      provider = "anthropic"
      model = "claude-sonnet-4-20250514"
      thinking_level = "medium"

      [runtime]
      extension_paths = ["./my-extensions"]
      # Optional safety cap on tool-using turns per prompt. Unset (the
      # default) or 0 means unlimited: a turn ends when the model stops
      # calling tools.
      max_tool_turns = 0

      [runtime.extensions]
      enabled = true
      auto_load_default_paths = false

      [runtime.compaction]
      enabled = true
      reserve_tokens = 16384
      keep_recent_tokens = 20000
      # threshold_percent = 80     # optional: compact at this % of the context window
      # threshold_tokens = 150000  # optional: fixed token threshold, overrides percent

      [runtime.retry]
      enabled = true
      max_retries = 3
      base_delay_ms = 1000

      [runtime.provider_routing]
      # Ordered model alternatives, expanded through [model_roles], precede
      # the existing provider fallback plan. Same-provider models are retained.
      fallback_models = ["openai:gpt-4o", "@smol"]

      [runtime.shell]
      path = "/bin/zsh"
      command_prefix = ""

      [runtime.secret_obfuscation]
      # Opt-in: replace secrets in provider-visible session text with
      # reversible placeholders (see docs/security/secret-obfuscation.md).
      enabled = false

      # Native `task` subagents. Unset keys keep these defaults.
      [runtime.task]
      max_depth = 2                 # -1 unlimited; 0 forbids the main session from spawning
      max_runtime_ms = 0            # 0 disables the per-child wall-clock limit
      worktree_merge = "none"       # none | patch | branch, used by worktree = true tasks
      disabled_agents = []          # persona IDs hidden from the task tool
      agent_models = {}             # persona ID => model or @role override

  Environment variables override file configuration:
  - `LEMON_DEFAULT_PROVIDER`
  - `LEMON_DEFAULT_MODEL`
  - `LEMON_DEFAULT_THINKING_LEVEL`
  - `LEMON_EXTENSION_PATHS` (comma-separated)
  - `LEMON_EXTENSIONS_ENABLED`
  - `LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS`
  - `LEMON_SECRET_OBFUSCATION_ENABLED`
  """

  alias LemonCore.Env

  defstruct [
    :default_provider,
    :default_model,
    :default_thinking_level,
    :compaction,
    :retry,
    :max_tool_turns,
    :shell,
    :extensions,
    :extension_paths,
    :budget_defaults,
    :provider_routing,
    :secret_obfuscation,
    :task
  ]

  @type t :: %__MODULE__{
          default_provider: String.t(),
          default_model: String.t(),
          default_thinking_level: String.t(),
          compaction: %{
            enabled: boolean(),
            reserve_tokens: integer(),
            keep_recent_tokens: integer(),
            threshold_percent: 1..100 | nil,
            threshold_tokens: pos_integer() | nil
          },
          retry: %{
            enabled: boolean(),
            max_retries: integer(),
            base_delay_ms: integer()
          },
          max_tool_turns: pos_integer() | :infinity,
          shell: %{
            path: String.t() | nil,
            command_prefix: String.t() | nil
          },
          extensions: %{
            enabled: boolean(),
            auto_load_default_paths: boolean()
          },
          extension_paths: [String.t()],
          budget_defaults: %{max_children: integer()},
          provider_routing: map(),
          secret_obfuscation: %{enabled: boolean()},
          task: %{
            max_depth: integer(),
            max_runtime_ms: non_neg_integer(),
            worktree_merge: String.t(),
            disabled_agents: [String.t()],
            agent_models: %{optional(String.t()) => String.t()}
          }
        }

  @doc """
  Resolves agent configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    agent_settings = normalize_agent_settings(settings)

    %__MODULE__{
      default_provider: resolve_provider(agent_settings),
      default_model: resolve_model(agent_settings),
      default_thinking_level: resolve_thinking_level(agent_settings),
      compaction: resolve_compaction(agent_settings),
      retry: resolve_retry(agent_settings),
      max_tool_turns: resolve_max_tool_turns(agent_settings),
      shell: resolve_shell(agent_settings),
      extensions: resolve_extensions(agent_settings),
      extension_paths: resolve_extension_paths(agent_settings),
      budget_defaults: resolve_budget_defaults(agent_settings),
      provider_routing: resolve_provider_routing(agent_settings),
      secret_obfuscation: resolve_secret_obfuscation(agent_settings),
      task: resolve_task(agent_settings)
    }
  end

  # Private functions for resolving each config section

  defp normalize_agent_settings(settings) when is_map(settings) do
    runtime = ensure_map(settings["runtime"])
    defaults = ensure_map(settings["defaults"])

    runtime
    |> maybe_put("default_provider", defaults["provider"])
    |> maybe_put("default_model", defaults["model"])
    |> maybe_put("default_thinking_level", defaults["thinking_level"])
  end

  defp normalize_agent_settings(_), do: %{}

  defp resolve_provider(settings) do
    Env.get(:lemon_default_provider, default: settings["default_provider"] || "anthropic")
  end

  defp resolve_model(settings) do
    Env.get(:lemon_default_model,
      default: settings["default_model"] || "claude-sonnet-4-20250514"
    )
  end

  defp resolve_thinking_level(settings) do
    Env.get(:lemon_default_thinking_level,
      default: settings["default_thinking_level"] || "medium"
    )
  end

  defp resolve_compaction(settings) do
    compaction = settings["compaction"] || %{}

    %{
      enabled:
        Env.get(:lemon_compaction_enabled,
          default: if(is_nil(compaction["enabled"]), do: true, else: compaction["enabled"])
        ),
      reserve_tokens:
        Env.get(:lemon_compaction_reserve_tokens,
          default: compaction["reserve_tokens"] || 16_384
        ),
      keep_recent_tokens:
        Env.get(:lemon_compaction_keep_recent_tokens,
          default: compaction["keep_recent_tokens"] || 20_000
        ),
      # Optional; `nil` keeps the reserve-based threshold. Out-of-range values
      # are reported by `Config.Validator.validate_agent/2`.
      threshold_percent: compaction["threshold_percent"],
      threshold_tokens: compaction["threshold_tokens"]
    }
  end

  defp resolve_retry(settings) do
    retry = settings["retry"] || %{}

    %{
      enabled:
        Env.get(:lemon_retry_enabled,
          default: if(is_nil(retry["enabled"]), do: true, else: retry["enabled"])
        ),
      max_retries: Env.get(:lemon_max_retries, default: retry["max_retries"] || 3),
      base_delay_ms: Env.get(:lemon_base_delay_ms, default: retry["base_delay_ms"] || 1000)
    }
  end

  # Unlimited unless a positive integer is configured: coding and assistant
  # turns routinely need far more than a few dozen tool calls, and the user can
  # always interrupt. A cap stays available for deployments that want one.
  defp resolve_max_tool_turns(settings) do
    normalize_max_tool_turns(settings["max_tool_turns"])
  end

  defp normalize_max_tool_turns(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_tool_turns(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> normalize_max_tool_turns(parsed)
      _ -> :infinity
    end
  end

  defp normalize_max_tool_turns(_value), do: :infinity

  defp resolve_provider_routing(settings) do
    routing = ensure_map(settings["provider_routing"])

    %{
      enabled:
        Env.get(:lemon_provider_routing_enabled,
          default: if(is_nil(routing["enabled"]), do: true, else: routing["enabled"])
        ),
      fallback_providers:
        Env.get(:lemon_provider_fallback_providers,
          default: normalize_string_list(routing["fallback_providers"])
        ),
      fallback_models: normalize_fallback_models(routing["fallback_models"]),
      default_pool:
        Env.get(:lemon_provider_routing_default_pool,
          default: normalize_optional_string(routing["default_pool"])
        ),
      default_profile:
        Env.get(:lemon_provider_routing_default_profile,
          default: normalize_optional_string(routing["default_profile"])
        ),
      credential_pools: normalize_credential_pools(routing["credential_pools"]),
      profiles: normalize_provider_routing_profiles(routing["profiles"]),
      require_credentials:
        Env.get(:lemon_provider_routing_require_credentials,
          default:
            if(is_nil(routing["require_credentials"]),
              do: true,
              else: routing["require_credentials"]
            )
        )
    }
  end

  defp resolve_shell(settings) do
    shell = settings["shell"] || %{}

    %{
      path: Env.get(:lemon_shell_path, default: shell["path"]),
      command_prefix: Env.get(:lemon_shell_command_prefix, default: shell["command_prefix"])
    }
  end

  defp resolve_extensions(settings) do
    extensions = ensure_map(settings["extensions"])

    %{
      enabled:
        Env.get(:lemon_extensions_enabled,
          default: if(is_nil(extensions["enabled"]), do: true, else: extensions["enabled"])
        ),
      auto_load_default_paths:
        Env.get(:lemon_extensions_auto_load_default_paths,
          default:
            if(is_nil(extensions["auto_load_default_paths"]),
              do: false,
              else: extensions["auto_load_default_paths"]
            )
        )
    }
  end

  defp resolve_secret_obfuscation(settings) do
    secret_obfuscation = ensure_map(settings["secret_obfuscation"])

    %{
      enabled:
        Env.get(:lemon_secret_obfuscation_enabled,
          default: secret_obfuscation["enabled"] == true
        )
    }
  end

  defp resolve_extension_paths(settings) do
    # Note: intentionally not `Env.get/2` -- LEMON_EXTENSION_PATHS falls back
    # to settings only when the *parsed* list is empty (e.g. a whitespace- or
    # comma-only value), not merely when the raw string is unset. `Env.get/2`
    # only checks the raw string, so it would return `[]` for the former case
    # instead of falling through to `settings["extension_paths"]`.
    env_paths = Env.list("LEMON_EXTENSION_PATHS")

    if env_paths != [] do
      env_paths
    else
      settings["extension_paths"] || []
    end
  end

  defp resolve_budget_defaults(settings) do
    budget = settings["budget_defaults"] || %{}

    %{
      max_children: Env.get(:lemon_budget_max_children, default: budget["max_children"] || 5)
    }
  end

  # Values are passed through for `LemonCore.Config.Validator` to report;
  # `CodingAgent.SettingsManager` falls back to defaults for invalid types.
  defp resolve_task(settings) do
    task = ensure_map(settings["task"])

    %{
      max_depth: Map.get(task, "max_depth", 2),
      max_runtime_ms: Map.get(task, "max_runtime_ms", 0),
      worktree_merge: Map.get(task, "worktree_merge", "none"),
      disabled_agents: Map.get(task, "disabled_agents", []),
      agent_models: Map.get(task, "agent_models", %{})
    }
  end

  defp normalize_string_list(nil), do: []

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_string_list(_), do: []

  # Keep the ordered chain bounded, and reject malformed selectors at config
  # resolution rather than silently changing the operator's fallback order.
  defp normalize_fallback_models(nil), do: []

  defp normalize_fallback_models(values) when is_list(values) and length(values) <= 64 do
    Enum.map(values, fn
      value when is_binary(value) and byte_size(value) <= 512 ->
        selector = String.trim(value)

        if Regex.match?(~r/^@[^@\s]+$/u, selector) or
             Regex.match?(~r/^[A-Za-z0-9_-]+:[^\s]+$/u, selector) do
          selector
        else
          raise ArgumentError,
                "runtime.provider_routing.fallback_models contains an invalid selector"
        end

      _ ->
        raise ArgumentError,
              "runtime.provider_routing.fallback_models must contain model selectors"
    end)
  end

  defp normalize_fallback_models(_) do
    raise ArgumentError,
          "runtime.provider_routing.fallback_models must be an array of at most 64 selectors"
  end

  # Credential pools carry a provider list plus optional per-provider
  # credential refs:
  #
  #     [runtime.provider_routing.credential_pools.burst]
  #     providers = ["openai", "zai"]
  #     strategy = "round_robin"
  #
  #     [runtime.provider_routing.credential_pools.burst.credentials]
  #     openai = ["secret:llm_openai_api_key_alt", "env:OPENAI_API_KEY_2"]
  #     zai = ["llm_zai_api_key"]
  #
  # A ref is "secret:NAME" (resolved via LemonCore.Secrets), "env:VAR", or an
  # unprefixed secret name (matching the llm_<provider>_api_key convention).
  # Refs normalize to `%{source: :secret | :env, name: binary}`. A pool with
  # credentials but no providers derives its provider list from the credential
  # keys; a pool with neither is dropped.
  defp normalize_credential_pools(pools) when is_map(pools) do
    pools
    |> Enum.reduce(%{}, fn {name, cfg}, acc ->
      cfg = ensure_map(cfg)
      providers = normalize_string_list(cfg["providers"])
      credentials = normalize_pool_credentials(cfg["credentials"])

      providers =
        if providers == [] do
          credentials |> Map.keys() |> Enum.sort()
        else
          providers
        end

      if providers == [] do
        acc
      else
        Map.put(acc, to_string(name), %{
          providers: providers,
          strategy: normalize_routing_strategy(cfg["strategy"]),
          credentials: credentials
        })
      end
    end)
  end

  defp normalize_credential_pools(_), do: %{}

  defp normalize_pool_credentials(credentials) when is_map(credentials) do
    credentials
    |> Enum.reduce(%{}, fn {provider, refs}, acc ->
      refs =
        refs
        |> List.wrap()
        |> Enum.map(&normalize_credential_ref/1)
        |> Enum.reject(&is_nil/1)

      provider = provider |> to_string() |> String.trim()

      if refs == [] or provider == "" do
        acc
      else
        Map.put(acc, provider, refs)
      end
    end)
  end

  defp normalize_pool_credentials(_), do: %{}

  defp normalize_credential_ref(ref) when is_binary(ref) do
    case String.trim(ref) do
      "" -> nil
      "secret:" <> name -> credential_ref(:secret, name)
      "env:" <> name -> credential_ref(:env, name)
      name -> credential_ref(:secret, name)
    end
  end

  defp normalize_credential_ref(_), do: nil

  defp credential_ref(source, name) do
    case String.trim(name) do
      "" -> nil
      name -> %{source: source, name: name}
    end
  end

  defp normalize_provider_routing_profiles(profiles) when is_map(profiles) do
    profiles
    |> Enum.reduce(%{}, fn {name, cfg}, acc ->
      cfg = ensure_map(cfg)

      Map.put(acc, to_string(name), %{
        fallback_providers: normalize_string_list(cfg["fallback_providers"]),
        credential_pool: normalize_optional_string(cfg["credential_pool"]),
        distribution: normalize_distribution(cfg["distribution"])
      })
    end)
  end

  defp normalize_provider_routing_profiles(_), do: %{}

  defp normalize_distribution(distribution) when is_map(distribution) do
    distribution
    |> Enum.reduce(%{}, fn {provider, weight}, acc ->
      case normalize_weight(weight) do
        nil -> acc
        weight -> Map.put(acc, to_string(provider), weight)
      end
    end)
  end

  defp normalize_distribution(_), do: %{}

  defp normalize_weight(weight) when is_integer(weight) and weight > 0, do: weight
  defp normalize_weight(weight) when is_float(weight) and weight > 0, do: weight

  defp normalize_weight(weight) when is_binary(weight) do
    case Float.parse(weight) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp normalize_weight(_), do: nil

  defp normalize_routing_strategy(strategy) when strategy in ["priority", "round_robin"],
    do: strategy

  defp normalize_routing_strategy(_), do: "priority"

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  @doc """
  Returns the default agent configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "default_provider" => "anthropic",
      "default_model" => "claude-sonnet-4-20250514",
      "default_thinking_level" => "medium",
      "compaction" => %{
        "enabled" => true,
        "reserve_tokens" => 16_384,
        "keep_recent_tokens" => 20_000
      },
      "retry" => %{
        "enabled" => true,
        "max_retries" => 3,
        "base_delay_ms" => 1000
      },
      "provider_routing" => %{
        "enabled" => true,
        "fallback_providers" => [],
        "default_pool" => nil,
        "default_profile" => nil,
        "credential_pools" => %{},
        "profiles" => %{},
        "require_credentials" => true
      },
      "shell" => %{
        "path" => nil,
        "command_prefix" => nil
      },
      "extensions" => %{
        "enabled" => true,
        "auto_load_default_paths" => false
      },
      "secret_obfuscation" => %{
        "enabled" => false
      },
      "extension_paths" => [],
      "theme" => "lemon"
    }
  end
end
