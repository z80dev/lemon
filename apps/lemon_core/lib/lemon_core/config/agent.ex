defmodule LemonCore.Config.Agent do
  @moduledoc """
  Agent behavior configuration.

  Inspired by Ironclaw's config/agent.rs, this module handles
  agent-specific configuration like retry behavior, compaction settings,
  and shell configuration.

  ## Configuration

  Preferred configuration is loaded from `[defaults]` + `[runtime]`.
  Legacy `[agent]` remains supported for backward compatibility.

      [defaults]
      provider = "anthropic"
      model = "claude-sonnet-4-20250514"
      thinking_level = "medium"

      [runtime]
      extension_paths = ["./my-extensions"]
      theme = "lemon"

      [runtime.extensions]
      enabled = true
      auto_load_default_paths = false

      [runtime.compaction]
      enabled = true
      reserve_tokens = 16384
      keep_recent_tokens = 20000

      [runtime.retry]
      enabled = true
      max_retries = 3
      base_delay_ms = 1000

      [runtime.shell]
      path = "/bin/zsh"
      command_prefix = ""

  Environment variables override file configuration:
  - `LEMON_DEFAULT_PROVIDER`
  - `LEMON_DEFAULT_MODEL`
  - `LEMON_DEFAULT_THINKING_LEVEL`
  - `LEMON_EXTENSION_PATHS` (comma-separated)
  - `LEMON_EXTENSIONS_ENABLED`
  - `LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS`
  - `LEMON_THEME`
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :default_provider,
    :default_model,
    :default_thinking_level,
    :compaction,
    :retry,
    :shell,
    :extensions,
    :extension_paths,
    :theme,
    :budget_defaults,
    :cli,
    :provider_routing
  ]

  @type t :: %__MODULE__{
          default_provider: String.t(),
          default_model: String.t(),
          default_thinking_level: String.t(),
          compaction: %{
            enabled: boolean(),
            reserve_tokens: integer(),
            keep_recent_tokens: integer()
          },
          retry: %{
            enabled: boolean(),
            max_retries: integer(),
            base_delay_ms: integer()
          },
          shell: %{
            path: String.t() | nil,
            command_prefix: String.t() | nil
          },
          extensions: %{
            enabled: boolean(),
            auto_load_default_paths: boolean()
          },
          extension_paths: [String.t()],
          theme: String.t(),
          budget_defaults: %{max_children: integer()},
          cli: map(),
          provider_routing: map()
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
      shell: resolve_shell(agent_settings),
      extensions: resolve_extensions(agent_settings),
      extension_paths: resolve_extension_paths(agent_settings),
      theme: resolve_theme(agent_settings),
      budget_defaults: resolve_budget_defaults(agent_settings),
      cli: resolve_cli(agent_settings),
      provider_routing: resolve_provider_routing(agent_settings)
    }
  end

  # Private functions for resolving each config section

  defp normalize_agent_settings(settings) when is_map(settings) do
    legacy_agent = ensure_map(settings["agent"])
    runtime = ensure_map(settings["runtime"])
    defaults = ensure_map(settings["defaults"])

    deep_merge(legacy_agent, runtime)
    |> maybe_put("default_provider", defaults["provider"])
    |> maybe_put("default_model", defaults["model"])
    |> maybe_put("default_thinking_level", defaults["thinking_level"])
  end

  defp normalize_agent_settings(_), do: %{}

  defp resolve_provider(settings) do
    Helpers.get_env("LEMON_DEFAULT_PROVIDER", settings["default_provider"] || "anthropic")
  end

  defp resolve_model(settings) do
    Helpers.get_env(
      "LEMON_DEFAULT_MODEL",
      settings["default_model"] || "claude-sonnet-4-20250514"
    )
  end

  defp resolve_thinking_level(settings) do
    Helpers.get_env(
      "LEMON_DEFAULT_THINKING_LEVEL",
      settings["default_thinking_level"] || "medium"
    )
  end

  defp resolve_compaction(settings) do
    compaction = settings["compaction"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_COMPACTION_ENABLED",
          if(is_nil(compaction["enabled"]), do: true, else: compaction["enabled"])
        ),
      reserve_tokens:
        Helpers.get_env_int(
          "LEMON_COMPACTION_RESERVE_TOKENS",
          compaction["reserve_tokens"] || 16_384
        ),
      keep_recent_tokens:
        Helpers.get_env_int(
          "LEMON_COMPACTION_KEEP_RECENT_TOKENS",
          compaction["keep_recent_tokens"] || 20_000
        )
    }
  end

  defp resolve_retry(settings) do
    retry = settings["retry"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_RETRY_ENABLED",
          if(is_nil(retry["enabled"]), do: true, else: retry["enabled"])
        ),
      max_retries: Helpers.get_env_int("LEMON_MAX_RETRIES", retry["max_retries"] || 3),
      base_delay_ms: Helpers.get_env_int("LEMON_BASE_DELAY_MS", retry["base_delay_ms"] || 1000)
    }
  end

  defp resolve_provider_routing(settings) do
    routing = ensure_map(settings["provider_routing"])

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_PROVIDER_ROUTING_ENABLED",
          if(is_nil(routing["enabled"]), do: true, else: routing["enabled"])
        ),
      fallback_providers:
        routing["fallback_providers"]
        |> normalize_string_list()
        |> env_string_list("LEMON_PROVIDER_FALLBACK_PROVIDERS"),
      default_pool:
        Helpers.get_env(
          "LEMON_PROVIDER_ROUTING_DEFAULT_POOL",
          normalize_optional_string(routing["default_pool"])
        ),
      default_profile:
        Helpers.get_env(
          "LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE",
          normalize_optional_string(routing["default_profile"])
        ),
      credential_pools: normalize_credential_pools(routing["credential_pools"]),
      profiles: normalize_provider_routing_profiles(routing["profiles"]),
      require_credentials:
        Helpers.get_env_bool(
          "LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS",
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
      path: Helpers.get_env("LEMON_SHELL_PATH", shell["path"]),
      command_prefix: Helpers.get_env("LEMON_SHELL_COMMAND_PREFIX", shell["command_prefix"])
    }
  end

  defp resolve_extensions(settings) do
    extensions = ensure_map(settings["extensions"])

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_EXTENSIONS_ENABLED",
          if(is_nil(extensions["enabled"]), do: true, else: extensions["enabled"])
        ),
      auto_load_default_paths:
        Helpers.get_env_bool(
          "LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS",
          if(is_nil(extensions["auto_load_default_paths"]),
            do: false,
            else: extensions["auto_load_default_paths"]
          )
        )
    }
  end

  defp resolve_extension_paths(settings) do
    env_paths = Helpers.get_env_list("LEMON_EXTENSION_PATHS")

    if env_paths != [] do
      env_paths
    else
      settings["extension_paths"] || []
    end
  end

  defp resolve_theme(settings) do
    Helpers.get_env("LEMON_THEME", settings["theme"] || "lemon")
  end

  defp resolve_budget_defaults(settings) do
    budget = settings["budget_defaults"] || %{}

    %{
      max_children:
        Helpers.get_env_int(
          "LEMON_BUDGET_MAX_CHILDREN",
          budget["max_children"] || 5
        )
    }
  end

  defp resolve_cli(settings) do
    cli = settings["cli"] || %{}

    %{
      codex: resolve_codex_cli(cli["codex"] || %{}),
      kimi: resolve_kimi_cli(cli["kimi"] || %{}),
      opencode: resolve_opencode_cli(cli["opencode"] || %{}),
      pi: resolve_pi_cli(cli["pi"] || %{}),
      droid: resolve_droid_cli(cli["droid"] || %{}),
      claude: resolve_claude_cli(cli["claude"] || %{})
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

  defp normalize_credential_pools(pools) when is_map(pools) do
    pools
    |> Enum.reduce(%{}, fn {name, cfg}, acc ->
      cfg = ensure_map(cfg)
      providers = normalize_string_list(cfg["providers"])

      if providers == [] do
        acc
      else
        Map.put(acc, to_string(name), %{
          providers: providers,
          strategy: normalize_routing_strategy(cfg["strategy"])
        })
      end
    end)
  end

  defp normalize_credential_pools(_), do: %{}

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

  defp env_string_list(default, env_name) do
    case Helpers.get_env(env_name) do
      nil -> default
      "" -> default
      value -> normalize_string_list(value)
    end
  end

  defp resolve_codex_cli(codex) do
    %{
      extra_args: parse_string_list(codex["extra_args"]),
      auto_approve: codex["auto_approve"] || false
    }
  end

  defp resolve_kimi_cli(kimi) do
    %{
      extra_args: parse_string_list(kimi["extra_args"])
    }
  end

  defp resolve_opencode_cli(opencode) do
    %{
      model: normalize_optional_string(opencode["model"])
    }
  end

  defp resolve_pi_cli(pi) do
    %{
      extra_args: parse_string_list(pi["extra_args"]),
      model: normalize_optional_string(pi["model"]),
      provider: normalize_optional_string(pi["provider"])
    }
  end

  defp resolve_droid_cli(droid) do
    %{
      extra_args: parse_string_list(droid["extra_args"]),
      model: normalize_optional_string(droid["model"]),
      reasoning_effort: normalize_optional_string(droid["reasoning_effort"]),
      enabled_tools: parse_string_list(droid["enabled_tools"]),
      disabled_tools: parse_string_list(droid["disabled_tools"]),
      use_spec: if(is_nil(droid["use_spec"]), do: false, else: droid["use_spec"]),
      spec_model: normalize_optional_string(droid["spec_model"])
    }
  end

  defp resolve_claude_cli(claude) do
    %{
      dangerously_skip_permissions:
        if(is_nil(claude["dangerously_skip_permissions"]),
          do: true,
          else: claude["dangerously_skip_permissions"]
        ),
      allowed_tools: parse_string_list(claude["allowed_tools"]),
      scrub_env: normalize_scrub_env(claude["scrub_env"]),
      env_allowlist: parse_string_list(claude["env_allowlist"]),
      env_allow_prefixes: parse_string_list(claude["env_allow_prefixes"]),
      env_overrides: normalize_env_overrides(claude["env_overrides"])
    }
  end

  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: list
  defp parse_string_list(_), do: []

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  defp normalize_scrub_env(nil), do: :auto
  defp normalize_scrub_env("auto"), do: :auto
  defp normalize_scrub_env("true"), do: true
  defp normalize_scrub_env("false"), do: false
  defp normalize_scrub_env(true), do: true
  defp normalize_scrub_env(false), do: false
  defp normalize_scrub_env(_), do: :auto

  defp normalize_env_overrides(nil), do: %{}
  defp normalize_env_overrides(map) when is_map(map), do: map
  defp normalize_env_overrides(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end

  defp deep_merge(_base, override), do: override

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
      "extension_paths" => [],
      "theme" => "lemon"
    }
  end
end
