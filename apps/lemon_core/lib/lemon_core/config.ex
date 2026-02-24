defmodule LemonCore.Config do
  @moduledoc """
  Canonical Lemon configuration loader.

  Loads TOML configuration from:
  - Global: `~/.lemon/config.toml`
  - Project: `<project>/.lemon/config.toml`

  Project values override global values. Environment variables override both.
  """

  require Logger

  @global_config_path "~/.lemon/config.toml"

  @default_agent %{
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
    "shell" => %{
      "path" => nil,
      "command_prefix" => nil
    },
    "tools" => %{
      "auto_resize_images" => true,
      "web" => %{
        "search" => %{
          "enabled" => true,
          "provider" => "brave",
          "api_key" => nil,
          "max_results" => 5,
          "timeout_seconds" => 30,
          "cache_ttl_minutes" => 15,
          "failover" => %{
            "enabled" => true,
            "provider" => nil
          },
          "perplexity" => %{
            "api_key" => nil,
            "base_url" => nil,
            "model" => "perplexity/sonar-pro"
          }
        },
        "fetch" => %{
          "enabled" => true,
          "max_chars" => 50_000,
          "timeout_seconds" => 30,
          "cache_ttl_minutes" => 15,
          "max_redirects" => 3,
          "user_agent" =>
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
          "readability" => true,
          "allow_private_network" => false,
          "allowed_hostnames" => [],
          "firecrawl" => %{
            "enabled" => nil,
            "api_key" => nil,
            "base_url" => "https://api.firecrawl.dev",
            "only_main_content" => true,
            "max_age_ms" => 172_800_000,
            "timeout_seconds" => 60
          }
        },
        "cache" => %{
          "persistent" => true,
          "path" => nil,
          "max_entries" => 100
        }
      },
      "wasm" => %{
        "enabled" => false,
        "auto_build" => true,
        "runtime_path" => "",
        "tool_paths" => [],
        "default_memory_limit" => 10_485_760,
        "default_timeout_ms" => 60_000,
        "default_fuel_limit" => 10_000_000,
        "cache_compiled" => true,
        "cache_dir" => "",
        "max_tool_invoke_depth" => 4
      }
    },
    "extension_paths" => [],
    "theme" => "default",
    "cli" => %{
      "codex" => %{
        "extra_args" => ["-c", "notify=[]"],
        "auto_approve" => false
      },
      "kimi" => %{
        "extra_args" => []
      },
      "opencode" => %{
        "model" => nil
      },
      "pi" => %{
        "extra_args" => [],
        "model" => nil,
        "provider" => nil
      },
      "claude" => %{
        "dangerously_skip_permissions" => true,
        "allowed_tools" => nil,
        "scrub_env" => :auto,
        "env_allowlist" => nil,
        "env_allow_prefixes" => nil,
        "env_overrides" => %{}
      }
    }
  }

  @default_tui %{
    "theme" => "lemon",
    "debug" => false
  }

  @default_logging %{
    "file" => nil,
    "level" => nil,
    "max_no_bytes" => nil,
    "max_no_files" => nil,
    "compress_on_rotate" => nil,
    "filesync_repeat_interval" => nil
  }

  @default_gateway %{
    "max_concurrent_runs" => 2,
    "default_engine" => "lemon",
    "default_cwd" => nil,
    "auto_resume" => false,
    "enable_telegram" => false,
    "enable_discord" => false,
    "require_engine_lock" => true,
    "engine_lock_timeout_ms" => 60_000,
    "projects" => %{},
    "bindings" => [],
    "sms" => %{},
    "queue" => %{
      "mode" => nil,
      "cap" => nil,
      "drop" => nil
    },
    "telegram" => %{},
    "discord" => %{},
    "engines" => %{}
  }

  defstruct providers: %{}, agent: %{}, tui: %{}, logging: %{}, gateway: %{}, agents: %{}

  @type provider_config :: %{
          optional(:api_key) => String.t() | nil,
          optional(:base_url) => String.t() | nil,
          optional(:api_key_secret) => String.t() | nil
        }
  @type t :: %__MODULE__{
          providers: %{optional(String.t()) => provider_config()},
          agent: map(),
          tui: map(),
          logging: map(),
          gateway: map(),
          agents: map()
        }

  @doc """
  Path to global config file.
  """
  @spec global_path() :: String.t()
  def global_path do
    case System.get_env("HOME") do
      nil -> Path.expand(@global_config_path)
      home -> Path.join([home, ".lemon", "config.toml"])
    end
  end

  @doc """
  Path to project config file for a given cwd.
  """
  @spec project_path(String.t()) :: String.t()
  def project_path(cwd) do
    Path.join([Path.expand(cwd), ".lemon", "config.toml"])
  end

  @doc """
  Load merged config (global + project) with environment overrides.
  """
  @spec load(String.t() | nil, keyword()) :: t()
  def load(cwd \\ nil, opts \\ []) do
    cached(cwd, opts)
  end

  @doc """
  Load config using the supervised cache when available.

  This is the default hot-path read. It avoids re-reading/parsing TOML on every call.
  """
  @spec cached(String.t() | nil, keyword()) :: t()
  def cached(cwd \\ nil, opts \\ []) do
    base =
      if Keyword.get(opts, :cache, true) and Code.ensure_loaded?(LemonCore.ConfigCache) and
           function_exported?(LemonCore.ConfigCache, :available?, 0) and
           LemonCore.ConfigCache.available?() do
        LemonCore.ConfigCache.get(cwd, opts)
      else
        load_base_from_disk(cwd)
      end

    base
    |> apply_env_overrides()
    |> apply_overrides(Keyword.get(opts, :overrides))
  end

  @doc """
  Force a reload from disk (and update the cache when available).

  Use this for explicit reload flows (e.g. admin reload, control plane refresh).
  """
  @spec reload(String.t() | nil, keyword()) :: t()
  def reload(cwd \\ nil, opts \\ []) do
    base =
      if Code.ensure_loaded?(LemonCore.ConfigCache) and
           function_exported?(LemonCore.ConfigCache, :available?, 0) and
           LemonCore.ConfigCache.available?() do
        LemonCore.ConfigCache.reload(cwd, opts)
      else
        load_base_from_disk(cwd)
      end

    base
    |> apply_env_overrides()
    |> apply_overrides(Keyword.get(opts, :overrides))
  end

  @doc false
  @spec load_base_from_disk(String.t() | nil) :: t()
  def load_base_from_disk(cwd \\ nil) do
    global = load_file(global_path())
    project = if is_binary(cwd) and cwd != "", do: load_file(project_path(cwd)), else: %{}
    merged = deep_merge(global, project)
    from_map(merged)
  end

  @doc """
  Load a single TOML file without environment overrides.
  """
  @spec load_file(String.t()) :: map()
  def load_file(path) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      case Toml.decode_file(expanded) do
        {:ok, map} ->
          stringify_keys(map)

        {:error, reason} ->
          Logger.warning("Failed to parse config TOML at #{expanded}: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  end

  @doc """
  Get a nested config value.
  """
  @spec get(t(), [atom()] | atom(), term()) :: term()
  def get(%__MODULE__{} = config, key, default \\ nil) do
    get_in_config(to_map(config), key, default)
  end

  @doc """
  Return config as a plain map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      providers: config.providers,
      agent: config.agent,
      tui: config.tui,
      logging: config.logging,
      gateway: config.gateway,
      agents: config.agents
    }
  end

  # ============================================================================
  # Parsing
  # ============================================================================

  @spec from_map(map()) :: t()
  defp from_map(map) when is_map(map) do
    map = stringify_keys(map)
    defaults = parse_defaults(Map.get(map, "defaults", %{}))
    agent_settings = normalize_agent_settings(map, defaults)
    agents_settings = normalize_agents_settings(map)

    %__MODULE__{
      providers: parse_providers(Map.get(map, "providers", %{})),
      agent: parse_agent(agent_settings),
      tui: parse_tui(Map.get(map, "tui", %{})),
      logging: parse_logging(Map.get(map, "logging", %{})),
      gateway: parse_gateway(Map.get(map, "gateway", %{})),
      agents: parse_agents(agents_settings, defaults)
    }
  end

  defp parse_defaults(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      "provider" => normalize_optional_string(map["provider"]),
      "model" => normalize_optional_string(map["model"]),
      "thinking_level" => normalize_optional_string(map["thinking_level"]),
      "engine" => normalize_optional_string(map["engine"])
    }
    |> reject_nil_values()
  end

  defp parse_defaults(_), do: %{}

  defp normalize_agent_settings(map, defaults) when is_map(map) do
    legacy_agent = ensure_map(Map.get(map, "agent", %{}))
    runtime = ensure_map(Map.get(map, "runtime", %{}))

    deep_merge(legacy_agent, runtime)
    |> maybe_put_string("default_provider", defaults["provider"])
    |> maybe_put_string("default_model", defaults["model"])
    |> maybe_put_string("default_thinking_level", defaults["thinking_level"])
  end

  defp normalize_agents_settings(map) when is_map(map) do
    legacy_agents = ensure_map(Map.get(map, "agents", %{}))
    profiles = ensure_map(Map.get(map, "profiles", %{}))

    deep_merge(legacy_agents, profiles)
  end

  defp parse_providers(map) do
    map
    |> stringify_keys()
    |> Enum.reduce(%{}, fn {name, cfg}, acc ->
      case parse_provider_config(cfg) do
        nil -> acc
        parsed -> Map.put(acc, name, parsed)
      end
    end)
  end

  defp parse_provider_config(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      api_key: map["api_key"],
      base_url: map["base_url"],
      api_key_secret: normalize_optional_string(map["api_key_secret"])
    }
    |> reject_nil_values()
  end

  defp parse_provider_config(_), do: nil

  defp parse_agent(map) do
    map = deep_merge(@default_agent, stringify_keys(map))

    %{
      default_provider: map["default_provider"],
      default_model: map["default_model"],
      default_thinking_level: parse_thinking_level(map["default_thinking_level"]),
      compaction: parse_compaction(map["compaction"] || %{}),
      retry: parse_retry(map["retry"] || %{}),
      shell: parse_shell(map["shell"] || %{}),
      tools: parse_tools(map["tools"] || %{}),
      extension_paths: parse_string_list(map["extension_paths"]),
      theme: map["theme"],
      cli: parse_cli(map["cli"] || %{})
    }
  end

  defp parse_tui(map) do
    map = deep_merge(@default_tui, stringify_keys(map))

    %{
      theme: map["theme"],
      debug: parse_boolean(map["debug"], false)
    }
  end

  defp parse_logging(map) do
    map = deep_merge(@default_logging, stringify_keys(map))

    %{
      file: map["file"],
      level: parse_log_level(map["level"]),
      max_no_bytes: map["max_no_bytes"],
      max_no_files: map["max_no_files"],
      compress_on_rotate: parse_boolean(map["compress_on_rotate"], nil),
      filesync_repeat_interval: map["filesync_repeat_interval"]
    }
    |> reject_nil_values()
  end

  defp parse_gateway(map) do
    map = deep_merge(@default_gateway, stringify_keys(map))

    %{
      max_concurrent_runs: map["max_concurrent_runs"],
      default_engine: map["default_engine"],
      default_cwd: parse_optional_string(map["default_cwd"]),
      auto_resume: parse_boolean(map["auto_resume"], false),
      enable_telegram: parse_boolean(map["enable_telegram"], false),
      enable_discord: parse_boolean(map["enable_discord"], false),
      require_engine_lock: parse_boolean(map["require_engine_lock"], true),
      engine_lock_timeout_ms: map["engine_lock_timeout_ms"],
      projects: parse_gateway_projects(map["projects"] || %{}),
      bindings: parse_gateway_bindings(map["bindings"] || []),
      sms: parse_gateway_sms(map["sms"] || %{}),
      queue: parse_gateway_queue(map["queue"] || %{}),
      telegram: parse_gateway_telegram(map["telegram"] || %{}),
      discord: parse_gateway_discord(map["discord"] || %{}),
      engines: parse_gateway_engines(map["engines"] || %{})
    }
  end

  defp parse_gateway_projects(map) when is_map(map) do
    map
    |> stringify_keys()
    |> Enum.reduce(%{}, fn {id, cfg}, acc ->
      cfg = stringify_keys(cfg || %{})

      Map.put(acc, id, %{
        root: cfg["root"],
        default_engine: cfg["default_engine"]
      })
    end)
  end

  defp parse_gateway_projects(_), do: %{}

  defp parse_gateway_bindings(list) when is_list(list) do
    Enum.map(list, fn item ->
      cfg = stringify_keys(item || %{})

      %{
        transport: cfg["transport"],
        chat_id: cfg["chat_id"],
        topic_id: cfg["topic_id"],
        project: cfg["project"],
        agent_id: cfg["agent_id"],
        default_engine: cfg["default_engine"],
        queue_mode: cfg["queue_mode"]
      }
    end)
  end

  defp parse_gateway_bindings(_), do: []

  defp parse_gateway_queue(map) do
    map = stringify_keys(map)

    %{
      mode: map["mode"],
      cap: map["cap"],
      drop: map["drop"]
    }
  end

  defp parse_gateway_sms(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      webhook_enabled: parse_boolean(map["webhook_enabled"], nil),
      webhook_port: map["webhook_port"],
      webhook_bind: parse_optional_string(map["webhook_bind"]),
      inbox_number: parse_optional_string(map["inbox_number"]),
      inbox_ttl_ms: map["inbox_ttl_ms"],
      validate_webhook: parse_boolean(map["validate_webhook"], nil),
      auth_token: parse_optional_string(map["auth_token"]),
      webhook_url: parse_optional_string(map["webhook_url"])
    }
    |> reject_nil_values()
  end

  defp parse_gateway_sms(_), do: %{}

  defp parse_gateway_telegram(map) do
    map = stringify_keys(map)

    %{
      bot_token: map["bot_token"],
      allowed_chat_ids: map["allowed_chat_ids"],
      poll_interval_ms: map["poll_interval_ms"],
      edit_throttle_ms: map["edit_throttle_ms"],
      debounce_ms: map["debounce_ms"],
      allow_queue_override: map["allow_queue_override"],
      account_id: map["account_id"],
      offset: map["offset"],
      drop_pending_updates: map["drop_pending_updates"],
      debug_inbound: map["debug_inbound"],
      log_drops: map["log_drops"],
      compaction: parse_gateway_telegram_compaction(map["compaction"] || %{}),
      files: parse_gateway_telegram_files(map["files"] || %{})
    }
    |> reject_nil_values()
  end

  defp parse_gateway_telegram_compaction(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], nil),
      context_window_tokens: parse_positive_integer(map["context_window_tokens"], nil),
      reserve_tokens: parse_positive_integer(map["reserve_tokens"], nil),
      trigger_ratio: parse_non_negative_number(map["trigger_ratio"], nil)
    }
    |> reject_nil_values()
  end

  defp parse_gateway_telegram_compaction(_), do: %{}

  defp parse_gateway_telegram_files(map) when is_map(map) do
    map = stringify_keys(map)

    %{
      enabled: map["enabled"],
      auto_put: map["auto_put"],
      auto_put_mode: map["auto_put_mode"],
      auto_send_generated_images: map["auto_send_generated_images"],
      auto_send_generated_max_files: map["auto_send_generated_max_files"],
      uploads_dir: map["uploads_dir"],
      allowed_user_ids: map["allowed_user_ids"],
      deny_globs: map["deny_globs"],
      max_upload_bytes: map["max_upload_bytes"],
      max_download_bytes: map["max_download_bytes"],
      media_group_debounce_ms: map["media_group_debounce_ms"],
      outbound_send_delay_ms: map["outbound_send_delay_ms"]
    }
    |> reject_nil_values()
  end

  defp parse_gateway_telegram_files(_), do: %{}

  defp parse_gateway_discord(map) do
    map = stringify_keys(map)

    %{
      bot_token: parse_optional_string(map["bot_token"]),
      allowed_guild_ids: map["allowed_guild_ids"],
      allowed_channel_ids: map["allowed_channel_ids"],
      deny_unbound_channels: parse_boolean(map["deny_unbound_channels"], false)
    }
    |> reject_nil_values()
  end

  defp parse_gateway_engines(map) when is_map(map) do
    map
    |> stringify_keys()
    |> Enum.reduce(%{}, fn {name, cfg}, acc ->
      cfg = stringify_keys(cfg || %{})

      Map.put(acc, name, %{
        cli_path: cfg["cli_path"],
        enabled: cfg["enabled"]
      })
    end)
  end

  defp parse_gateway_engines(_), do: %{}

  defp parse_agents(map, defaults) when is_map(map) do
    map
    |> stringify_keys()
    |> Enum.reduce(%{}, fn {id, cfg}, acc ->
      parsed = parse_agent_profile(to_string(id), cfg, defaults)
      Map.put(acc, to_string(id), parsed)
    end)
    |> ensure_default_agent(defaults)
  end

  defp parse_agents(_, defaults), do: ensure_default_agent(%{}, defaults)

  defp ensure_default_agent(agents, defaults) when is_map(agents) do
    if Map.has_key?(agents, "default") do
      agents
    else
      Map.put(agents, "default", default_agent_profile("default", %{}, defaults))
    end
  end

  defp parse_agent_profile(id, cfg, defaults) do
    cfg = stringify_keys(cfg || %{})

    base = default_agent_profile(id, cfg, defaults)

    default_engine = cfg["default_engine"] || cfg["engine"] || base.default_engine

    tool_policy = parse_tool_policy(cfg["tool_policy"])

    base
    |> Map.put(:name, cfg["name"] || base.name || id)
    |> Map.put(:description, cfg["description"])
    |> Map.put(:avatar, cfg["avatar"])
    |> Map.put(:default_engine, default_engine)
    |> Map.put(:model, cfg["model"] || base.model)
    |> Map.put(:system_prompt, cfg["system_prompt"])
    |> Map.put(:tool_policy, tool_policy)
    |> Map.put(:rate_limit, cfg["rate_limit"])
    |> Map.put(:status, cfg["status"] || base.status || "active")
  end

  defp default_agent_profile(id, _cfg, defaults) do
    name =
      if id == "default" do
        "Default Agent"
      else
        id
      end

    default_model = if id == "default", do: defaults["model"], else: nil
    default_engine = if id == "default", do: defaults["engine"], else: nil

    %{
      id: id,
      name: name,
      description: nil,
      avatar: nil,
      default_engine: default_engine,
      model: default_model,
      system_prompt: nil,
      tool_policy: nil,
      rate_limit: nil,
      status: "active"
    }
  end

  defp parse_tool_policy(nil), do: nil

  defp parse_tool_policy(map) when is_map(map) do
    map = stringify_keys(map)

    allow =
      case map["allow"] do
        "all" -> :all
        :all -> :all
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> :all
      end

    deny =
      case map["deny"] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> []
      end

    require_approval =
      case map["require_approval"] do
        list when is_list(list) -> Enum.map(list, &to_string/1)
        other when is_binary(other) -> [other]
        _ -> []
      end

    approvals =
      case map["approvals"] do
        approvals when is_map(approvals) ->
          approvals
          |> stringify_keys()
          |> Enum.reduce(%{}, fn {tool_name, mode}, acc ->
            mode =
              case mode do
                :always -> :always
                "always" -> :always
                true -> :always
                :never -> :never
                "never" -> :never
                false -> :never
                _ -> nil
              end

            if mode do
              Map.put(acc, tool_name, mode)
            else
              acc
            end
          end)

        _ ->
          %{}
      end

    profile =
      case map["profile"] do
        "full_access" -> :full_access
        "minimal_core" -> :minimal_core
        "read_only" -> :read_only
        "safe_mode" -> :safe_mode
        "subagent_restricted" -> :subagent_restricted
        "no_external" -> :no_external
        "custom" -> :custom
        _ -> nil
      end

    %{
      allow: allow,
      deny: deny,
      require_approval: require_approval,
      approvals: approvals,
      no_reply: parse_boolean(map["no_reply"], false),
      profile: profile
    }
  end

  defp parse_tool_policy(_), do: nil

  defp parse_compaction(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], true),
      reserve_tokens: map["reserve_tokens"] || 16_384,
      keep_recent_tokens: map["keep_recent_tokens"] || 20_000
    }
  end

  defp parse_retry(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], true),
      max_retries: map["max_retries"] || 3,
      base_delay_ms: map["base_delay_ms"] || 1000
    }
  end

  defp parse_shell(map) do
    map = stringify_keys(map)

    %{
      path: map["path"],
      command_prefix: map["command_prefix"]
    }
  end

  defp parse_tools(map) do
    map = stringify_keys(map)

    %{
      auto_resize_images: parse_boolean(map["auto_resize_images"], true),
      web: parse_web_tools(map["web"] || %{}),
      wasm: parse_wasm_tools(map["wasm"] || %{})
    }
  end

  defp parse_wasm_tools(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], false),
      auto_build: parse_boolean(map["auto_build"], true),
      runtime_path: normalize_optional_string(map["runtime_path"]),
      tool_paths: parse_string_list(map["tool_paths"]),
      default_memory_limit: parse_positive_integer(map["default_memory_limit"], 10_485_760),
      default_timeout_ms: parse_positive_integer(map["default_timeout_ms"], 60_000),
      default_fuel_limit: parse_positive_integer(map["default_fuel_limit"], 10_000_000),
      cache_compiled: parse_boolean(map["cache_compiled"], true),
      cache_dir: normalize_optional_string(map["cache_dir"]),
      max_tool_invoke_depth: parse_positive_integer(map["max_tool_invoke_depth"], 4)
    }
  end

  defp parse_web_tools(map) do
    map = stringify_keys(map)

    %{
      search: parse_web_search_config(map["search"] || %{}),
      fetch: parse_web_fetch_config(map["fetch"] || %{}),
      cache: parse_web_cache_config(map["cache"] || %{})
    }
  end

  defp parse_web_search_config(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], true),
      provider: normalize_web_search_provider(map["provider"]),
      api_key: normalize_optional_string(map["api_key"]),
      max_results: parse_positive_integer(map["max_results"], 5),
      timeout_seconds: parse_positive_integer(map["timeout_seconds"], 30),
      cache_ttl_minutes: parse_non_negative_number(map["cache_ttl_minutes"], 15),
      failover: parse_web_search_failover_config(map["failover"] || %{}),
      perplexity: parse_perplexity_config(map["perplexity"] || %{})
    }
  end

  defp parse_web_search_failover_config(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], true),
      provider:
        normalize_optional_web_search_provider(
          normalize_optional_string(map["provider"] || map["secondary_provider"])
        )
    }
  end

  defp parse_web_cache_config(map) do
    map = stringify_keys(map)

    %{
      persistent: parse_boolean(map["persistent"], true),
      path: normalize_optional_string(map["path"]),
      max_entries: parse_positive_integer(map["max_entries"], 100)
    }
  end

  defp parse_perplexity_config(map) do
    map = stringify_keys(map)

    %{
      api_key: normalize_optional_string(map["api_key"]),
      base_url: normalize_optional_string(map["base_url"]),
      model: normalize_optional_string(map["model"]) || "perplexity/sonar-pro"
    }
  end

  defp parse_web_fetch_config(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], true),
      max_chars: parse_positive_integer(map["max_chars"], 50_000),
      timeout_seconds: parse_positive_integer(map["timeout_seconds"], 30),
      cache_ttl_minutes: parse_non_negative_number(map["cache_ttl_minutes"], 15),
      max_redirects: parse_non_negative_integer(map["max_redirects"], 3),
      user_agent:
        normalize_optional_string(map["user_agent"]) ||
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
      readability: parse_boolean(map["readability"], true),
      allow_private_network: parse_boolean(map["allow_private_network"], false),
      allowed_hostnames: parse_string_list(map["allowed_hostnames"]),
      firecrawl: parse_firecrawl_config(map["firecrawl"] || %{})
    }
  end

  defp parse_firecrawl_config(map) do
    map = stringify_keys(map)

    %{
      enabled: parse_boolean(map["enabled"], nil),
      api_key: normalize_optional_string(map["api_key"]),
      base_url: normalize_optional_string(map["base_url"]) || "https://api.firecrawl.dev",
      only_main_content: parse_boolean(map["only_main_content"], true),
      max_age_ms: parse_non_negative_integer(map["max_age_ms"], 172_800_000),
      timeout_seconds: parse_positive_integer(map["timeout_seconds"], 60)
    }
  end

  defp parse_cli(map) do
    map = stringify_keys(map)

    %{
      codex: parse_codex_cli(map["codex"] || %{}),
      kimi: parse_kimi_cli(map["kimi"] || %{}),
      opencode: parse_opencode_cli(map["opencode"] || %{}),
      pi: parse_pi_cli(map["pi"] || %{}),
      claude: parse_claude_cli(map["claude"] || %{})
    }
  end

  defp parse_codex_cli(map) do
    map = stringify_keys(map)

    %{
      extra_args: parse_string_list(map["extra_args"]),
      auto_approve: parse_boolean(map["auto_approve"], false)
    }
  end

  defp parse_kimi_cli(map) do
    map = stringify_keys(map)

    %{
      extra_args: parse_string_list(map["extra_args"])
    }
  end

  defp parse_opencode_cli(map) do
    map = stringify_keys(map)

    model =
      case map["model"] do
        v when is_binary(v) ->
          v = String.trim(v)
          if v == "", do: nil, else: v

        _ ->
          nil
      end

    %{model: model}
  end

  defp parse_pi_cli(map) do
    map = stringify_keys(map)

    model =
      case map["model"] do
        v when is_binary(v) ->
          v = String.trim(v)
          if v == "", do: nil, else: v

        _ ->
          nil
      end

    provider =
      case map["provider"] do
        v when is_binary(v) ->
          v = String.trim(v)
          if v == "", do: nil, else: v

        _ ->
          nil
      end

    %{
      extra_args: parse_string_list(map["extra_args"]),
      model: model,
      provider: provider
    }
  end

  defp parse_claude_cli(map) do
    map = stringify_keys(map)

    %{
      dangerously_skip_permissions: parse_boolean(map["dangerously_skip_permissions"], true),
      yolo: parse_boolean(map["yolo"], nil),
      allowed_tools: parse_string_list(map["allowed_tools"]),
      scrub_env: normalize_scrub_env(map["scrub_env"]),
      env_allowlist: parse_string_list(map["env_allowlist"]),
      env_allow_prefixes: parse_string_list(map["env_allow_prefixes"]),
      env_overrides: normalize_env_overrides(map["env_overrides"])
    }
  end

  # ============================================================================
  # Overrides
  # ============================================================================

  defp apply_overrides(config, nil), do: config

  defp apply_overrides(%__MODULE__{} = config, overrides) when is_map(overrides) do
    overrides = stringify_keys(overrides)
    merged = deep_merge(stringify_keys(to_map(config)), overrides)
    from_map(merged)
  end

  defp apply_env_overrides(%__MODULE__{} = config) do
    config
    |> apply_env_provider_overrides()
    |> apply_env_agent_overrides()
    |> apply_env_tui_overrides()
    |> apply_env_logging_overrides()
  end

  defp apply_env_agent_overrides(%__MODULE__{} = config) do
    agent = config.agent

    agent =
      agent
      |> maybe_put("default_provider", System.get_env("LEMON_DEFAULT_PROVIDER"))
      |> maybe_put("default_model", System.get_env("LEMON_DEFAULT_MODEL"))

    agent =
      case System.get_env("LEMON_CODEX_EXTRA_ARGS") do
        nil ->
          agent

        "" ->
          agent

        raw ->
          put_in(agent, [:cli, :codex, :extra_args], String.split(raw, ~r/\s+/, trim: true))
      end

    agent =
      case System.get_env("LEMON_CODEX_AUTO_APPROVE") do
        nil -> agent
        value -> put_in(agent, [:cli, :codex, :auto_approve], parse_boolean(value, false))
      end

    agent =
      case System.get_env("LEMON_CLAUDE_YOLO") do
        nil ->
          agent

        value ->
          put_in(
            agent,
            [:cli, :claude, :dangerously_skip_permissions],
            parse_boolean(value, true)
          )
      end

    agent =
      case System.get_env("LEMON_WASM_ENABLED") do
        nil -> agent
        value -> put_in(agent, [:tools, :wasm, :enabled], parse_boolean(value, false))
      end

    agent =
      case normalize_optional_string(System.get_env("LEMON_WASM_RUNTIME_PATH")) do
        nil -> agent
        runtime_path -> put_in(agent, [:tools, :wasm, :runtime_path], runtime_path)
      end

    agent =
      case System.get_env("LEMON_WASM_TOOL_PATHS") do
        nil -> agent
        paths -> put_in(agent, [:tools, :wasm, :tool_paths], parse_string_list(paths))
      end

    agent =
      case System.get_env("LEMON_WASM_AUTO_BUILD") do
        nil -> agent
        value -> put_in(agent, [:tools, :wasm, :auto_build], parse_boolean(value, true))
      end

    %{config | agent: agent}
  end

  defp apply_env_tui_overrides(%__MODULE__{} = config) do
    tui = config.tui

    tui =
      tui
      |> maybe_put("theme", System.get_env("LEMON_THEME"))

    tui =
      case System.get_env("LEMON_DEBUG") do
        nil -> tui
        value -> Map.put(tui, :debug, parse_boolean(value, false))
      end

    %{config | tui: tui}
  end

  defp apply_env_provider_overrides(%__MODULE__{} = config) do
    providers =
      config.providers
      |> put_provider_env_override("anthropic",
        api_key: env_first(["ANTHROPIC_API_KEY"]),
        base_url: env_first(["ANTHROPIC_BASE_URL"])
      )
      |> put_provider_env_override("openai",
        api_key: env_first(["OPENAI_API_KEY"]),
        base_url: env_first(["OPENAI_BASE_URL"])
      )
      |> put_provider_env_override("openai-codex",
        api_key: env_first(["OPENAI_CODEX_API_KEY", "CHATGPT_TOKEN"]),
        base_url: env_first(["OPENAI_BASE_URL"])
      )
      |> put_provider_env_override("opencode",
        api_key: env_first(["OPENCODE_API_KEY"]),
        base_url: env_first(["OPENCODE_BASE_URL"])
      )
      |> put_provider_env_override("kimi",
        api_key: env_first(["KIMI_API_KEY"]),
        base_url: env_first(["KIMI_BASE_URL"])
      )
      |> put_provider_env_override("google",
        api_key: env_first(["GOOGLE_GENERATIVE_AI_API_KEY", "GOOGLE_API_KEY", "GEMINI_API_KEY"]),
        base_url: env_first(["GOOGLE_BASE_URL"])
      )

    %{config | providers: providers}
  end

  defp apply_env_logging_overrides(%__MODULE__{} = config) do
    logging = config.logging

    logging =
      logging
      |> maybe_put("file", System.get_env("LEMON_LOG_FILE"))

    logging =
      case System.get_env("LEMON_LOG_LEVEL") do
        nil -> logging
        "" -> logging
        level -> Map.put(logging, :level, parse_log_level(level))
      end

    %{config | logging: logging}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp parse_thinking_level(nil), do: :medium
  defp parse_thinking_level("off"), do: :off
  defp parse_thinking_level("minimal"), do: :minimal
  defp parse_thinking_level("low"), do: :low
  defp parse_thinking_level("medium"), do: :medium
  defp parse_thinking_level("high"), do: :high
  defp parse_thinking_level("xhigh"), do: :xhigh
  defp parse_thinking_level(level) when is_atom(level), do: level
  defp parse_thinking_level(_), do: :medium

  defp parse_boolean(nil, default), do: default
  defp parse_boolean(true, _default), do: true
  defp parse_boolean(false, _default), do: false
  defp parse_boolean("true", _default), do: true
  defp parse_boolean("false", _default), do: false
  defp parse_boolean("1", _default), do: true
  defp parse_boolean("0", _default), do: false
  defp parse_boolean(_, default), do: default

  defp parse_log_level(nil), do: nil
  defp parse_log_level(level) when is_atom(level), do: level

  defp parse_log_level(level) when is_binary(level) do
    case String.downcase(String.trim(level)) do
      "debug" -> :debug
      "info" -> :info
      "notice" -> :notice
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      "critical" -> :critical
      "alert" -> :alert
      "emergency" -> :emergency
      _ -> nil
    end
  end

  defp parse_log_level(_), do: nil

  defp parse_string_list(nil), do: []
  defp parse_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)

  defp parse_string_list(value) when is_binary(value),
    do: String.split(value, ~r/\s*,\s*/, trim: true)

  defp parse_string_list(_), do: []

  defp parse_optional_string(nil), do: nil

  defp parse_optional_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp parse_optional_string(_), do: nil

  defp parse_positive_integer(value, _default) when is_integer(value), do: max(value, 1)

  defp parse_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 1)
      _ -> default
    end
  end

  defp parse_positive_integer(_value, default), do: default

  defp parse_non_negative_integer(value, _default) when is_integer(value), do: max(value, 0)

  defp parse_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 0)
      _ -> default
    end
  end

  defp parse_non_negative_integer(_value, default), do: default

  defp parse_non_negative_number(value, _default) when is_number(value), do: max(value, 0)

  defp parse_non_negative_number(value, default) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {parsed, ""} -> max(parsed, 0)
      _ -> default
    end
  end

  defp parse_non_negative_number(_value, default), do: default

  defp normalize_optional_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_optional_string(_), do: nil

  defp normalize_web_search_provider(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "perplexity" -> "perplexity"
      "brave" -> "brave"
      _ -> "brave"
    end
  end

  defp normalize_web_search_provider(_), do: "brave"

  defp normalize_optional_web_search_provider(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      "perplexity" -> "perplexity"
      "brave" -> "brave"
      _ -> nil
    end
  end

  defp normalize_optional_web_search_provider(_), do: nil

  defp normalize_env_overrides(nil), do: %{}
  defp normalize_env_overrides(env) when is_map(env), do: env
  defp normalize_env_overrides(env) when is_list(env), do: Map.new(env)
  defp normalize_env_overrides(_), do: %{}

  defp normalize_scrub_env(nil), do: :auto
  defp normalize_scrub_env(:auto), do: :auto
  defp normalize_scrub_env("auto"), do: :auto
  defp normalize_scrub_env(true), do: true
  defp normalize_scrub_env(false), do: false
  defp normalize_scrub_env("true"), do: true
  defp normalize_scrub_env("false"), do: false
  defp normalize_scrub_env(_), do: :auto

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

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), stringify_keys(v)} end)
    |> Map.new()
  end

  defp stringify_keys(list) when is_list(list) do
    Enum.map(list, &stringify_keys/1)
  end

  defp stringify_keys(value), do: value

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map

  defp maybe_put(map, key, value) when is_binary(key),
    do: Map.put(map, String.to_atom(key), value)

  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, key, value) when is_binary(key), do: Map.put(map, key, value)

  defp ensure_map(map) when is_map(map), do: stringify_keys(map)
  defp ensure_map(_), do: %{}

  defp put_provider_env_override(providers, name, api_key: api_key, base_url: base_url) do
    if api_key || base_url do
      existing = Map.get(providers, name, %{})
      merged = existing |> Map.merge(reject_nil_values(%{api_key: api_key, base_url: base_url}))
      Map.put(providers, name, merged)
    else
      providers
    end
  end

  defp env_first(names) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp get_in_config(map, key, default) when is_atom(key) do
    Map.get(map, key, default)
  end

  defp get_in_config(map, [key], default), do: get_in_config(map, key, default)

  defp get_in_config(map, [key | rest], default) when is_map(map) do
    case Map.get(map, key) do
      nil -> default
      nested -> get_in_config(nested, rest, default)
    end
  end
end
