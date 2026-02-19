defmodule LemonCore.Config.ProvidersTest do
  @moduledoc """
  Tests for the Config.Providers module.
  """
  use LemonCore.Testing.Case, async: false

  alias LemonCore.Config.Providers

  setup do
    # Store original env vars to restore later
    original_env = System.get_env()

    on_exit(fn ->
      # Clear test env vars
      [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_CODEX_API_KEY"
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
    test "returns empty providers when no settings provided" do
      config = Providers.resolve(%{})

      assert config.providers == %{}
    end

    test "parses providers from config" do
      settings = %{
        "providers" => %{
          "anthropic" => %{
            "api_key" => "sk-ant-test123",
            "base_url" => "https://api.anthropic.com"
          },
          "openai" => %{
            "api_key" => "sk-test456",
            "base_url" => "https://api.openai.com"
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["anthropic"][:api_key] == "sk-ant-test123"
      assert config.providers["anthropic"][:base_url] == "https://api.anthropic.com"
      assert config.providers["openai"][:api_key] == "sk-test456"
      assert config.providers["openai"][:base_url] == "https://api.openai.com"
    end

    test "handles api_key_secret field" do
      settings = %{
        "providers" => %{
          "openai" => %{
            "api_key_secret" => "openai_api_key"
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["openai"][:api_key_secret] == "openai_api_key"
      assert config.providers["openai"][:api_key] == nil
    end

    test "filters out nil values" do
      settings = %{
        "providers" => %{
          "anthropic" => %{
            "api_key" => "sk-test",
            "base_url" => nil,
            "api_key_secret" => ""
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["anthropic"][:api_key] == "sk-test"
      assert not Map.has_key?(config.providers["anthropic"], :base_url)
      assert not Map.has_key?(config.providers["anthropic"], :api_key_secret)
    end

    test "environment variables override config values" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-env")
      System.put_env("ANTHROPIC_BASE_URL", "https://env.anthropic.com")

      settings = %{
        "providers" => %{
          "anthropic" => %{
            "api_key" => "sk-ant-config",
            "base_url" => "https://config.anthropic.com"
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["anthropic"][:api_key] == "sk-ant-env"
      assert config.providers["anthropic"][:base_url] == "https://env.anthropic.com"
    end

    test "openai-codex uses OPENAI_CODEX_API_KEY env var" do
      System.put_env("OPENAI_CODEX_API_KEY", "sk-codex-env")

      settings = %{
        "providers" => %{
          "openai-codex" => %{
            "api_key" => "sk-codex-config"
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["openai-codex"][:api_key] == "sk-codex-env"
    end

    test "openai and openai-codex share OPENAI_BASE_URL" do
      System.put_env("OPENAI_BASE_URL", "https://custom.openai.com")

      settings = %{
        "providers" => %{
          "openai" => %{},
          "openai-codex" => %{}
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["openai"][:base_url] == "https://custom.openai.com"
      assert config.providers["openai-codex"][:base_url] == "https://custom.openai.com"
    end

    test "handles unknown providers" do
      settings = %{
        "providers" => %{
          "custom-provider" => %{
            "api_key" => "sk-custom",
            "base_url" => "https://custom.example.com"
          }
        }
      }

      config = Providers.resolve(settings)

      assert config.providers["custom-provider"][:api_key] == "sk-custom"
      assert config.providers["custom-provider"][:base_url] == "https://custom.example.com"
    end

    test "ignores invalid provider configs" do
      settings = %{
        "providers" => %{
          "invalid" => "not a map",
          "valid" => %{"api_key" => "sk-valid"}
        }
      }

      config = Providers.resolve(settings)

      assert not Map.has_key?(config.providers, "invalid")
      assert config.providers["valid"][:api_key] == "sk-valid"
    end
  end

  describe "get_provider/2" do
    test "returns provider config when exists" do
      config = Providers.resolve(%{
        "providers" => %{"anthropic" => %{"api_key" => "sk-test"}}
      })

      provider = Providers.get_provider(config, "anthropic")

      assert provider[:api_key] == "sk-test"
    end

    test "returns empty map when provider not found" do
      config = Providers.resolve(%{})

      provider = Providers.get_provider(config, "unknown")

      assert provider == %{}
    end
  end

  describe "get_api_key/2" do
    test "returns api_key when present" do
      config = Providers.resolve(%{
        "providers" => %{"anthropic" => %{"api_key" => "sk-test"}}
      })

      assert Providers.get_api_key(config, "anthropic") == "sk-test"
    end

    test "returns nil when provider not found" do
      config = Providers.resolve(%{})

      assert Providers.get_api_key(config, "unknown") == nil
    end

    test "returns nil when api_key not present" do
      config = Providers.resolve(%{
        "providers" => %{"openai" => %{"api_key_secret" => "secret_name"}}
      })

      # api_key_secret is not resolved here (would need Secrets module)
      assert Providers.get_api_key(config, "openai") == nil
    end
  end

  describe "list_providers/1" do
    test "returns list of provider names" do
      config = Providers.resolve(%{
        "providers" => %{
          "anthropic" => %{},
          "openai" => %{},
          "ollama" => %{}
        }
      })

      providers = Providers.list_providers(config)

      assert "anthropic" in providers
      assert "openai" in providers
      assert "ollama" in providers
    end

    test "returns empty list when no providers" do
      config = Providers.resolve(%{})

      assert Providers.list_providers(config) == []
    end
  end

  describe "defaults/0" do
    test "returns empty map" do
      assert Providers.defaults() == %{}
    end
  end

  describe "struct type" do
    test "returns a properly typed struct" do
      config = Providers.resolve(%{})

      assert %Providers{} = config
      assert is_map(config.providers)
    end
  end
end
