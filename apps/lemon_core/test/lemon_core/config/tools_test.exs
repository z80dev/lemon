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
        "LEMON_EXECUTE_CODE_ENABLED",
        "LEMON_EXECUTE_CODE_PYTHON_PATH",
        "LEMON_EXECUTE_CODE_TIMEOUT_MS",
        "LEMON_EXECUTE_CODE_MAX_RPC_CALLS",
        "LEMON_EXECUTE_CODE_MAX_RPC_RESULT_BYTES",
        "LEMON_EXECUTE_CODE_MAX_OUTPUT_BYTES",
        "LEMON_EXECUTE_CODE_TOOLS",
        "LEMON_EXECUTE_CODE_KERNEL_MODE",
        "LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS",
        "LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS",
        "LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL",
        "LEMON_TOOL_DISCLOSURE_ENABLED",
        "LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS",
        "LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS",
        "LEMON_TOOL_DISCLOSURE_MAX_RESULTS"
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

  describe "execute_code configuration" do
    test "uses default execute_code settings" do
      config = Tools.resolve(%{})

      assert config.execute_code.enabled == false
      assert config.execute_code.python_path == ""
      assert config.execute_code.timeout_ms == 120_000
      assert config.execute_code.max_rpc_calls == 100
      assert config.execute_code.max_rpc_result_bytes == 5_242_880
      assert config.execute_code.max_output_bytes == 50_000
      assert config.execute_code.max_text_bytes == 65_536
      assert config.execute_code.max_parallel_rpc == 4
      assert config.execute_code.kernel_mode == "per_call"
      assert config.execute_code.kernel_idle_timeout_ms == 1_800_000
      assert config.execute_code.max_live_kernels == 16
      assert config.execute_code.max_queued_cells_per_kernel == 8
    end

    test "uses execute_code settings from config" do
      settings = %{
        "tools" => %{
          "execute_code" => %{
            "enabled" => true,
            "python_path" => "/usr/local/bin/python3",
            "timeout_ms" => 5_000,
            "max_rpc_calls" => 12,
            "max_rpc_result_bytes" => 1_024,
            "max_output_bytes" => 2_048,
            "max_text_bytes" => 4_096,
            "max_parallel_rpc" => 2,
            "kernel_mode" => "session",
            "kernel_idle_timeout_ms" => 600_000,
            "max_live_kernels" => 3,
            "max_queued_cells_per_kernel" => 2
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.execute_code.enabled == true
      assert config.execute_code.python_path == "/usr/local/bin/python3"
      assert config.execute_code.timeout_ms == 5_000
      assert config.execute_code.max_rpc_calls == 12
      assert config.execute_code.max_rpc_result_bytes == 1_024
      assert config.execute_code.max_output_bytes == 2_048
      assert config.execute_code.max_text_bytes == 4_096
      assert config.execute_code.max_parallel_rpc == 2
      assert config.execute_code.kernel_mode == "session"
      assert config.execute_code.kernel_idle_timeout_ms == 600_000
      assert config.execute_code.max_live_kernels == 3
      assert config.execute_code.max_queued_cells_per_kernel == 2
    end

    test "environment variables override execute_code settings" do
      System.put_env("LEMON_EXECUTE_CODE_ENABLED", "true")
      System.put_env("LEMON_EXECUTE_CODE_MAX_RPC_CALLS", "7")
      System.put_env("LEMON_EXECUTE_CODE_TIMEOUT_MS", "3000")
      System.put_env("LEMON_EXECUTE_CODE_TOOLS", "read,ls")
      System.put_env("LEMON_EXECUTE_CODE_KERNEL_MODE", "session")
      System.put_env("LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS", "240000")
      System.put_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS", "5")
      System.put_env("LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL", "4")
      System.put_env("LEMON_EXECUTE_CODE_MAX_TEXT_BYTES", "1024")
      System.put_env("LEMON_EXECUTE_CODE_MAX_PARALLEL_RPC", "9")

      settings = %{
        "tools" => %{
          "execute_code" => %{
            "enabled" => false,
            "timeout_ms" => 5_000,
            "max_rpc_calls" => 12,
            "tools" => ["grep"],
            "kernel_mode" => "per_call",
            "kernel_idle_timeout_ms" => 1_800_000,
            "max_live_kernels" => 16,
            "max_queued_cells_per_kernel" => 8
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.execute_code.enabled == true
      assert config.execute_code.max_rpc_calls == 7
      assert config.execute_code.timeout_ms == 3_000
      assert config.execute_code.tools == ["read", "ls"]
      assert config.execute_code.kernel_mode == "session"
      assert config.execute_code.kernel_idle_timeout_ms == 240_000
      assert config.execute_code.max_live_kernels == 5
      assert config.execute_code.max_queued_cells_per_kernel == 4
      assert config.execute_code.max_text_bytes == 1_024
      assert config.execute_code.max_parallel_rpc == 9

      System.delete_env("LEMON_EXECUTE_CODE_KERNEL_MODE")
      System.delete_env("LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS")
      System.delete_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS")
      System.delete_env("LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL")
      System.delete_env("LEMON_EXECUTE_CODE_MAX_TEXT_BYTES")
      System.delete_env("LEMON_EXECUTE_CODE_MAX_PARALLEL_RPC")
    end

    test "defaults/0 documents the execute_code section" do
      assert Tools.defaults()["execute_code"] == %{
               "enabled" => false,
               "python_path" => "",
               "timeout_ms" => 120_000,
               "max_rpc_calls" => 100,
               "max_rpc_result_bytes" => 5_242_880,
               "max_output_bytes" => 50_000,
               "max_text_bytes" => 65_536,
               "max_parallel_rpc" => 4,
               "tools" => [],
               "kernel_mode" => "per_call",
               "kernel_idle_timeout_ms" => 1_800_000,
               "max_live_kernels" => 16,
               "max_queued_cells_per_kernel" => 8
             }
    end

    test "kernel_mode accepts only per_call or session and trims whitespace" do
      System.put_env("LEMON_EXECUTE_CODE_KERNEL_MODE", "  session\n")
      assert Tools.resolve(%{}).execute_code.kernel_mode == "session"

      System.put_env("LEMON_EXECUTE_CODE_KERNEL_MODE", "per_call")

      assert Tools.resolve(%{"tools" => %{"execute_code" => %{"kernel_mode" => "session"}}}).execute_code.kernel_mode ==
               "per_call"

      System.delete_env("LEMON_EXECUTE_CODE_KERNEL_MODE")
    end

    test "invalid kernel_mode values fail closed to per_call" do
      # Fail-closed contract: no malformed spelling (TOML or env) can select
      # session mode; persistence requires the exact string "session".
      for bad_mode <- ["Session", "SESSION", "persistent", "per-call", "percall", 42, true] do
        settings = %{"tools" => %{"execute_code" => %{"kernel_mode" => bad_mode}}}

        assert Tools.resolve(settings).execute_code.kernel_mode == "per_call"
      end

      # A malformed env override never defers to a valid TOML "session".
      System.put_env("LEMON_EXECUTE_CODE_KERNEL_MODE", "sessions")

      assert Tools.resolve(%{"tools" => %{"execute_code" => %{"kernel_mode" => "session"}}}).execute_code.kernel_mode ==
               "per_call"

      System.delete_env("LEMON_EXECUTE_CODE_KERNEL_MODE")
    end

    test "kernel bounds resolve only positive integers" do
      # Zero, negative, or non-integer TOML bounds fall back to the hardcoded
      # default rather than reading downstream as "unlimited" or "reap
      # immediately".
      for bad_bound <- [0, -1, -1_800_000, "eight", 2.5, true] do
        settings = %{"tools" => %{"execute_code" => %{"max_live_kernels" => bad_bound}}}

        assert Tools.resolve(settings).execute_code.max_live_kernels == 16
      end

      assert Tools.resolve(%{
               "tools" => %{"execute_code" => %{"kernel_idle_timeout_ms" => 0}}
             }).execute_code.kernel_idle_timeout_ms == 1_800_000

      assert Tools.resolve(%{
               "tools" => %{"execute_code" => %{"max_queued_cells_per_kernel" => -8}}
             }).execute_code.max_queued_cells_per_kernel == 8
    end

    test "invalid kernel bound env overrides defer to TOML, never to zero or unlimited" do
      settings = %{
        "tools" => %{
          "execute_code" => %{
            "max_live_kernels" => 4,
            "kernel_idle_timeout_ms" => 300_000,
            "max_queued_cells_per_kernel" => 6
          }
        }
      }

      for bad_env <- ["abc", "0", "-2", ""] do
        System.put_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS", bad_env)
        assert Tools.resolve(settings).execute_code.max_live_kernels == 4
      end

      System.delete_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS")

      System.put_env("LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS", "soon")
      assert Tools.resolve(settings).execute_code.kernel_idle_timeout_ms == 300_000
      System.delete_env("LEMON_EXECUTE_CODE_KERNEL_IDLE_TIMEOUT_MS")

      System.put_env("LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL", "0")
      assert Tools.resolve(settings).execute_code.max_queued_cells_per_kernel == 6
      System.delete_env("LEMON_EXECUTE_CODE_MAX_QUEUED_CELLS_PER_KERNEL")

      # With nothing valid anywhere, the hardcoded defaults win.
      System.put_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS", "junk")

      config = Tools.resolve(%{})

      assert config.execute_code.max_live_kernels == 16
      assert config.execute_code.kernel_idle_timeout_ms == 1_800_000
      assert config.execute_code.max_queued_cells_per_kernel == 8

      System.delete_env("LEMON_EXECUTE_CODE_MAX_LIVE_KERNELS")
    end

    test "defaults/0 round-trips through resolve/1 unchanged for execute_code" do
      # Guards against key-name drift between the `defaults/0` advertisement
      # (string keys, what `lemon config init` writes) and the resolver
      # (which reads those same string keys back out of a TOML file).
      assert Tools.resolve(%{"tools" => Tools.defaults()}).execute_code ==
               Tools.resolve(%{}).execute_code
    end
  end

  describe "tool disclosure configuration" do
    test "uses default disclosure settings" do
      config = Tools.resolve(%{})

      assert config.disclosure == %{
               enabled: true,
               budget_tokens: 40_000,
               catalog_tokens: 2_000,
               max_results: 5
             }
    end

    test "uses disclosure settings from config" do
      settings = %{
        "tools" => %{
          "disclosure" => %{
            "enabled" => false,
            "budget_tokens" => 12_000,
            "catalog_tokens" => 500,
            "max_results" => 3
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.disclosure == %{
               enabled: false,
               budget_tokens: 12_000,
               catalog_tokens: 500,
               max_results: 3
             }
    end

    test "environment variables override disclosure settings" do
      System.put_env("LEMON_TOOL_DISCLOSURE_ENABLED", "false")
      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "9999")
      System.put_env("LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS", "77")

      settings = %{
        "tools" => %{
          "disclosure" => %{
            "enabled" => true,
            "budget_tokens" => 12_000,
            "catalog_tokens" => 500
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.disclosure.enabled == false
      assert config.disclosure.budget_tokens == 9_999
      assert config.disclosure.catalog_tokens == 77
    end
  end

  describe "tool disclosure configuration (adversarial)" do
    test "defaults/0 round-trips through resolve/1 unchanged" do
      # Guards against key-name drift between the `defaults/0` advertisement
      # (string keys, what `lemon config init` writes) and the resolver
      # (which reads those same string keys back out of a TOML file).
      assert Tools.resolve(%{"tools" => Tools.defaults()}).disclosure ==
               Tools.resolve(%{}).disclosure
    end

    test "defaults/0 and resolve/1 agree key-for-key" do
      resolved = Tools.resolve(%{}).disclosure
      advertised = Tools.defaults()["disclosure"]

      assert Enum.sort(Map.keys(advertised)) ==
               resolved |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      for {key, value} <- advertised do
        assert resolved[String.to_existing_atom(key)] == value
      end
    end

    test "each disclosure key defaults independently of the others" do
      for {key, atom_key, value} <- [
            {"enabled", :enabled, false},
            {"enabled", :enabled, true},
            {"budget_tokens", :budget_tokens, 111},
            {"catalog_tokens", :catalog_tokens, 222},
            {"max_results", :max_results, 3}
          ] do
        resolved = Tools.resolve(%{"tools" => %{"disclosure" => %{key => value}}}).disclosure

        assert Map.get(resolved, atom_key) == value

        assert Map.drop(resolved, [atom_key]) ==
                 Map.drop(Tools.resolve(%{}).disclosure, [atom_key])
      end
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
      # Documented decision: `max_results` is a per-call default the model
      # overrides with the search tool's `limit` parameter, not an operator
      # knob. This pins that no half-wired env var appears later.
      System.put_env("LEMON_TOOL_DISCLOSURE_MAX_RESULTS", "99")

      assert Tools.resolve(%{}).disclosure.max_results == 5

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"max_results" => 3}}}).disclosure.max_results ==
               3

      assert LemonCore.Env.describe(:lemon_tool_disclosure_max_results) == nil
    end

    test "out-of-contract token budgets pass through unsanitized" do
      # NOTE: this pins today's behavior, which does NOT match the declared
      # `disclosure_config` type (`pos_integer()`). Zero/negative budgets mean
      # "always over budget" and a string budget will crash any numeric
      # comparison, so the consumer of `config.agent.tools.disclosure` must
      # sanitize before use.
      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"budget_tokens" => 0}}}).disclosure.budget_tokens ==
               0

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"budget_tokens" => -5}}}).disclosure.budget_tokens ==
               -5

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"catalog_tokens" => 0}}}).disclosure.catalog_tokens ==
               0

      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"budget_tokens" => "lots"}}}).disclosure.budget_tokens ==
               "lots"

      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "0")
      assert Tools.resolve(%{}).disclosure.budget_tokens == 0

      System.put_env("LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS", "-3")
      assert Tools.resolve(%{}).disclosure.budget_tokens == -3
    end

    test "a non-boolean enabled value passes through as-is" do
      # Same caveat as the budgets: a TOML `enabled = "false"` is a truthy
      # binary downstream, so consumers must not branch on it directly.
      assert Tools.resolve(%{"tools" => %{"disclosure" => %{"enabled" => "false"}}}).disclosure.enabled ==
               "false"
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

    test "atom-keyed settings are ignored (TOML settings are string-keyed)" do
      assert Tools.resolve(%{"tools" => %{disclosure: %{budget_tokens: 7}}}).disclosure ==
               Tools.resolve(%{}).disclosure
    end
  end

  describe "defaults/0" do
    test "returns the default tools configuration" do
      defaults = Tools.defaults()

      assert defaults["auto_resize_images"] == true
      assert defaults["web"]["search"]["enabled"] == true
      assert defaults["web"]["search"]["provider"] == "brave"
      assert defaults["web"]["fetch"]["max_chars"] == 50_000
      assert defaults["wasm"]["enabled"] == false
      assert defaults["wasm"]["auto_build"] == true

      assert defaults["disclosure"] == %{
               "enabled" => true,
               "budget_tokens" => 40_000,
               "catalog_tokens" => 2_000,
               "max_results" => 5
             }
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = Tools.resolve(%{})

      assert %Tools{} = config
      assert is_boolean(config.auto_resize_images)
      assert is_map(config.web)
      assert is_map(config.web.search)
      assert is_map(config.web.fetch)
      assert is_map(config.web.cache)
      assert is_map(config.wasm)
      assert is_map(config.disclosure)
    end
  end
end
