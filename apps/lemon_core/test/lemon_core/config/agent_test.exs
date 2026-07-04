defmodule LemonCore.Config.AgentTest do
  @moduledoc """
  Tests for the Config.Agent module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Agent

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear any test env vars
      [
        "LEMON_DEFAULT_PROVIDER",
        "LEMON_DEFAULT_MODEL",
        "LEMON_DEFAULT_THINKING_LEVEL",
        "LEMON_COMPACTION_ENABLED",
        "LEMON_COMPACTION_RESERVE_TOKENS",
        "LEMON_COMPACTION_KEEP_RECENT_TOKENS",
        "LEMON_RETRY_ENABLED",
        "LEMON_MAX_RETRIES",
        "LEMON_BASE_DELAY_MS",
        "LEMON_PROVIDER_ROUTING_ENABLED",
        "LEMON_PROVIDER_FALLBACK_PROVIDERS",
        "LEMON_PROVIDER_ROUTING_DEFAULT_POOL",
        "LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE",
        "LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS",
        "LEMON_SHELL_PATH",
        "LEMON_SHELL_COMMAND_PREFIX",
        "LEMON_EXTENSION_PATHS",
        "LEMON_EXTENSIONS_ENABLED",
        "LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS",
        "LEMON_THEME"
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
      config = Agent.resolve(%{})

      assert config.default_provider == "anthropic"
      assert config.default_model == "claude-sonnet-4-20250514"
      assert config.default_thinking_level == "medium"
      assert config.theme == "lemon"
      assert config.extension_paths == []
      assert config.extensions.auto_load_default_paths == false
    end

    test "uses settings from config map" do
      settings = %{
        "agent" => %{
          "default_provider" => "openai",
          "default_model" => "gpt-4o",
          "default_thinking_level" => "high",
          "theme" => "ocean"
        }
      }

      config = Agent.resolve(settings)

      assert config.default_provider == "openai"
      assert config.default_model == "gpt-4o"
      assert config.default_thinking_level == "high"
      assert config.theme == "ocean"
    end

    test "supports defaults and runtime aliases" do
      settings = %{
        "defaults" => %{
          "provider" => "openai",
          "model" => "openai:gpt-5",
          "thinking_level" => "high"
        },
        "runtime" => %{
          "theme" => "ocean"
        }
      }

      config = Agent.resolve(settings)

      assert config.default_provider == "openai"
      assert config.default_model == "openai:gpt-5"
      assert config.default_thinking_level == "high"
      assert config.theme == "ocean"
    end

    test "environment variables override settings" do
      System.put_env("LEMON_DEFAULT_PROVIDER", "ollama")
      System.put_env("LEMON_DEFAULT_MODEL", "llama3")
      System.put_env("LEMON_DEFAULT_THINKING_LEVEL", "low")
      System.put_env("LEMON_THEME", "dark")

      settings = %{
        "agent" => %{
          "default_provider" => "openai",
          "default_model" => "gpt-4o",
          "default_thinking_level" => "high",
          "theme" => "ocean"
        }
      }

      config = Agent.resolve(settings)

      assert config.default_provider == "ollama"
      assert config.default_model == "llama3"
      assert config.default_thinking_level == "low"
      assert config.theme == "dark"
    end
  end

  describe "provider routing configuration" do
    test "uses provider routing defaults" do
      config = Agent.resolve(%{})

      assert config.provider_routing.enabled == true
      assert config.provider_routing.fallback_providers == []
      assert config.provider_routing.default_pool == nil
      assert config.provider_routing.default_profile == nil
      assert config.provider_routing.credential_pools == %{}
      assert config.provider_routing.profiles == %{}
      assert config.provider_routing.require_credentials == true
    end

    test "uses runtime provider routing settings" do
      settings = %{
        "runtime" => %{
          "provider_routing" => %{
            "enabled" => false,
            "fallback_providers" => ["zai", "anthropic"],
            "default_pool" => "burst",
            "default_profile" => "ops",
            "credential_pools" => %{
              "burst" => %{
                "providers" => ["openai", "zai"],
                "strategy" => "round_robin"
              }
            },
            "profiles" => %{
              "ops" => %{
                "fallback_providers" => ["anthropic"],
                "credential_pool" => "burst",
                "distribution" => %{"openai" => 70, "zai" => 30}
              }
            },
            "require_credentials" => false
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.provider_routing.enabled == false
      assert config.provider_routing.fallback_providers == ["zai", "anthropic"]
      assert config.provider_routing.default_pool == "burst"
      assert config.provider_routing.default_profile == "ops"

      assert config.provider_routing.credential_pools == %{
               "burst" => %{providers: ["openai", "zai"], strategy: "round_robin"}
             }

      assert config.provider_routing.profiles == %{
               "ops" => %{
                 fallback_providers: ["anthropic"],
                 credential_pool: "burst",
                 distribution: %{"openai" => 70, "zai" => 30}
               }
             }

      assert config.provider_routing.require_credentials == false
    end

    test "provider routing env vars override settings" do
      System.put_env("LEMON_PROVIDER_ROUTING_ENABLED", "false")
      System.put_env("LEMON_PROVIDER_FALLBACK_PROVIDERS", "openai,zai")
      System.put_env("LEMON_PROVIDER_ROUTING_DEFAULT_POOL", "burst")
      System.put_env("LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE", "ops")
      System.put_env("LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS", "false")

      config = Agent.resolve(%{})

      assert config.provider_routing.enabled == false
      assert config.provider_routing.fallback_providers == ["openai", "zai"]
      assert config.provider_routing.default_pool == "burst"
      assert config.provider_routing.default_profile == "ops"
      assert config.provider_routing.require_credentials == false
    end
  end

  describe "compaction configuration" do
    test "uses default compaction settings" do
      config = Agent.resolve(%{})

      assert config.compaction.enabled == true
      assert config.compaction.reserve_tokens == 16_384
      assert config.compaction.keep_recent_tokens == 20_000
    end

    test "uses compaction settings from config" do
      settings = %{
        "agent" => %{
          "compaction" => %{
            "enabled" => false,
            "reserve_tokens" => 8192,
            "keep_recent_tokens" => 10_000
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.compaction.enabled == false
      assert config.compaction.reserve_tokens == 8192
      assert config.compaction.keep_recent_tokens == 10_000
    end

    test "environment variables override compaction settings" do
      System.put_env("LEMON_COMPACTION_ENABLED", "false")
      System.put_env("LEMON_COMPACTION_RESERVE_TOKENS", "8192")
      System.put_env("LEMON_COMPACTION_KEEP_RECENT_TOKENS", "10000")

      settings = %{
        "agent" => %{
          "compaction" => %{
            "enabled" => true,
            "reserve_tokens" => 16_384,
            "keep_recent_tokens" => 20_000
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.compaction.enabled == false
      assert config.compaction.reserve_tokens == 8192
      assert config.compaction.keep_recent_tokens == 10_000
    end
  end

  describe "retry configuration" do
    test "uses default retry settings" do
      config = Agent.resolve(%{})

      assert config.retry.enabled == true
      assert config.retry.max_retries == 3
      assert config.retry.base_delay_ms == 1000
    end

    test "uses retry settings from config" do
      settings = %{
        "agent" => %{
          "retry" => %{
            "enabled" => false,
            "max_retries" => 5,
            "base_delay_ms" => 2000
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.retry.enabled == false
      assert config.retry.max_retries == 5
      assert config.retry.base_delay_ms == 2000
    end

    test "environment variables override retry settings" do
      System.put_env("LEMON_RETRY_ENABLED", "false")
      System.put_env("LEMON_MAX_RETRIES", "5")
      System.put_env("LEMON_BASE_DELAY_MS", "2000")

      config = Agent.resolve(%{})

      assert config.retry.enabled == false
      assert config.retry.max_retries == 5
      assert config.retry.base_delay_ms == 2000
    end
  end

  describe "shell configuration" do
    test "uses default shell settings (nil)" do
      config = Agent.resolve(%{})

      assert config.shell.path == nil
      assert config.shell.command_prefix == nil
    end

    test "uses shell settings from config" do
      settings = %{
        "agent" => %{
          "shell" => %{
            "path" => "/bin/zsh",
            "command_prefix" => "prefix"
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.shell.path == "/bin/zsh"
      assert config.shell.command_prefix == "prefix"
    end

    test "environment variables override shell settings" do
      System.put_env("LEMON_SHELL_PATH", "/bin/bash")
      System.put_env("LEMON_SHELL_COMMAND_PREFIX", "sudo")

      settings = %{
        "agent" => %{
          "shell" => %{
            "path" => "/bin/zsh",
            "command_prefix" => "prefix"
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.shell.path == "/bin/bash"
      assert config.shell.command_prefix == "sudo"
    end
  end

  describe "extension_paths configuration" do
    test "uses default empty extension_paths" do
      config = Agent.resolve(%{})

      assert config.extension_paths == []
    end

    test "uses extension_paths from config" do
      settings = %{
        "agent" => %{
          "extension_paths" => ["./ext1", "./ext2"]
        }
      }

      config = Agent.resolve(settings)

      assert config.extension_paths == ["./ext1", "./ext2"]
    end

    test "environment variable overrides extension_paths" do
      System.put_env("LEMON_EXTENSION_PATHS", "/path/one,/path/two")

      settings = %{
        "agent" => %{
          "extension_paths" => ["./ext1"]
        }
      }

      config = Agent.resolve(settings)

      assert config.extension_paths == ["/path/one", "/path/two"]
    end

    test "default extension directories require explicit trust" do
      config = Agent.resolve(%{})

      assert config.extensions.enabled == true
      assert config.extensions.auto_load_default_paths == false
    end

    test "uses extension enabled setting from config" do
      settings = %{
        "runtime" => %{
          "extensions" => %{
            "enabled" => false
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.extensions.enabled == false
    end

    test "environment variable overrides extension enabled setting" do
      System.put_env("LEMON_EXTENSIONS_ENABLED", "false")

      config =
        Agent.resolve(%{
          "runtime" => %{
            "extensions" => %{
              "enabled" => true
            }
          }
        })

      assert config.extensions.enabled == false
    end

    test "uses default extension auto-load setting from config" do
      settings = %{
        "runtime" => %{
          "extensions" => %{
            "auto_load_default_paths" => true
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.extensions.auto_load_default_paths == true
    end

    test "environment variable overrides default extension auto-load setting" do
      System.put_env("LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS", "true")

      config =
        Agent.resolve(%{
          "runtime" => %{
            "extensions" => %{
              "auto_load_default_paths" => false
            }
          }
        })

      assert config.extensions.auto_load_default_paths == true
    end
  end

  describe "defaults/0" do
    test "returns the default agent configuration" do
      defaults = Agent.defaults()

      assert defaults["default_provider"] == "anthropic"
      assert defaults["default_model"] == "claude-sonnet-4-20250514"
      assert defaults["default_thinking_level"] == "medium"
      assert defaults["theme"] == "lemon"
      assert defaults["extension_paths"] == []
      assert defaults["extensions"]["enabled"] == true
      assert defaults["extensions"]["auto_load_default_paths"] == false
      assert defaults["compaction"]["enabled"] == true
      assert defaults["retry"]["max_retries"] == 3
      assert defaults["provider_routing"]["enabled"] == true
      assert defaults["provider_routing"]["fallback_providers"] == []
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = Agent.resolve(%{})

      assert %Agent{} = config
      assert is_binary(config.default_provider)
      assert is_binary(config.default_model)
      assert is_map(config.compaction)
      assert is_map(config.retry)
      assert is_map(config.provider_routing)
      assert is_map(config.shell)
      assert is_list(config.extension_paths)
      assert is_binary(config.theme)
    end
  end
end
