defmodule CodingAgent.SettingsManagerTest do
  @moduledoc """
  Tests for the CodingAgent.SettingsManager module.

  This module loads canonical TOML configuration and exposes a struct
  that coding agent components can consume.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.SettingsManager
  alias LemonCore.Config, as: LemonConfig

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup do
    # Create a temporary directory for test configs
    tmp_dir = System.tmp_dir!()
    test_id = :erlang.unique_integer([:positive])
    test_dir = Path.join(tmp_dir, "settings_manager_test_#{test_id}")

    File.mkdir_p!(test_dir)

    on_exit(fn -> File.rm_rf!(test_dir) end)

    %{test_dir: test_dir}
  end

  # ============================================================================
  # from_config/1 Tests
  # ============================================================================

  describe "from_config/1" do
    test "converts empty LemonConfig to SettingsManager with defaults" do
      config = %LemonConfig{
        providers: %{},
        agent: %{},
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert %SettingsManager{} = settings
      assert settings.default_model == nil
      assert settings.default_thinking_level == :medium
      assert settings.providers == %{}
      assert settings.compaction_enabled == true
      assert settings.reserve_tokens == 16_384
      assert settings.keep_recent_tokens == 20_000
      assert settings.retry_enabled == true
      assert settings.max_retries == 3
      assert settings.base_delay_ms == 1000
      assert settings.shell_path == nil
      assert settings.command_prefix == nil
      assert settings.auto_resize_images == true
      assert settings.tools == %{}
      assert settings.extension_paths == []
      assert settings.theme == "default"
      assert settings.codex == %{}
      assert settings.kimi == %{}
      assert settings.claude == %{}
      assert settings.opencode == %{}
      assert settings.pi == %{}
    end

    test "converts config with default provider and model" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: "anthropic",
          default_model: "claude-sonnet-4"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model == %{
               provider: "anthropic",
               model_id: "claude-sonnet-4",
               base_url: nil
             }
    end

    test "parses model spec with provider prefix" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: nil,
          default_model: "openai:gpt-4"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model == %{
               provider: "openai",
               model_id: "gpt-4",
               base_url: nil
             }
    end

    test "handles model without provider prefix" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: "anthropic",
          default_model: "claude-3-opus"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model.provider == "anthropic"
      assert settings.default_model.model_id == "claude-3-opus"
    end

    test "handles nil provider and model" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: nil,
          default_model: nil
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model == nil
    end

    test "handles empty string model" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: "anthropic",
          default_model: ""
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model == nil
    end

    test "converts thinking level from string to atom" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_thinking_level: "high"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_thinking_level == :high
    end

    test "preserves atom thinking level" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_thinking_level: :low
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_thinking_level == :low
    end

    test "copies providers from config" do
      providers = %{
        "anthropic" => %{api_key: "test-key", base_url: "https://api.anthropic.com"},
        "openai" => %{api_key: "openai-key"}
      }

      config = %LemonConfig{
        providers: providers,
        agent: %{},
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.providers == providers
    end

    test "extracts compaction settings from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          compaction: %{
            enabled: false,
            reserve_tokens: 8192,
            keep_recent_tokens: 10000
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.compaction_enabled == false
      assert settings.reserve_tokens == 8192
      assert settings.keep_recent_tokens == 10000
    end

    test "extracts retry settings from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          retry: %{
            enabled: false,
            max_retries: 5,
            base_delay_ms: 2000
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.retry_enabled == false
      assert settings.max_retries == 5
      assert settings.base_delay_ms == 2000
    end

    test "extracts shell settings from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          shell: %{
            path: "/bin/zsh",
            command_prefix: "source ~/.zshrc &&"
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.shell_path == "/bin/zsh"
      assert settings.command_prefix == "source ~/.zshrc &&"
    end

    test "extracts tool settings from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          tools: %{
            auto_resize_images: false,
            web: %{search: %{enabled: true}}
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.auto_resize_images == false
      assert settings.tools == %{auto_resize_images: false, web: %{search: %{enabled: true}}}
    end

    test "extracts extension paths from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          extension_paths: ["/path/to/ext1", "/path/to/ext2"]
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.extension_paths == ["/path/to/ext1", "/path/to/ext2"]
    end

    test "extracts theme from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          theme: "dark"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.theme == "dark"
    end

    test "extracts CLI settings from agent config" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          cli: %{
            codex: %{auto_approve: true, extra_args: ["-v"]},
            kimi: %{extra_args: ["--debug"]},
            claude: %{dangerously_skip_permissions: false},
            opencode: %{model: "gpt-4"},
            pi: %{model: "custom-model", provider: "custom-provider"}
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.codex == %{auto_approve: true, extra_args: ["-v"]}
      assert settings.kimi == %{extra_args: ["--debug"]}
      assert settings.claude == %{dangerously_skip_permissions: false}
      assert settings.opencode == %{model: "gpt-4"}
      assert settings.pi == %{model: "custom-model", provider: "custom-provider"}
    end
  end

  # ============================================================================
  # load/1 Tests
  # ============================================================================

  describe "load/1" do
    test "loads settings from a project directory", %{test_dir: test_dir} do
      # Create a project config
      config_dir = Path.join(test_dir, ".lemon")
      File.mkdir_p!(config_dir)

      config_content = """
      [agent]
      default_provider = "openai"
      default_model = "gpt-4"
      default_thinking_level = "low"
      theme = "light"

      [agent.compaction]
      enabled = false
      reserve_tokens = 4096
      keep_recent_tokens = 5000

      [agent.retry]
      enabled = true
      max_retries = 5
      base_delay_ms = 500

      [agent.shell]
      path = "/bin/bash"
      command_prefix = "export PATH=/usr/local/bin:$PATH &&"

      [agent.tools]
      auto_resize_images = false

      [[agent.extension_paths]]
      "/custom/extensions"
      """

      File.write!(Path.join(config_dir, "config.toml"), config_content)

      settings = SettingsManager.load(test_dir)

      assert %SettingsManager{} = settings
      assert settings.default_model.provider == "openai"
      assert settings.default_model.model_id == "gpt-4"
      assert settings.default_thinking_level == :low
      assert settings.theme == "light"
      assert settings.compaction_enabled == false
      assert settings.reserve_tokens == 4096
      assert settings.keep_recent_tokens == 5000
      assert settings.retry_enabled == true
      assert settings.max_retries == 5
      assert settings.base_delay_ms == 500
      assert settings.shell_path == "/bin/bash"
      assert settings.command_prefix == "export PATH=/usr/local/bin:$PATH &&"
      assert settings.auto_resize_images == false
    end

    test "loads settings with defaults when no config exists", %{test_dir: test_dir} do
      # Ensure no config exists
      settings = SettingsManager.load(test_dir)

      assert %SettingsManager{} = settings
      assert settings.default_thinking_level == :medium
      assert settings.compaction_enabled == true
      assert settings.retry_enabled == true
    end
  end

  # ============================================================================
  # get_compaction_settings/1 Tests
  # ============================================================================

  describe "get_compaction_settings/1" do
    test "returns compaction settings as a map" do
      settings = %SettingsManager{
        compaction_enabled: true,
        reserve_tokens: 8192,
        keep_recent_tokens: 10000
      }

      result = SettingsManager.get_compaction_settings(settings)

      assert result == %{
               enabled: true,
               reserve_tokens: 8192,
               keep_recent_tokens: 10000
             }
    end

    test "returns correct values when compaction is disabled" do
      settings = %SettingsManager{
        compaction_enabled: false,
        reserve_tokens: 16_384,
        keep_recent_tokens: 20_000
      }

      result = SettingsManager.get_compaction_settings(settings)

      assert result.enabled == false
      assert result.reserve_tokens == 16_384
      assert result.keep_recent_tokens == 20_000
    end
  end

  # ============================================================================
  # get_retry_settings/1 Tests
  # ============================================================================

  describe "get_retry_settings/1" do
    test "returns retry settings as a map" do
      settings = %SettingsManager{
        retry_enabled: true,
        max_retries: 5,
        base_delay_ms: 2000
      }

      result = SettingsManager.get_retry_settings(settings)

      assert result == %{
               enabled: true,
               max_retries: 5,
               base_delay_ms: 2000
             }
    end

    test "returns correct values when retry is disabled" do
      settings = %SettingsManager{
        retry_enabled: false,
        max_retries: 3,
        base_delay_ms: 1000
      }

      result = SettingsManager.get_retry_settings(settings)

      assert result.enabled == false
      assert result.max_retries == 3
      assert result.base_delay_ms == 1000
    end
  end

  # ============================================================================
  # get_model_settings/1 Tests
  # ============================================================================

  describe "get_model_settings/1" do
    test "returns model settings with default_model and thinking_level" do
      default_model = %{provider: "anthropic", model_id: "claude-3-opus", base_url: nil}

      settings = %SettingsManager{
        default_model: default_model,
        default_thinking_level: :high
      }

      result = SettingsManager.get_model_settings(settings)

      assert result == %{
               default_model: default_model,
               default_thinking_level: :high
             }
    end

    test "returns nil for default_model when not set" do
      settings = %SettingsManager{
        default_model: nil,
        default_thinking_level: :medium
      }

      result = SettingsManager.get_model_settings(settings)

      assert result.default_model == nil
      assert result.default_thinking_level == :medium
    end
  end

  # ============================================================================
  # get_shell_settings/1 Tests
  # ============================================================================

  describe "get_shell_settings/1" do
    test "returns shell settings as a map" do
      settings = %SettingsManager{
        shell_path: "/bin/zsh",
        command_prefix: "source ~/.zshrc &&"
      }

      result = SettingsManager.get_shell_settings(settings)

      assert result == %{
               shell_path: "/bin/zsh",
               command_prefix: "source ~/.zshrc &&"
             }
    end

    test "returns nil values when shell settings are not configured" do
      settings = %SettingsManager{
        shell_path: nil,
        command_prefix: nil
      }

      result = SettingsManager.get_shell_settings(settings)

      assert result.shell_path == nil
      assert result.command_prefix == nil
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration" do
    test "full round-trip from config to settings to component settings", %{test_dir: test_dir} do
      config = %LemonConfig{
        providers: %{
          "anthropic" => %{api_key: "test-key"}
        },
        agent: %{
          default_provider: "anthropic",
          default_model: "claude-sonnet-4",
          default_thinking_level: :medium,
          compaction: %{
            enabled: true,
            reserve_tokens: 8192,
            keep_recent_tokens: 10000
          },
          retry: %{
            enabled: true,
            max_retries: 3,
            base_delay_ms: 1000
          },
          shell: %{
            path: "/bin/bash",
            command_prefix: nil
          }
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      # Verify all component settings can be extracted
      model_settings = SettingsManager.get_model_settings(settings)
      assert model_settings.default_model.provider == "anthropic"
      assert model_settings.default_thinking_level == :medium

      compaction_settings = SettingsManager.get_compaction_settings(settings)
      assert compaction_settings.enabled == true
      assert compaction_settings.reserve_tokens == 8192

      retry_settings = SettingsManager.get_retry_settings(settings)
      assert retry_settings.enabled == true
      assert retry_settings.max_retries == 3

      shell_settings = SettingsManager.get_shell_settings(settings)
      assert shell_settings.shell_path == "/bin/bash"
    end

    test "parse_model_spec handles various model specification formats" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: nil,
          default_model: "provider:model-name"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model.provider == "provider"
      assert settings.default_model.model_id == "model-name"
    end

    test "from_config uses default values for missing nested configs" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          # No compaction, retry, or shell config provided
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      # Should use defaults
      assert settings.compaction_enabled == true
      assert settings.reserve_tokens == 16_384
      assert settings.retry_enabled == true
      assert settings.max_retries == 3
      assert settings.shell_path == nil
      assert settings.command_prefix == nil
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles model spec with multiple colons correctly" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: nil,
          default_model: "azure:gpt-4:vision"
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      # Should split on first colon only
      assert settings.default_model.provider == "azure"
      assert settings.default_model.model_id == "gpt-4:vision"
    end

    test "handles empty extension_paths" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          extension_paths: []
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.extension_paths == []
    end

    test "handles all thinking level values" do
      levels = [:off, :minimal, :low, :medium, :high, :xhigh]

      for level <- levels do
        config = %LemonConfig{
          providers: %{},
          agent: %{
            default_thinking_level: level
          },
          tui: %{},
          logging: %{},
          gateway: %{},
          agents: %{}
        }

        settings = SettingsManager.from_config(config)
        assert settings.default_thinking_level == level
      end
    end

    test "handles string thinking level values" do
      levels = ["off", "minimal", "low", "medium", "high", "xhigh"]
      expected = [:off, :minimal, :low, :medium, :high, :xhigh]

      for {level, expected_atom} <- Enum.zip(levels, expected) do
        config = %LemonConfig{
          providers: %{},
          agent: %{
            default_thinking_level: level
          },
          tui: %{},
          logging: %{},
          gateway: %{},
          agents: %{}
        }

        settings = SettingsManager.from_config(config)
        assert settings.default_thinking_level == expected_atom
      end
    end

    test "handles provider without model" do
      config = %LemonConfig{
        providers: %{},
        agent: %{
          default_provider: "anthropic",
          default_model: nil
        },
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.default_model == nil
    end

    test "handles complex provider configuration" do
      providers = %{
        "anthropic" => %{
          api_key: "sk-ant-api03-test",
          base_url: "https://api.anthropic.com",
          api_key_secret: nil
        },
        "openai" => %{
          api_key: "sk-test",
          base_url: "https://api.openai.com/v1",
          api_key_secret: "secret-key"
        }
      }

      config = %LemonConfig{
        providers: providers,
        agent: %{},
        tui: %{},
        logging: %{},
        gateway: %{},
        agents: %{}
      }

      settings = SettingsManager.from_config(config)

      assert settings.providers["anthropic"].api_key == "sk-ant-api03-test"
      assert settings.providers["anthropic"].base_url == "https://api.anthropic.com"
      assert settings.providers["openai"].api_key_secret == "secret-key"
    end
  end
end
