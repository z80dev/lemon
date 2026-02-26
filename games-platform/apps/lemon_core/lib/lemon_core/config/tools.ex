defmodule LemonCore.Config.Tools do
  @moduledoc """
  Tools configuration for web search, fetch, and WASM tools.

  Inspired by Ironclaw's modular config pattern, this module handles
  tool-specific configuration including web search providers,
  fetch settings, and WASM runtime configuration.

  ## Configuration

  Configuration is loaded from the TOML config file under `[agent.tools]`:

      [agent.tools]
      auto_resize_images = true

      [agent.tools.web.search]
      enabled = true
      provider = "brave"
      max_results = 5
      timeout_seconds = 30

      [agent.tools.web.fetch]
      enabled = true
      max_chars = 50000
      readability = true

      [agent.tools.wasm]
      enabled = false
      auto_build = true
      default_memory_limit = 10485760

  Environment variables override file configuration:
  - `LEMON_WEB_SEARCH_ENABLED`, `LEMON_WEB_SEARCH_PROVIDER`
  - `LEMON_WEB_FETCH_ENABLED`, `LEMON_WEB_FETCH_MAX_CHARS`
  - `LEMON_WASM_ENABLED`, `LEMON_WASM_AUTO_BUILD`
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :auto_resize_images,
    :web,
    :wasm
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

  @type t :: %__MODULE__{
          auto_resize_images: boolean(),
          web: %{
            search: web_search_config(),
            fetch: web_fetch_config(),
            cache: web_cache_config()
          },
          wasm: wasm_config()
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
      wasm: resolve_wasm(tools_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_auto_resize(settings) do
    Helpers.get_env_bool(
      "LEMON_AUTO_RESIZE_IMAGES",
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
        Helpers.get_env_bool(
          "LEMON_WEB_SEARCH_ENABLED",
          if(is_nil(search["enabled"]), do: true, else: search["enabled"])
        ),
      provider: Helpers.get_env("LEMON_WEB_SEARCH_PROVIDER", search["provider"] || "brave"),
      api_key: Helpers.get_env("LEMON_WEB_SEARCH_API_KEY", search["api_key"]),
      max_results:
        Helpers.get_env_int("LEMON_WEB_SEARCH_MAX_RESULTS", search["max_results"] || 5),
      timeout_seconds:
        Helpers.get_env_int("LEMON_WEB_SEARCH_TIMEOUT", search["timeout_seconds"] || 30),
      cache_ttl_minutes:
        Helpers.get_env_int(
          "LEMON_WEB_SEARCH_CACHE_TTL",
          search["cache_ttl_minutes"] || 15
        ),
      failover: resolve_search_failover(search),
      perplexity: resolve_perplexity(search)
    }
  end

  defp resolve_search_failover(search) do
    failover = search["failover"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_WEB_SEARCH_FAILOVER_ENABLED",
          if(is_nil(failover["enabled"]), do: true, else: failover["enabled"])
        ),
      provider: Helpers.get_env("LEMON_WEB_SEARCH_FAILOVER_PROVIDER", failover["provider"])
    }
  end

  defp resolve_perplexity(search) do
    perplexity = search["perplexity"] || %{}

    %{
      api_key: Helpers.get_env("LEMON_PERPLEXITY_API_KEY", perplexity["api_key"]),
      base_url: Helpers.get_env("LEMON_PERPLEXITY_BASE_URL", perplexity["base_url"]),
      model: Helpers.get_env("LEMON_PERPLEXITY_MODEL", perplexity["model"] || "perplexity/sonar-pro")
    }
  end

  defp resolve_web_fetch(web) do
    fetch = web["fetch"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_WEB_FETCH_ENABLED",
          if(is_nil(fetch["enabled"]), do: true, else: fetch["enabled"])
        ),
      max_chars: Helpers.get_env_int("LEMON_WEB_FETCH_MAX_CHARS", fetch["max_chars"] || 50_000),
      timeout_seconds:
        Helpers.get_env_int("LEMON_WEB_FETCH_TIMEOUT", fetch["timeout_seconds"] || 30),
      cache_ttl_minutes:
        Helpers.get_env_int("LEMON_WEB_FETCH_CACHE_TTL", fetch["cache_ttl_minutes"] || 15),
      max_redirects:
        Helpers.get_env_int("LEMON_WEB_FETCH_MAX_REDIRECTS", fetch["max_redirects"] || 3),
      user_agent:
        Helpers.get_env(
          "LEMON_WEB_FETCH_USER_AGENT",
          fetch["user_agent"] ||
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        ),
      readability:
        Helpers.get_env_bool(
          "LEMON_WEB_FETCH_READABILITY",
          if(is_nil(fetch["readability"]), do: true, else: fetch["readability"])
        ),
      allow_private_network:
        Helpers.get_env_bool(
          "LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK",
          if(is_nil(fetch["allow_private_network"]), do: false, else: fetch["allow_private_network"])
        ),
      allowed_hostnames: resolve_allowed_hostnames(fetch),
      firecrawl: resolve_firecrawl(fetch)
    }
  end

  defp resolve_allowed_hostnames(fetch) do
    env_hostnames = Helpers.get_env_list("LEMON_WEB_FETCH_ALLOWED_HOSTNAMES")

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
      enabled:
        if(is_nil(enabled_val), do: nil, else: enabled_val)
        |> then(fn val ->
          env_val = Helpers.get_env("LEMON_FIRECRAWL_ENABLED")

          cond do
            is_nil(env_val) -> val
            env_val in ["true", "1", "yes"] -> true
            env_val in ["false", "0", "no"] -> false
            true -> val
          end
        end),
      api_key: Helpers.get_env("LEMON_FIRECRAWL_API_KEY", firecrawl["api_key"]),
      base_url:
        Helpers.get_env(
          "LEMON_FIRECRAWL_BASE_URL",
          firecrawl["base_url"] || "https://api.firecrawl.dev"
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
        Helpers.get_env_bool(
          "LEMON_WEB_CACHE_PERSISTENT",
          if(is_nil(cache["persistent"]), do: true, else: cache["persistent"])
        ),
      path: Helpers.get_env("LEMON_WEB_CACHE_PATH", cache["path"]),
      max_entries: Helpers.get_env_int("LEMON_WEB_CACHE_MAX_ENTRIES", cache["max_entries"] || 100)
    }
  end

  defp resolve_wasm(settings) do
    wasm = settings["wasm"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_WASM_ENABLED",
          if(is_nil(wasm["enabled"]), do: false, else: wasm["enabled"])
        ),
      auto_build:
        Helpers.get_env_bool(
          "LEMON_WASM_AUTO_BUILD",
          if(is_nil(wasm["auto_build"]), do: true, else: wasm["auto_build"])
        ),
      runtime_path: Helpers.get_env("LEMON_WASM_RUNTIME_PATH", wasm["runtime_path"] || ""),
      tool_paths: resolve_wasm_tool_paths(wasm),
      default_memory_limit:
        Helpers.get_env_bytes(
          "LEMON_WASM_DEFAULT_MEMORY_LIMIT",
          wasm["default_memory_limit"] || 10_485_760
        ),
      default_timeout_ms:
        Helpers.get_env_int(
          "LEMON_WASM_DEFAULT_TIMEOUT_MS",
          wasm["default_timeout_ms"] || 60_000
        ),
      default_fuel_limit:
        Helpers.get_env_int(
          "LEMON_WASM_DEFAULT_FUEL_LIMIT",
          wasm["default_fuel_limit"] || 10_000_000
        ),
      cache_compiled:
        Helpers.get_env_bool(
          "LEMON_WASM_CACHE_COMPILED",
          if(is_nil(wasm["cache_compiled"]), do: true, else: wasm["cache_compiled"])
        ),
      cache_dir: Helpers.get_env("LEMON_WASM_CACHE_DIR", wasm["cache_dir"] || ""),
      max_tool_invoke_depth:
        Helpers.get_env_int(
          "LEMON_WASM_MAX_TOOL_INVOKE_DEPTH",
          wasm["max_tool_invoke_depth"] || 4
        )
    }
  end

  defp resolve_wasm_tool_paths(wasm) do
    env_paths = Helpers.get_env_list("LEMON_WASM_TOOL_PATHS")

    if env_paths != [] do
      env_paths
    else
      wasm["tool_paths"] || []
    end
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
      }
    }
  end
end
