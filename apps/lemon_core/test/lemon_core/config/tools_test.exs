defmodule LemonCore.Config.ToolsTest do
  @moduledoc """
  Tests for the Config.Tools module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Tools

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      [
        "LEMON_AUTO_RESIZE_IMAGES",
        "LEMON_WEB_SEARCH_ENABLED",
        "LEMON_WEB_SEARCH_PROVIDER",
        "LEMON_WEB_SEARCH_API_KEY",
        "LEMON_WEB_SEARCH_MAX_RESULTS",
        "LEMON_WEB_SEARCH_TIMEOUT",
        "LEMON_WEB_SEARCH_CACHE_TTL",
        "LEMON_WEB_SEARCH_FAILOVER_ENABLED",
        "LEMON_WEB_SEARCH_FAILOVER_PROVIDER",
        "LEMON_PERPLEXITY_API_KEY",
        "LEMON_PERPLEXITY_BASE_URL",
        "LEMON_PERPLEXITY_MODEL",
        "LEMON_WEB_FETCH_ENABLED",
        "LEMON_WEB_FETCH_MAX_CHARS",
        "LEMON_WEB_FETCH_TIMEOUT",
        "LEMON_WEB_FETCH_CACHE_TTL",
        "LEMON_WEB_FETCH_MAX_REDIRECTS",
        "LEMON_WEB_FETCH_USER_AGENT",
        "LEMON_WEB_FETCH_READABILITY",
        "LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK",
        "LEMON_WEB_FETCH_ALLOWED_HOSTNAMES",
        "LEMON_FIRECRAWL_ENABLED",
        "LEMON_FIRECRAWL_API_KEY",
        "LEMON_FIRECRAWL_BASE_URL",
        "LEMON_WEB_CACHE_PERSISTENT",
        "LEMON_WEB_CACHE_PATH",
        "LEMON_WEB_CACHE_MAX_ENTRIES",
        "LEMON_WASM_ENABLED",
        "LEMON_WASM_AUTO_BUILD",
        "LEMON_WASM_RUNTIME_PATH",
        "LEMON_WASM_TOOL_PATHS",
        "LEMON_WASM_DEFAULT_MEMORY_LIMIT",
        "LEMON_WASM_DEFAULT_TIMEOUT_MS",
        "LEMON_WASM_DEFAULT_FUEL_LIMIT",
        "LEMON_WASM_CACHE_COMPILED",
        "LEMON_WASM_CACHE_DIR",
        "LEMON_WASM_MAX_TOOL_INVOKE_DEPTH",
        "LEMON_TOOL_DISCLOSURE_ENABLED",
        "LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS",
        "LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS",
        "LEMON_TOOL_DISCLOSURE_MAX_RESULTS",
        "LEMON_TOOL_DISCLOSURE_PROFILE"
      ]
      |> Enum.each(&System.delete_env/1)

      # Restore original values
      original_env
      |> Enum.each(fn {key, value} ->
        System.put_env(key, value)
      end)
    end)

    :ok
  end

  describe "resolve/1" do
    test "uses defaults when no settings provided" do
      config = Tools.resolve(%{})

      assert config.auto_resize_images == true
      assert config.web.search.enabled == true
      assert config.web.search.provider == "brave"
      assert config.web.fetch.enabled == true
      assert config.wasm.enabled == false
    end

    test "uses settings from config map" do
      settings = %{
        "tools" => %{
          "auto_resize_images" => false,
          "web" => %{
            "search" => %{
              "provider" => "perplexity",
              "max_results" => 10
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.auto_resize_images == false
      assert config.web.search.provider == "perplexity"
      assert config.web.search.max_results == 10
    end

    test "environment variables override settings" do
      System.put_env("LEMON_AUTO_RESIZE_IMAGES", "false")
      System.put_env("LEMON_WEB_SEARCH_PROVIDER", "perplexity")
      System.put_env("LEMON_WEB_FETCH_MAX_CHARS", "100000")
      System.put_env("LEMON_WASM_ENABLED", "true")

      settings = %{
        "tools" => %{
          "auto_resize_images" => true,
          "web" => %{
            "search" => %{
              "provider" => "brave"
            },
            "fetch" => %{
              "max_chars" => 50_000
            }
          },
          "wasm" => %{
            "enabled" => false
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.auto_resize_images == false
      assert config.web.search.provider == "perplexity"
      assert config.web.fetch.max_chars == 100_000
      assert config.wasm.enabled == true
    end
  end

  describe "web search configuration" do
    test "uses default search settings" do
      config = Tools.resolve(%{})

      assert config.web.search.enabled == true
      assert config.web.search.provider == "brave"
      assert config.web.search.max_results == 5
      assert config.web.search.timeout_seconds == 30
      assert config.web.search.cache_ttl_minutes == 15
    end

    test "uses search settings from config" do
      settings = %{
        "tools" => %{
          "web" => %{
            "search" => %{
              "enabled" => false,
              "provider" => "perplexity",
              "max_results" => 10,
              "timeout_seconds" => 60
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.search.enabled == false
      assert config.web.search.provider == "perplexity"
      assert config.web.search.max_results == 10
      assert config.web.search.timeout_seconds == 60
    end

    test "environment variables override search settings" do
      System.put_env("LEMON_WEB_SEARCH_ENABLED", "false")
      System.put_env("LEMON_WEB_SEARCH_PROVIDER", "perplexity")
      System.put_env("LEMON_WEB_SEARCH_MAX_RESULTS", "10")
      System.put_env("LEMON_WEB_SEARCH_TIMEOUT", "60")
      System.put_env("LEMON_WEB_SEARCH_CACHE_TTL", "30")

      config = Tools.resolve(%{})

      assert config.web.search.enabled == false
      assert config.web.search.provider == "perplexity"
      assert config.web.search.max_results == 10
      assert config.web.search.timeout_seconds == 60
      assert config.web.search.cache_ttl_minutes == 30
    end
  end

  describe "search failover configuration" do
    test "uses default failover settings" do
      config = Tools.resolve(%{})

      assert config.web.search.failover.enabled == true
      assert config.web.search.failover.provider == nil
    end

    test "uses failover settings from config" do
      settings = %{
        "tools" => %{
          "web" => %{
            "search" => %{
              "failover" => %{
                "enabled" => false,
                "provider" => "brave"
              }
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.search.failover.enabled == false
      assert config.web.search.failover.provider == "brave"
    end

    test "environment variables override failover settings" do
      System.put_env("LEMON_WEB_SEARCH_FAILOVER_ENABLED", "false")
      System.put_env("LEMON_WEB_SEARCH_FAILOVER_PROVIDER", "perplexity")

      config = Tools.resolve(%{})

      assert config.web.search.failover.enabled == false
      assert config.web.search.failover.provider == "perplexity"
    end
  end

  describe "perplexity configuration" do
    test "uses default perplexity settings" do
      config = Tools.resolve(%{})

      assert config.web.search.perplexity.api_key == nil
      assert config.web.search.perplexity.base_url == nil
      assert config.web.search.perplexity.model == "perplexity/sonar-pro"
    end

    test "uses perplexity settings from config" do
      settings = %{
        "tools" => %{
          "web" => %{
            "search" => %{
              "perplexity" => %{
                "model" => "perplexity/sonar"
              }
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.search.perplexity.model == "perplexity/sonar"
    end

    test "environment variables override perplexity settings" do
      System.put_env("LEMON_PERPLEXITY_API_KEY", "test-key")
      System.put_env("LEMON_PERPLEXITY_BASE_URL", "https://api.perplexity.ai")
      System.put_env("LEMON_PERPLEXITY_MODEL", "perplexity/sonar")

      config = Tools.resolve(%{})

      assert config.web.search.perplexity.api_key == "test-key"
      assert config.web.search.perplexity.base_url == "https://api.perplexity.ai"
      assert config.web.search.perplexity.model == "perplexity/sonar"
    end
  end

  describe "web fetch configuration" do
    test "uses default fetch settings" do
      config = Tools.resolve(%{})

      assert config.web.fetch.enabled == true
      assert config.web.fetch.max_chars == 50_000
      assert config.web.fetch.timeout_seconds == 30
      assert config.web.fetch.max_redirects == 3
      assert config.web.fetch.readability == true
      assert config.web.fetch.allow_private_network == false
      assert config.web.fetch.allowed_hostnames == []
    end

    test "uses fetch settings from config" do
      settings = %{
        "tools" => %{
          "web" => %{
            "fetch" => %{
              "enabled" => false,
              "max_chars" => 100_000,
              "readability" => false,
              "allow_private_network" => true
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.fetch.enabled == false
      assert config.web.fetch.max_chars == 100_000
      assert config.web.fetch.readability == false
      assert config.web.fetch.allow_private_network == true
    end

    test "environment variables override fetch settings" do
      System.put_env("LEMON_WEB_FETCH_ENABLED", "false")
      System.put_env("LEMON_WEB_FETCH_MAX_CHARS", "100000")
      System.put_env("LEMON_WEB_FETCH_TIMEOUT", "60")
      System.put_env("LEMON_WEB_FETCH_MAX_REDIRECTS", "5")
      System.put_env("LEMON_WEB_FETCH_READABILITY", "false")
      System.put_env("LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK", "true")

      config = Tools.resolve(%{})

      assert config.web.fetch.enabled == false
      assert config.web.fetch.max_chars == 100_000
      assert config.web.fetch.timeout_seconds == 60
      assert config.web.fetch.max_redirects == 5
      assert config.web.fetch.readability == false
      assert config.web.fetch.allow_private_network == true
    end

    test "environment variable overrides allowed hostnames" do
      System.put_env("LEMON_WEB_FETCH_ALLOWED_HOSTNAMES", "example.com,test.com")

      settings = %{
        "tools" => %{
          "web" => %{
            "fetch" => %{
              "allowed_hostnames" => ["other.com"]
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.fetch.allowed_hostnames == ["example.com", "test.com"]
    end
  end

  describe "web cache configuration" do
    test "uses default cache settings" do
      config = Tools.resolve(%{})

      assert config.web.cache.persistent == true
      assert config.web.cache.path == nil
      assert config.web.cache.max_entries == 100
    end

    test "uses cache settings from config" do
      settings = %{
        "tools" => %{
          "web" => %{
            "cache" => %{
              "persistent" => false,
              "max_entries" => 200
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.cache.persistent == false
      assert config.web.cache.max_entries == 200
    end

    test "environment variables override cache settings" do
      System.put_env("LEMON_WEB_CACHE_PERSISTENT", "false")
      System.put_env("LEMON_WEB_CACHE_PATH", "/tmp/cache")
      System.put_env("LEMON_WEB_CACHE_MAX_ENTRIES", "200")

      config = Tools.resolve(%{})

      assert config.web.cache.persistent == false
      assert config.web.cache.path == "/tmp/cache"
      assert config.web.cache.max_entries == 200
    end
  end

  describe "wasm configuration" do
    test "uses default wasm settings" do
      config = Tools.resolve(%{})

      assert config.wasm.enabled == false
      assert config.wasm.auto_build == true
      assert config.wasm.default_memory_limit == 10_485_760
      assert config.wasm.default_timeout_ms == 60_000
      assert config.wasm.default_fuel_limit == 10_000_000
      assert config.wasm.cache_compiled == true
      assert config.wasm.max_tool_invoke_depth == 4
    end

    test "uses wasm settings from config" do
      settings = %{
        "tools" => %{
          "wasm" => %{
            "enabled" => true,
            "auto_build" => false,
            "default_memory_limit" => 20_971_520,
            "max_tool_invoke_depth" => 8
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.wasm.enabled == true
      assert config.wasm.auto_build == false
      assert config.wasm.default_memory_limit == 20_971_520
      assert config.wasm.max_tool_invoke_depth == 8
    end

    test "environment variables override wasm settings" do
      System.put_env("LEMON_WASM_ENABLED", "true")
      System.put_env("LEMON_WASM_AUTO_BUILD", "false")
      System.put_env("LEMON_WASM_DEFAULT_MEMORY_LIMIT", "20MB")
      System.put_env("LEMON_WASM_DEFAULT_TIMEOUT_MS", "120000")
      System.put_env("LEMON_WASM_DEFAULT_FUEL_LIMIT", "20000000")
      System.put_env("LEMON_WASM_CACHE_COMPILED", "false")
      System.put_env("LEMON_WASM_MAX_TOOL_INVOKE_DEPTH", "8")

      config = Tools.resolve(%{})

      assert config.wasm.enabled == true
      assert config.wasm.auto_build == false
      assert config.wasm.default_memory_limit == 20_971_520
      assert config.wasm.default_timeout_ms == 120_000
      assert config.wasm.default_fuel_limit == 20_000_000
      assert config.wasm.cache_compiled == false
      assert config.wasm.max_tool_invoke_depth == 8
    end

    test "environment variable overrides wasm tool paths" do
      System.put_env("LEMON_WASM_TOOL_PATHS", "/path/one,/path/two")

      settings = %{
        "tools" => %{
          "wasm" => %{
            "tool_paths" => ["./tools"]
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.wasm.tool_paths == ["/path/one", "/path/two"]
    end
  end

  describe "tool disclosure configuration" do
    test "environment variables override disclosure settings" do
      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "false")
      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "9999")
      System.put_env("LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS", "77")
      System.put_env("LEMON_TOOL_DISCLOSURE_PROFILE", "coding")

      settings = %{
        "tools" => %{
          "disclosure" => %{
            "enabled" => true,
            "budget_tokens" => 12_000,
            "catalog_tokens" => 500,
            "profile" => "legacy"
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.disclosure.enabled == false
      assert config.disclosure.budget_tokens == 9_999
      assert config.disclosure.catalog_tokens == 77
      assert config.disclosure.profile == "coding"
    end

    test "env wins over config in both directions for the boolean" do
      settings = %{"tools" => %{"disclosure" => %{"enabled" => false}}}

      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "true")
      assert Tools.resolve(settings).disclosure.enabled == true

      # Truthy spellings other than "true" are honored by the shared caster.
      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "yes")
      assert Tools.resolve(settings).disclosure.enabled == true

      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "off")

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"enabled" => true}}}).disclosure.enabled ==
               false
    end

    test "unparseable env falls back to the configured value, not the hardcoded default" do
      settings = %{
        "tools" => %{
          "disclosure" => %{"enabled" => false, "budget_tokens" => 12_000}
        }
      }

      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "not-a-number")
      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "maybe")

      config = Tools.resolve(settings)

      assert config.disclosure.budget_tokens == 12_000
      assert config.disclosure.enabled == false
    end

    test "empty env values are treated as unset" do
      settings = %{"tools" => %{"disclosure" => %{"budget_tokens" => 12_000}}}

      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "")
      System.put_env("LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS", "   ")

      config = Tools.resolve(settings)

      assert config.disclosure.budget_tokens == 12_000
      assert config.disclosure.catalog_tokens == 2_000
    end

    test "max_results has no env override" do
      # `max_results` is controlled by config and the search tool's `limit`,
      # not by an environment override.
      System.put_env("LEMON_TOOL_DISCLOSURE_MAX_RESULTS", "99")

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"max_results" => 3}}}).disclosure.max_results ==
               3
    end

    test "an explicit nil disclosure table resolves to the defaults" do
      assert Tools.resolve(%{"tools" => %{"disclosure" => nil}}).disclosure ==
               Tools.resolve(%{}).disclosure
    end

    test "a non-map disclosure value raises, matching the other tool sections" do
      # TOML settings are always string-keyed maps; a scalar here means a
      # malformed config file. Pinned so the failure mode stays uniform with
      # `[runtime.tools.wasm]`/`[runtime.tools.web]` rather than silently
      # disclosing every tool.
      assert_raise FunctionClauseError, fn ->
        Tools.resolve(%{"tools" => %{"disclosure" => 5}})
      end

      assert_raise FunctionClauseError, fn ->
        Tools.resolve(%{"tools" => %{"wasm" => 5}})
      end
    end
  end
end
