defmodule LemonCore.Config.ReadmeTest do
  @moduledoc """
  Tests to verify the examples in the README work correctly.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config

  describe "README examples" do
    test "Config.Agent.resolve/1 works as documented" do
      settings = %{
        "agent" => %{
          "default_provider" => "openai",
          "default_model" => "gpt-4o"
        }
      }

      config = Config.Agent.resolve(settings)

      assert config.default_provider == "openai"
      assert config.default_model == "gpt-4o"
    end

    test "Config.Tools.resolve/1 works as documented" do
      settings = %{
        "tools" => %{
          "auto_resize_images" => false,
          "web" => %{
            "search" => %{
              "provider" => "perplexity"
            }
          }
        }
      }

      config = Config.Tools.resolve(settings)

      assert config.auto_resize_images == false
      assert config.web.search.provider == "perplexity"
    end

    test "Config.Gateway.resolve/1 works as documented" do
      settings = %{
        "gateway" => %{
          "max_concurrent_runs" => 5,
          "enable_telegram" => true
        }
      }

      config = Config.Gateway.resolve(settings)

      assert config.max_concurrent_runs == 5
      assert config.enable_telegram == true
    end

    test "Config.Logging.resolve/1 works as documented" do
      settings = %{
        "logging" => %{
          "file" => "./logs/test.log",
          "level" => "debug"
        }
      }

      config = Config.Logging.resolve(settings)

      assert config.file == "./logs/test.log"
      assert config.level == :debug
    end

    test "Config.TUI.resolve/1 works as documented" do
      settings = %{
        "tui" => %{
          "theme" => "dark",
          "debug" => true
        }
      }

      config = Config.TUI.resolve(settings)

      assert config.theme == "dark"
      assert config.debug == true
    end

    test "Config.Providers.resolve/1 works as documented" do
      settings = %{
        "providers" => %{
          "anthropic" => %{
            "api_key" => "sk-test"
          }
        }
      }

      config = Config.Providers.resolve(settings)

      assert config.providers["anthropic"][:api_key] == "sk-test"
    end

    test "Config.Providers helper functions work" do
      settings = %{
        "providers" => %{
          "anthropic" => %{"api_key" => "sk-test"},
          "openai" => %{"api_key" => "sk-openai"}
        }
      }

      config = Config.Providers.resolve(settings)

      # Test get_provider/2
      anthropic = Config.Providers.get_provider(config, "anthropic")
      assert anthropic[:api_key] == "sk-test"

      # Test get_api_key/2
      assert Config.Providers.get_api_key(config, "anthropic") == "sk-test"
      assert Config.Providers.get_api_key(config, "openai") == "sk-openai"

      # Test list_providers/1
      providers = Config.Providers.list_providers(config)
      assert "anthropic" in providers
      assert "openai" in providers
    end

    test "environment variable priority works" do
      # Set env var
      System.put_env("LEMON_DEFAULT_MODEL", "gpt-4o-mini")

      on_exit(fn ->
        System.delete_env("LEMON_DEFAULT_MODEL")
      end)

      settings = %{
        "agent" => %{
          "default_model" => "claude-sonnet-4-20250514"
        }
      }

      config = Config.Agent.resolve(settings)

      # Env var should override config file
      assert config.default_model == "gpt-4o-mini"
    end
  end
end
