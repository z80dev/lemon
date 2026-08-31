defmodule LemonCore.Config.Tools do
  @moduledoc """
  Tools configuration for web search, fetch, and WASM tools.

  Inspired by Ironclaw's modular config pattern, this module handles
  tool-specific configuration including web search providers,
  fetch settings, and WASM runtime configuration.

  ## Configuration

  Configuration is loaded from the TOML config file under `[runtime.tools]`:

      [runtime.tools]
      auto_resize_images = true

      [runtime.tools.web.search]
      enabled = true
      provider = "brave"
      max_results = 5
      timeout_seconds = 30

      [runtime.tools.web.fetch]
      enabled = true
      max_chars = 50000
      readability = true

      [runtime.tools.wasm]
      enabled = false
      auto_build = true
      default_memory_limit = 10485760

      [runtime.tools.execute_code]
      enabled = false
      timeout_ms = 120000
      kernel_mode = "per_call"
      kernel_idle_timeout_ms = 1800000
      max_live_kernels = 16
      max_queued_cells_per_kernel = 8

      # Hide the MCP/extension/WASM long tail behind tool_search/tool_invoke
      # once the catalog's estimated schema cost exceeds budget_tokens.
      [runtime.tools.disclosure]
      enabled = true
      budget_tokens = 40000
      catalog_tokens = 2000
      max_results = 5

  Environment variables override file configuration:
  - `LEMON_WEB_SEARCH_ENABLED`, `LEMON_WEB_SEARCH_PROVIDER`
  - `LEMON_WEB_FETCH_ENABLED`, `LEMON_WEB_FETCH_MAX_CHARS`
  - `LEMON_WASM_ENABLED`, `LEMON_WASM_AUTO_BUILD`
  - `LEMON_EXECUTE_CODE_ENABLED`, `LEMON_EXECUTE_CODE_TIMEOUT_MS`,
    `LEMON_EXECUTE_CODE_KERNEL_MODE`, `LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS`,
    `LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS`, `LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL`,
    `LEMON_EXECUTE_CODE_MAX_TEXT_BYTES`, `LEMON_EXECUTE_CODE_MAX_PARALLEL_RPC`
  - `LEMON_TOOL_DISCLOSURE_ENABLED`, `LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS`,
    `LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS`

  `[runtime.tools.*]` is the only spelling a config file may use:
  `LemonCore.Config.Modular.normalize_tools_settings/1` maps `runtime.tools` onto the
  top-level `tools` settings this module resolves, while the legacy `[tools]` and
  `[agent.tools]` spellings are rejected by validation with a
  `LemonCore.Config.ValidationError`. The resolver itself still reads the normalized
  top-level `tools` key, which is why `resolve/1` is called with `%{"tools" => ...}`.
  """

  alias LemonCore.Env

  defstruct [
    :auto_resize_images,
    :web,
    :wasm,
    :execute_code,
    :disclosure
  ]

  @type web_search_config :: %{
          enabled: boolean(),
          provider: String.t(),
          api_key: String.t() | nil,
          max_results: integer(),
          timeout_seconds: integer(),
          cache_ttl_minutes: integer(),
          failover: %{
            enabled: boolean(),
            provider: String.t() | nil
          },
          perplexity: %{
            api_key: String.t() | nil,
            base_url: String.t() | nil,
            model: String.t()
          }
        }

  @type web_fetch_config :: %{
          enabled: boolean(),
          max_chars: integer(),
          timeout_seconds: integer(),
          cache_ttl_minutes: integer(),
          max_redirects: integer(),
          user_agent: String.t(),
          readability: boolean(),
          allow_private_network: boolean(),
          allowed_hostnames: [String.t()],
          firecrawl: %{
            enabled: boolean() | nil,
            api_key: String.t() | nil,
            base_url: String.t(),
            only_main_content: boolean(),
            max_age_ms: integer(),
            timeout_seconds: integer()
          }
        }

  @type web_cache_config :: %{
          persistent: boolean(),
          path: String.t() | nil,
          max_entries: integer()
        }

  @type wasm_config :: %{
          enabled: boolean(),
          auto_build: boolean(),
          runtime_path: String.t(),
          tool_paths: [String.t()],
          default_memory_limit: integer(),
          default_timeout_ms: integer(),
          default_fuel_limit: integer(),
          cache_compiled: boolean(),
          cache_dir: String.t(),
          max_tool_invoke_depth: integer()
        }

  @type execute_code_config :: %{
          enabled: boolean(),
          python_path: String.t(),
          timeout_ms: integer(),
          max_rpc_calls: integer(),
          max_rpc_result_bytes: integer(),
          max_output_bytes: integer(),
          max_text_bytes: pos_integer(),
          max_parallel_rpc: pos_integer(),
          tools: [String.t()],
          kernel_mode: String.t(),
          kernel_idle_timeout_ms: pos_integer(),
          max_live_kernels: pos_integer(),
          max_queued_cells_per_kernel: pos_integer()
        }

  @type disclosure_config :: %{
          enabled: boolean(),
          budget_tokens: pos_integer(),
          catalog_tokens: pos_integer(),
          max_results: pos_integer()
        }

  @type t :: %__MODULE__{
          auto_resize_images: boolean(),
          web: %{
            search: web_search_config(),
            fetch: web_fetch_config(),
            cache: web_cache_config()
          },
          wasm: wasm_config(),
          execute_code: execute_code_config(),
          disclosure: disclosure_config()
        }

  @doc """
  Resolves tools configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    tools_settings = settings["tools"] || %{}

    %__MODULE__{
      auto_resize_images: resolve_auto_resize(tools_settings),
      web: resolve_web(tools_settings),
      wasm: resolve_wasm(tools_settings),
      execute_code: resolve_execute_code(tools_settings),
      disclosure: resolve_disclosure(tools_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_auto_resize(settings) do
    Env.get(:lemon_auto_resize_images,
      default:
        if(is_nil(settings["auto_resize_images"]), do: true, else: settings["auto_resize_images"])
    )
  end

  defp resolve_web(settings) do
    web = settings["web"] || %{}

    %{
      search: resolve_web_search(web),
      fetch: resolve_web_fetch(web),
      cache: resolve_web_cache(web)
    }
  end

  defp resolve_web_search(web) do
    search = web["search"] || %{}

    %{
      enabled:
        Env.get(:lemon_web_search_enabled,
          default: if(is_nil(search["enabled"]), do: true, else: search["enabled"])
        ),
      provider: Env.get(:lemon_web_search_provider, default: search["provider"] || "brave"),
      api_key: Env.get(:lemon_web_search_api_key, default: search["api_key"]),
      max_results: Env.get(:lemon_web_search_max_results, default: search["max_results"] || 5),
      timeout_seconds:
        Env.get(:lemon_web_search_timeout, default: search["timeout_seconds"] || 30),
      cache_ttl_minutes:
        Env.get(:lemon_web_search_cache_ttl, default: search["cache_ttl_minutes"] || 15),
      api_key_secret: normalize_optional_string(search["api_key_secret"]),
      providers: ensure_map(search["providers"]),
      failover: resolve_search_failover(search),
      perplexity: resolve_perplexity(search)
    }
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp resolve_search_failover(search) do
    failover = search["failover"] || %{}

    %{
      enabled:
        Env.get(:lemon_web_search_failover_enabled,
          default: if(is_nil(failover["enabled"]), do: true, else: failover["enabled"])
        ),
      provider: Env.get(:lemon_web_search_failover_provider, default: failover["provider"])
    }
  end

  defp resolve_perplexity(search) do
    perplexity = search["perplexity"] || %{}

    %{
      api_key: Env.get(:lemon_perplexity_api_key, default: perplexity["api_key"]),
      api_key_secret: normalize_optional_string(perplexity["api_key_secret"]),
      base_url: Env.get(:lemon_perplexity_base_url, default: perplexity["base_url"]),
      model:
        Env.get(:lemon_perplexity_model, default: perplexity["model"] || "perplexity/sonar-pro")
    }
  end

  defp resolve_web_fetch(web) do
    fetch = web["fetch"] || %{}

    %{
      enabled:
        Env.get(:lemon_web_fetch_enabled,
          default: if(is_nil(fetch["enabled"]), do: true, else: fetch["enabled"])
        ),
      max_chars: Env.get(:lemon_web_fetch_max_chars, default: fetch["max_chars"] || 50_000),
      timeout_seconds: Env.get(:lemon_web_fetch_timeout, default: fetch["timeout_seconds"] || 30),
      cache_ttl_minutes:
        Env.get(:lemon_web_fetch_cache_ttl, default: fetch["cache_ttl_minutes"] || 15),
      max_redirects:
        Env.get(:lemon_web_fetch_max_redirects, default: fetch["max_redirects"] || 3),
      user_agent:
        Env.get(:lemon_web_fetch_user_agent,
          default:
            fetch["user_agent"] ||
              "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        ),
      readability:
        Env.get(:lemon_web_fetch_readability,
          default: if(is_nil(fetch["readability"]), do: true, else: fetch["readability"])
        ),
      allow_private_network:
        Env.get(:lemon_web_fetch_allow_private_network,
          default:
            if(is_nil(fetch["allow_private_network"]),
              do: false,
              else: fetch["allow_private_network"]
            )
        ),
      allowed_hostnames: resolve_allowed_hostnames(fetch),
      providers: ensure_map(fetch["providers"]),
      firecrawl: resolve_firecrawl(fetch)
    }
  end

  defp resolve_allowed_hostnames(fetch) do
    # Note: intentionally not `Env.get/2` -- see the comment on
    # `LemonCore.Config.Agent.resolve_extension_paths/1` for why a list var
    # whose "empty after parsing" fallback must key off the parsed list, not
    # the raw string, stays on the explicit `Env.list/1` + if/else form.
    env_hostnames = Env.list("LEMON_WEB_FETCH_ALLOWED_HOSTNAMES")

    if env_hostnames != [] do
      env_hostnames
    else
      fetch["allowed_hostnames"] || []
    end
  end

  defp resolve_firecrawl(fetch) do
    firecrawl = fetch["firecrawl"] || %{}

    enabled_val = firecrawl["enabled"]

    %{
      # Note: intentionally not `Env.get/2` -- unlike every other boolean
      # here, this one preserves a genuine `nil` ("undecided") state distinct
      # from `true`/`false`, and only recognizes "true"/"1"/"yes" and
      # "false"/"0"/"no" (not the "on"/"off" spellings `Env.get/2`'s standard
      # :boolean cast accepts). `Env.get/2` would always coerce to a concrete
      # boolean and use the wider token set, which is a real behavior change.
      enabled:
        if(is_nil(enabled_val), do: nil, else: enabled_val)
        |> then(fn val ->
          env_val = Env.string("LEMON_FIRECRAWL_ENABLED")

          cond do
            is_nil(env_val) -> val
            env_val in ["true", "1", "yes"] -> true
            env_val in ["false", "0", "no"] -> false
            true -> val
          end
        end),
      api_key: Env.get(:lemon_firecrawl_api_key, default: firecrawl["api_key"]),
      api_key_secret: normalize_optional_string(firecrawl["api_key_secret"]),
      base_url:
        Env.get(:lemon_firecrawl_base_url,
          default: firecrawl["base_url"] || "https://api.firecrawl.dev"
        ),
      only_main_content:
        if(is_nil(firecrawl["only_main_content"]),
          do: true,
          else: firecrawl["only_main_content"]
        ),
      max_age_ms: firecrawl["max_age_ms"] || 172_800_000,
      timeout_seconds: firecrawl["timeout_seconds"] || 60
    }
  end

  defp resolve_web_cache(web) do
    cache = web["cache"] || %{}

    %{
      persistent:
        Env.get(:lemon_web_cache_persistent,
          default: if(is_nil(cache["persistent"]), do: true, else: cache["persistent"])
        ),
      path: Env.get(:lemon_web_cache_path, default: cache["path"]),
      max_entries: Env.get(:lemon_web_cache_max_entries, default: cache["max_entries"] || 100)
    }
  end

  defp resolve_wasm(settings) do
    wasm = settings["wasm"] || %{}

    %{
      enabled:
        Env.get(:lemon_wasm_enabled,
          default: if(is_nil(wasm["enabled"]), do: false, else: wasm["enabled"])
        ),
      auto_build:
        Env.get(:lemon_wasm_auto_build,
          default: if(is_nil(wasm["auto_build"]), do: true, else: wasm["auto_build"])
        ),
      runtime_path: Env.get(:lemon_wasm_runtime_path, default: wasm["runtime_path"] || ""),
      tool_paths: resolve_wasm_tool_paths(wasm),
      default_memory_limit:
        Env.get(:lemon_wasm_default_memory_limit,
          default: wasm["default_memory_limit"] || 10_485_760
        ),
      default_timeout_ms:
        Env.get(:lemon_wasm_default_timeout_ms, default: wasm["default_timeout_ms"] || 60_000),
      default_fuel_limit:
        Env.get(:lemon_wasm_default_fuel_limit,
          default: wasm["default_fuel_limit"] || 10_000_000
        ),
      cache_compiled:
        Env.get(:lemon_wasm_cache_compiled,
          default: if(is_nil(wasm["cache_compiled"]), do: true, else: wasm["cache_compiled"])
        ),
      cache_dir: Env.get(:lemon_wasm_cache_dir, default: wasm["cache_dir"] || ""),
      max_tool_invoke_depth:
        Env.get(:lemon_wasm_max_tool_invoke_depth,
          default: wasm["max_tool_invoke_depth"] || 4
        )
    }
  end

  defp resolve_wasm_tool_paths(wasm) do
    # Note: intentionally not `Env.get/2` -- see the comment on
    # `LemonCore.Config.Agent.resolve_extension_paths/1`.
    env_paths = Env.list("LEMON_WASM_TOOL_PATHS")

    if env_paths != [] do
      env_paths
    else
      wasm["tool_paths"] || []
    end
  end

  # Programmatic tool calling (`execute_code`): a per-tool runtime capability
  # gated exactly like `[runtime.tools.wasm]`, default-off because the script
  # runs arbitrary code with host permissions. `tools` narrows the RPC
  # allowlist the generated python shim exposes; `[]` means "the full
  # allowlist" and the coding_agent-side loader resolves it. The `kernel_*`
  # settings configure the optional persistent-interpreter mode:
  # `kernel_mode = "session"` keeps Python state across calls while
  # `"per_call"` (the default) keeps today's fresh-process behavior, and the
  # three bounds cap idle reaping, concurrent live kernels, and queued cells
  # per kernel.
  defp resolve_execute_code(settings) do
    ec = settings["execute_code"] || %{}

    %{
      enabled:
        Env.get(:lemon_execute_code_enabled,
          default: if(is_nil(ec["enabled"]), do: false, else: ec["enabled"])
        ),
      python_path: Env.get(:lemon_execute_code_python_path, default: ec["python_path"] || ""),
      timeout_ms: Env.get(:lemon_execute_code_timeout_ms, default: ec["timeout_ms"] || 120_000),
      max_rpc_calls:
        Env.get(:lemon_execute_code_max_rpc_calls, default: ec["max_rpc_calls"] || 100),
      max_rpc_result_bytes:
        Env.get(:lemon_execute_code_max_rpc_result_bytes,
          default: ec["max_rpc_result_bytes"] || 5_242_880
        ),
      max_output_bytes:
        Env.get(:lemon_execute_code_max_output_bytes, default: ec["max_output_bytes"] || 50_000),
      max_text_bytes:
        resolve_execute_code_bound(
          "LEMON_EXECUTE_CODE_MAX_TEXT_BYTES",
          ec["max_text_bytes"],
          65_536
        ),
      max_parallel_rpc:
        resolve_execute_code_bound(
          "LEMON_EXECUTE_CODE_MAX_PARALLEL_RPC",
          ec["max_parallel_rpc"],
          4
        ),
      tools: resolve_execute_code_tools(ec),
      kernel_mode: resolve_execute_code_kernel_mode(ec),
      kernel_idle_timeout_ms:
        resolve_execute_code_bound(
          "LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS",
          ec["kernel_idle_timeout_ms"],
          1_800_000
        ),
      max_live_kernels:
        resolve_execute_code_bound(
          "LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS",
          ec["max_live_kernels"],
          16
        ),
      max_queued_cells_per_kernel:
        resolve_execute_code_bound(
          "LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL",
          ec["max_queued_cells_per_kernel"],
          8
        )
    }
  end

  defp resolve_execute_code_tools(ec) do
    # Note: intentionally not `Env.get/2` -- see the comment on
    # `LemonCore.Config.Agent.resolve_extension_paths/1`.
    env_tools = Env.list("LEMON_EXECUTE_CODE_TOOLS")

    if env_tools != [] do
      env_tools
    else
      ec["tools"] || []
    end
  end

  # Only the exact spellings "per_call"/"session" (after trimming) select a
  # mode. Anything else fails closed to "per_call": a malformed env override
  # never defers to a lower-precedence source, so persistence can only ever
  # be enabled by an unambiguous valid value. Like `LEMON_EXECUTE_CODE_TOOLS`
  # above, this is a raw (undeclared) env read.
  defp resolve_execute_code_kernel_mode(ec) do
    raw = Env.string("LEMON_EXECUTE_CODE_KERNEL_MODE") || ec["kernel_mode"]

    normalize_execute_code_kernel_mode(raw) || "per_call"
  end

  defp normalize_execute_code_kernel_mode(mode) when is_binary(mode) do
    case String.trim(mode) do
      "per_call" -> "per_call"
      "session" -> "session"
      _ -> nil
    end
  end

  defp normalize_execute_code_kernel_mode(_), do: nil

  # Kernel bounds must stay positive integers: a zero/negative/garbage value
  # would read downstream as "no limit" or "reap immediately", so an invalid
  # value at one precedence level is skipped and the next valid level (env >
  # TOML > hardcoded default) wins instead.
  defp resolve_execute_code_bound(env_var, toml_value, default) do
    # Raw (undeclared) typed read; `Env.int/1` yields 0 (an invalid bound)
    # when unset, empty, or unparseable.
    env_value = Env.int(env_var)

    cond do
      positive_int?(env_value) -> env_value
      positive_int?(toml_value) -> toml_value
      true -> default
    end
  end

  defp positive_int?(value) when is_integer(value) and value > 0, do: true
  defp positive_int?(_), do: false

  # Progressive tool-schema disclosure: once the resolved catalog's schema cost
  # exceeds `budget_tokens`, `CodingAgent.ToolDisclosure` hides the
  # MCP/extension/WASM long tail behind a `tool_search` / `tool_invoke` bridge
  # pair while built-in tools stay fully disclosed. `enabled` defaults to true
  # because the budget is the real gate: the built-in set is far under it, so a
  # setup without a large MCP catalog never activates disclosure and sees no
  # change at all. `enabled = false` is the kill switch for setups that would
  # otherwise activate it.
  defp resolve_disclosure(settings) do
    disclosure = settings["disclosure"] || %{}

    %{
      enabled:
        Env.get(:lemon_tool_disclosure_enabled,
          default: if(is_nil(disclosure["enabled"]), do: true, else: disclosure["enabled"])
        ),
      budget_tokens:
        Env.get(:lemon_tool_disclosure_budget_tokens,
          default: disclosure["budget_tokens"] || 40_000
        ),
      catalog_tokens:
        Env.get(:lemon_tool_disclosure_catalog_tokens,
          default: disclosure["catalog_tokens"] || 2_000
        ),
      max_results: disclosure["max_results"] || 5
    }
  end

  @doc """
  Returns the default tools configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
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
      },
      "execute_code" => %{
        "enabled" => false,
        "python_path" => "",
        "timeout_ms" => 120_000,
        "max_rpc_calls" => 100,
        "max_rpc_result_bytes" => 5_242_880,
        "max_output_bytes" => 50_000,
        "tools" => [],
        "kernel_mode" => "per_call",
        "kernel_idle_timeout_ms" => 1_800_000,
        "max_live_kernels" => 16,
        "max_text_bytes" => 65_536,
        "max_parallel_rpc" => 4,
        "max_queued_cells_per_kernel" => 8
      },
      "disclosure" => %{
        "enabled" => true,
        "budget_tokens" => 40_000,
        "catalog_tokens" => 2_000,
        "max_results" => 5
      }
    }
  end
end
