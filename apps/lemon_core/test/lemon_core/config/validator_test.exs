defmodule LemonCore.Config.ValidatorTest do
  @moduledoc """
  Tests for the Config.Validator module.
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.Validator
  alias LemonCore.Config.Modular

  describe "validate/1" do
    test "returns :ok for valid config" do
      config = %Modular{
        agent: %{
          default_model: "claude-sonnet-4",
          default_provider: "anthropic",
          default_thinking_level: "medium"
        },
        gateway: %{
          max_concurrent_runs: 5,
          auto_resume: false,
          enable_telegram: false,
          require_engine_lock: true,
          engine_lock_timeout_ms: 30000
        },
        logging: %{
          level: :info,
          file: "/tmp/test.log",
          max_no_bytes: 100_000_000,
          max_no_files: 5,
          compress_on_rotate: true
        },
        providers: %{
          providers: %{
            anthropic: %{
              api_key: "test-key",
              base_url: "https://api.anthropic.com"
            }
          }
        },
        tools: %{
          auto_resize_images: true
        },
        tui: %{
          theme: :default,
          debug: false
        }
      }

      assert :ok = Validator.validate(config)
    end

    test "returns errors for invalid config" do
      config = %Modular{
        agent: %{
          default_model: "",
          default_provider: ""
        },
        gateway: %{
          max_concurrent_runs: -1
        },
        logging: %{
          level: :invalid_level
        },
        providers: %{
          providers: %{
            anthropic: %{
              api_key: "",
              base_url: "not-a-url"
            }
          }
        },
        tools: %{},
        tui: %{
          theme: :invalid_theme
        }
      }

      assert {:error, errors} = Validator.validate(config)
      assert is_list(errors)
      assert length(errors) > 0

      # Check for specific errors
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))
      assert Enum.any?(errors, &String.contains?(&1, "logging.level"))
    end
  end

  describe "validate_agent/2" do
    test "validates default_model" do
      errors = Validator.validate_agent(%{default_model: ""}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))

      errors = Validator.validate_agent(%{default_model: "valid-model"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
    end

    test "validates default_provider" do
      errors = Validator.validate_agent(%{default_provider: ""}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_provider"))

      errors = Validator.validate_agent(%{default_provider: "anthropic"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.default_provider"))
    end

    test "validates default_thinking_level" do
      errors = Validator.validate_agent(%{default_thinking_level: ""}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_thinking_level"))

      errors = Validator.validate_agent(%{default_thinking_level: "medium"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.default_thinking_level"))
    end

    test "accepts nil values" do
      errors = Validator.validate_agent(%{}, [])
      assert errors == []
    end
  end

  describe "validate_gateway/2" do
    test "validates max_concurrent_runs" do
      errors = Validator.validate_gateway(%{max_concurrent_runs: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))

      errors = Validator.validate_gateway(%{max_concurrent_runs: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))

      errors = Validator.validate_gateway(%{max_concurrent_runs: 5}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))
    end

    test "validates engine_lock_timeout_ms" do
      errors = Validator.validate_gateway(%{engine_lock_timeout_ms: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.engine_lock_timeout_ms"))

      errors = Validator.validate_gateway(%{engine_lock_timeout_ms: 0}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.engine_lock_timeout_ms"))
    end

    test "validates boolean fields" do
      errors = Validator.validate_gateway(%{auto_resume: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.auto_resume"))

      errors = Validator.validate_gateway(%{enable_telegram: "true"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.enable_telegram"))

      errors = Validator.validate_gateway(%{auto_resume: true, enable_telegram: false}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.auto_resume"))
      refute Enum.any?(errors, &String.contains?(&1, "gateway.enable_telegram"))
    end

    test "accepts nil values" do
      errors = Validator.validate_gateway(%{}, [])
      assert errors == []
    end
  end

  describe "validate_logging/2" do
    test "validates log level" do
      valid_levels = [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

      for level <- valid_levels do
        errors = Validator.validate_logging(%{level: level}, [])
        refute Enum.any?(errors, &String.contains?(&1, "logging.level")),
               "Level #{level} should be valid"
      end

      errors = Validator.validate_logging(%{level: :invalid}, [])
      assert Enum.any?(errors, &String.contains?(&1, "logging.level"))
    end

    test "validates file path" do
      errors = Validator.validate_logging(%{file: ""}, [])
      assert Enum.any?(errors, &String.contains?(&1, "logging.file"))

      errors = Validator.validate_logging(%{file: "/valid/path.log"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "logging.file"))
    end

    test "validates max_no_bytes" do
      errors = Validator.validate_logging(%{max_no_bytes: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "logging.max_no_bytes"))

      errors = Validator.validate_logging(%{max_no_bytes: 100_000_000}, [])
      refute Enum.any?(errors, &String.contains?(&1, "logging.max_no_bytes"))
    end

    test "validates compress_on_rotate" do
      errors = Validator.validate_logging(%{compress_on_rotate: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "logging.compress_on_rotate"))

      errors = Validator.validate_logging(%{compress_on_rotate: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "logging.compress_on_rotate"))
    end

    test "accepts nil values" do
      errors = Validator.validate_logging(%{}, [])
      assert errors == []
    end
  end

  describe "validate_providers/2" do
    test "validates provider API key" do
      errors = Validator.validate_providers(%{
        providers: %{anthropic: %{api_key: ""}}
      }, [])

      assert Enum.any?(errors, &String.contains?(&1, "api_key"))
    end

    test "validates provider base_url" do
      errors = Validator.validate_providers(%{
        providers: %{anthropic: %{base_url: "not-a-url"}}
      }, [])

      assert Enum.any?(errors, &String.contains?(&1, "base_url"))

      errors = Validator.validate_providers(%{
        providers: %{anthropic: %{base_url: "https://api.anthropic.com"}}
      }, [])

      refute Enum.any?(errors, &String.contains?(&1, "base_url"))
    end

    test "accepts nil provider config" do
      errors = Validator.validate_providers(%{providers: nil}, [])
      assert errors == []
    end
  end

  describe "validate_tools/2" do
    test "validates auto_resize_images" do
      errors = Validator.validate_tools(%{auto_resize_images: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tools.auto_resize_images"))

      errors = Validator.validate_tools(%{auto_resize_images: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "tools.auto_resize_images"))
    end

    test "accepts nil values" do
      errors = Validator.validate_tools(%{}, [])
      assert errors == []
    end
  end

  describe "validate_tui/2" do
    test "validates theme" do
      valid_themes = [:default, :dark, :light, :high_contrast, :lemon]

      for theme <- valid_themes do
        errors = Validator.validate_tui(%{theme: theme}, [])
        refute Enum.any?(errors, &String.contains?(&1, "tui.theme")),
               "Theme #{theme} should be valid"
      end

      errors = Validator.validate_tui(%{theme: :invalid}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tui.theme"))
    end

    test "validates debug" do
      errors = Validator.validate_tui(%{debug: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tui.debug"))

      errors = Validator.validate_tui(%{debug: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "tui.debug"))
    end

    test "accepts nil values" do
      errors = Validator.validate_tui(%{}, [])
      assert errors == []
    end
  end

  describe "nil values" do
    test "accepts nil for optional fields" do
      config = %Modular{
        agent: %{
          default_model: "test-model",
          default_provider: nil,
          default_thinking_level: nil
        },
        gateway: %{
          max_concurrent_runs: nil
        },
        logging: %{
          level: nil,
          file: nil
        },
        providers: %{
          providers: nil
        },
        tools: %{
          auto_resize_images: nil
        },
        tui: %{
          theme: nil,
          debug: nil
        }
      }

      assert :ok = Validator.validate(config)
    end
  end

  describe "validate_telegram_config/2" do
    test "validates telegram token format" do
      errors = Validator.validate_telegram_config([], %{
        token: "123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
      })
      assert errors == []

      errors = Validator.validate_telegram_config([], %{
        token: "invalid-token"
      })
      assert Enum.any?(errors, &String.contains?(&1, "token"))
    end

    test "accepts env var references in token" do
      errors = Validator.validate_telegram_config([], %{
        token: "${TELEGRAM_BOT_TOKEN}"
      })
      assert errors == []
    end

    test "validates telegram compaction settings" do
      errors = Validator.validate_telegram_config([], %{
        compaction: %{
          enabled: true,
          context_window_tokens: 400_000,
          reserve_tokens: 16_384,
          trigger_ratio: 0.9
        }
      })
      assert errors == []

      errors = Validator.validate_telegram_config([], %{
        compaction: %{
          enabled: "yes",
          trigger_ratio: 1.5
        }
      })
      assert Enum.any?(errors, &String.contains?(&1, "enabled"))
      assert Enum.any?(errors, &String.contains?(&1, "trigger_ratio"))
    end

    test "accepts nil telegram config" do
      errors = Validator.validate_telegram_config([], nil)
      assert errors == []
    end
  end

  describe "validate_queue_config/2" do
    test "validates queue mode" do
      errors = Validator.validate_queue_config([], %{mode: "fifo"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "lifo"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "priority"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "invalid"})
      assert Enum.any?(errors, &String.contains?(&1, "mode"))
    end

    test "validates queue drop policy" do
      errors = Validator.validate_queue_config([], %{drop: "oldest"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{drop: "newest"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{drop: "reject"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{drop: "invalid"})
      assert Enum.any?(errors, &String.contains?(&1, "drop"))
    end

    test "validates queue cap" do
      errors = Validator.validate_queue_config([], %{cap: 100})
      assert errors == []

      errors = Validator.validate_queue_config([], %{cap: 0})
      assert Enum.any?(errors, &String.contains?(&1, "cap"))

      errors = Validator.validate_queue_config([], %{cap: nil})
      assert errors == []
    end

    test "accepts nil queue config" do
      errors = Validator.validate_queue_config([], nil)
      assert errors == []
    end
  end

  describe "validate_discord_config/2" do
    test "validates discord bot token format" do
      # Valid Discord token format (3 parts separated by dots)
      errors = Validator.validate_discord_config([], %{
        bot_token: "MTA5ODc2NTQzMjEwOTg3NjU0MzIx.ABC123.XYZ789abc123def456"
      })
      assert errors == []

      # Invalid token format
      errors = Validator.validate_discord_config([], %{
        bot_token: "invalid-token"
      })
      assert Enum.any?(errors, &String.contains?(&1, "bot_token"))
    end

    test "accepts env var references in discord token" do
      errors = Validator.validate_discord_config([], %{
        bot_token: "${DISCORD_BOT_TOKEN}"
      })
      assert errors == []
    end

    test "validates discord allowed_guild_ids" do
      errors = Validator.validate_discord_config([], %{
        allowed_guild_ids: [123_456_789, 987_654_321]
      })
      assert errors == []

      errors = Validator.validate_discord_config([], %{
        allowed_guild_ids: ["123", "456"]
      })
      assert Enum.any?(errors, &String.contains?(&1, "allowed_guild_ids"))
    end

    test "validates discord allowed_channel_ids" do
      errors = Validator.validate_discord_config([], %{
        allowed_channel_ids: [123_456_789]
      })
      assert errors == []

      errors = Validator.validate_discord_config([], %{
        allowed_channel_ids: "not-a-list"
      })
      assert Enum.any?(errors, &String.contains?(&1, "allowed_channel_ids"))
    end

    test "validates discord deny_unbound_channels" do
      errors = Validator.validate_discord_config([], %{
        deny_unbound_channels: true
      })
      assert errors == []

      errors = Validator.validate_discord_config([], %{
        deny_unbound_channels: "yes"
      })
      assert Enum.any?(errors, &String.contains?(&1, "deny_unbound_channels"))
    end

    test "accepts nil discord config" do
      errors = Validator.validate_discord_config([], nil)
      assert errors == []
    end

    test "validates complete discord config" do
      errors = Validator.validate_discord_config([], %{
        bot_token: "MTA5ODc2NTQzMjEwOTg3NjU0MzIx.ABC123.XYZ789abc123def456",
        allowed_guild_ids: [123_456_789],
        allowed_channel_ids: [987_654_321],
        deny_unbound_channels: true
      })
      assert errors == []
    end
  end

  describe "validate_web_dashboard_config/2" do
    test "validates web dashboard port" do
      errors = Validator.validate_web_dashboard_config([], %{port: 4080})
      assert errors == []

      errors = Validator.validate_web_dashboard_config([], %{port: 0})
      assert Enum.any?(errors, &String.contains?(&1, "port"))

      errors = Validator.validate_web_dashboard_config([], %{port: 70_000})
      assert Enum.any?(errors, &String.contains?(&1, "port"))

      errors = Validator.validate_web_dashboard_config([], %{port: "not-an-integer"})
      assert Enum.any?(errors, &String.contains?(&1, "port"))
    end

    test "validates web dashboard host" do
      errors = Validator.validate_web_dashboard_config([], %{host: "localhost"})
      assert errors == []

      errors = Validator.validate_web_dashboard_config([], %{host: ""})
      assert Enum.any?(errors, &String.contains?(&1, "host"))

      errors = Validator.validate_web_dashboard_config([], %{host: 123})
      assert Enum.any?(errors, &String.contains?(&1, "host"))
    end

    test "validates web dashboard secret_key_base" do
      # Valid secret key (64+ characters)
      long_key = String.duplicate("a", 64)
      errors = Validator.validate_web_dashboard_config([], %{secret_key_base: long_key})
      assert errors == []

      # Too short secret key
      short_key = String.duplicate("a", 32)
      errors = Validator.validate_web_dashboard_config([], %{secret_key_base: short_key})
      assert Enum.any?(errors, &String.contains?(&1, "secret_key_base"))

      # Env var reference is valid
      errors = Validator.validate_web_dashboard_config([], %{secret_key_base: "${LEMON_WEB_SECRET_KEY_BASE}"})
      assert errors == []
    end

    test "validates web dashboard access_token" do
      # Valid access token (16+ characters)
      long_token = String.duplicate("a", 16)
      errors = Validator.validate_web_dashboard_config([], %{access_token: long_token})
      assert errors == []

      # Short access token (warning)
      short_token = String.duplicate("a", 8)
      errors = Validator.validate_web_dashboard_config([], %{access_token: short_token})
      assert Enum.any?(errors, &String.contains?(&1, "access_token"))

      # Env var reference is valid
      errors = Validator.validate_web_dashboard_config([], %{access_token: "${LEMON_WEB_ACCESS_TOKEN}"})
      assert errors == []
    end

    test "accepts nil web dashboard config" do
      errors = Validator.validate_web_dashboard_config([], nil)
      assert errors == []
    end

    test "validates complete web dashboard config" do
      errors = Validator.validate_web_dashboard_config([], %{
        port: 4080,
        host: "localhost",
        secret_key_base: String.duplicate("a", 64),
        access_token: String.duplicate("b", 16)
      })
      assert errors == []
    end

    test "validates enable_web_dashboard boolean" do
      errors = Validator.validate_gateway(%{enable_web_dashboard: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "enable_web_dashboard"))

      errors = Validator.validate_gateway(%{enable_web_dashboard: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "enable_web_dashboard"))
    end
  end

  describe "validate_farcaster_config/2" do
    test "validates farcaster hub_url" do
      errors = Validator.validate_farcaster_config([], %{hub_url: "https://hub.farcaster.xyz"})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{hub_url: "http://localhost:2281"})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{hub_url: "invalid-url"})
      assert Enum.any?(errors, &String.contains?(&1, "hub_url"))

      errors = Validator.validate_farcaster_config([], %{hub_url: 123})
      assert Enum.any?(errors, &String.contains?(&1, "hub_url"))
    end

    test "validates farcaster signer_key" do
      # Valid hex-encoded ed25519 private key (64 hex chars)
      valid_key = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      errors = Validator.validate_farcaster_config([], %{signer_key: valid_key})
      assert errors == []

      # Invalid format (too short)
      short_key = "a1b2c3d4"
      errors = Validator.validate_farcaster_config([], %{signer_key: short_key})
      assert Enum.any?(errors, &String.contains?(&1, "signer_key"))

      # Invalid format (non-hex characters)
      invalid_key = "g1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      errors = Validator.validate_farcaster_config([], %{signer_key: invalid_key})
      assert Enum.any?(errors, &String.contains?(&1, "signer_key"))

      # Env var reference is valid
      errors = Validator.validate_farcaster_config([], %{signer_key: "${FARCASTER_SIGNER_KEY}"})
      assert errors == []
    end

    test "validates farcaster app_key" do
      # Valid app key (8+ characters)
      errors = Validator.validate_farcaster_config([], %{app_key: "my-app-key-123"})
      assert errors == []

      # Too short app key
      errors = Validator.validate_farcaster_config([], %{app_key: "short"})
      assert Enum.any?(errors, &String.contains?(&1, "app_key"))

      # Env var reference is valid
      errors = Validator.validate_farcaster_config([], %{app_key: "${FARCASTER_APP_KEY}"})
      assert errors == []
    end

    test "validates farcaster frame_url" do
      errors = Validator.validate_farcaster_config([], %{frame_url: "https://frames.example.com"})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{frame_url: "http://localhost:3000/frame"})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{frame_url: "invalid-url"})
      assert Enum.any?(errors, &String.contains?(&1, "frame_url"))
    end

    test "validates farcaster verify_trusted_data boolean" do
      errors = Validator.validate_farcaster_config([], %{verify_trusted_data: true})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{verify_trusted_data: false})
      assert errors == []

      errors = Validator.validate_farcaster_config([], %{verify_trusted_data: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "verify_trusted_data"))
    end

    test "validates farcaster state_secret" do
      # Valid state secret (32+ characters)
      valid_secret = String.duplicate("a", 32)
      errors = Validator.validate_farcaster_config([], %{state_secret: valid_secret})
      assert errors == []

      # Too short state secret
      short_secret = String.duplicate("a", 16)
      errors = Validator.validate_farcaster_config([], %{state_secret: short_secret})
      assert Enum.any?(errors, &String.contains?(&1, "state_secret"))

      # Env var reference is valid
      errors = Validator.validate_farcaster_config([], %{state_secret: "${FARCASTER_STATE_SECRET}"})
      assert errors == []
    end

    test "accepts nil farcaster config" do
      errors = Validator.validate_farcaster_config([], nil)
      assert errors == []
    end

    test "validates complete farcaster config" do
      errors = Validator.validate_farcaster_config([], %{
        hub_url: "https://hub.farcaster.xyz",
        signer_key: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
        app_key: "my-farcaster-app",
        frame_url: "https://frames.example.com",
        verify_trusted_data: true,
        state_secret: String.duplicate("s", 32)
      })
      assert errors == []
    end

    test "validates enable_farcaster boolean" do
      errors = Validator.validate_gateway(%{enable_farcaster: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "enable_farcaster"))

      errors = Validator.validate_gateway(%{enable_farcaster: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "enable_farcaster"))
    end
  end

  describe "validate_xmtp_config/2" do
    test "validates xmtp wallet_key" do
      # Valid Ethereum private key (64 hex chars without 0x prefix)
      valid_key = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      errors = Validator.validate_xmtp_config([], %{wallet_key: valid_key})
      assert errors == []

      # Valid Ethereum private key (with 0x prefix)
      valid_key_with_prefix = "0xa1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      errors = Validator.validate_xmtp_config([], %{wallet_key: valid_key_with_prefix})
      assert errors == []

      # Invalid format (too short)
      short_key = "a1b2c3d4"
      errors = Validator.validate_xmtp_config([], %{wallet_key: short_key})
      assert Enum.any?(errors, &String.contains?(&1, "wallet_key"))

      # Invalid format (non-hex characters)
      invalid_key = "g1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
      errors = Validator.validate_xmtp_config([], %{wallet_key: invalid_key})
      assert Enum.any?(errors, &String.contains?(&1, "wallet_key"))

      # Env var reference is valid
      errors = Validator.validate_xmtp_config([], %{wallet_key: "${XMTP_WALLET_KEY}"})
      assert errors == []
    end

    test "validates xmtp environment" do
      errors = Validator.validate_xmtp_config([], %{environment: "production"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{env: "production"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{environment: "dev"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{environment: "local"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{environment: "invalid"})
      assert Enum.any?(errors, &String.contains?(&1, "environment"))

      errors = Validator.validate_xmtp_config([], %{environment: 123})
      assert Enum.any?(errors, &String.contains?(&1, "environment"))
    end

    test "validates xmtp wallet_address" do
      errors =
        Validator.validate_xmtp_config([], %{
          wallet_address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
        })

      assert errors == []

      errors = Validator.validate_xmtp_config([], %{wallet_address: "abcdef"})
      assert Enum.any?(errors, &String.contains?(&1, "wallet_address"))
    end

    test "validates xmtp api_url" do
      errors = Validator.validate_xmtp_config([], %{api_url: "https://api.xmtp.network"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{api_url: "http://localhost:5555"})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{api_url: "invalid-url"})
      assert Enum.any?(errors, &String.contains?(&1, "api_url"))

      errors = Validator.validate_xmtp_config([], %{api_url: 123})
      assert Enum.any?(errors, &String.contains?(&1, "api_url"))
    end

    test "validates xmtp max_connections" do
      errors = Validator.validate_xmtp_config([], %{max_connections: 10})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{max_connections: 0})
      assert Enum.any?(errors, &String.contains?(&1, "max_connections"))

      errors = Validator.validate_xmtp_config([], %{max_connections: -1})
      assert Enum.any?(errors, &String.contains?(&1, "max_connections"))

      errors = Validator.validate_xmtp_config([], %{max_connections: "not-an-integer"})
      assert Enum.any?(errors, &String.contains?(&1, "max_connections"))
    end

    test "validates xmtp poll_interval_ms and connect_timeout_ms" do
      errors =
        Validator.validate_xmtp_config([], %{
          poll_interval_ms: 1000,
          connect_timeout_ms: 5000
        })

      assert errors == []

      errors = Validator.validate_xmtp_config([], %{poll_interval_ms: 0})
      assert Enum.any?(errors, &String.contains?(&1, "poll_interval_ms"))

      errors = Validator.validate_xmtp_config([], %{connect_timeout_ms: -1})
      assert Enum.any?(errors, &String.contains?(&1, "connect_timeout_ms"))
    end

    test "validates xmtp enable_relay boolean" do
      errors = Validator.validate_xmtp_config([], %{enable_relay: true})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{enable_relay: false})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{enable_relay: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "enable_relay"))
    end

    test "validates xmtp mock_mode and require_live booleans" do
      errors = Validator.validate_xmtp_config([], %{mock_mode: false, require_live: true})
      assert errors == []

      errors = Validator.validate_xmtp_config([], %{mock_mode: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "mock_mode"))

      errors = Validator.validate_xmtp_config([], %{require_live: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "require_live"))
    end

    test "accepts nil xmtp config" do
      errors = Validator.validate_xmtp_config([], nil)
      assert errors == []
    end

    test "validates complete xmtp config" do
      errors = Validator.validate_xmtp_config([], %{
        wallet_key: "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2",
        wallet_address: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        env: "production",
        api_url: "https://api.xmtp.network",
        poll_interval_ms: 1000,
        connect_timeout_ms: 5000,
        mock_mode: false,
        require_live: true,
        max_connections: 10,
        enable_relay: false
      })
      assert errors == []
    end

    test "validates enable_xmtp boolean" do
      errors = Validator.validate_gateway(%{enable_xmtp: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "enable_xmtp"))

      errors = Validator.validate_gateway(%{enable_xmtp: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "enable_xmtp"))
    end
  end

  describe "validate_email_config/2" do
    test "validates email inbound config" do
      errors = Validator.validate_email_config([], %{
        inbound: %{
          bind_host: "0.0.0.0",
          bind_port: 8080,
          token: "webhook-secret-token",
          max_body_bytes: 10_000_000
        }
      })
      assert errors == []

      # Invalid port
      errors = Validator.validate_email_config([], %{
        inbound: %{bind_port: 70_000}
      })
      assert Enum.any?(errors, &String.contains?(&1, "bind_port"))

      # Empty host
      errors = Validator.validate_email_config([], %{
        inbound: %{bind_host: ""}
      })
      assert Enum.any?(errors, &String.contains?(&1, "bind_host"))
    end

    test "validates email outbound config" do
      errors = Validator.validate_email_config([], %{
        outbound: %{
          relay: "smtp.gmail.com",
          port: 587,
          username: "user@example.com",
          password: "secret",
          tls: true,
          auth: true,
          hostname: "example.com",
          from_address: "bot@example.com"
        }
      })
      assert errors == []

      # Invalid port
      errors = Validator.validate_email_config([], %{
        outbound: %{port: 0}
      })
      assert Enum.any?(errors, &String.contains?(&1, "port"))

      # Empty relay
      errors = Validator.validate_email_config([], %{
        outbound: %{relay: ""}
      })
      assert Enum.any?(errors, &String.contains?(&1, "relay"))
    end

    test "validates email tls config" do
      # Boolean values
      errors = Validator.validate_email_config([], %{outbound: %{tls: true}})
      assert errors == []

      errors = Validator.validate_email_config([], %{outbound: %{tls: false}})
      assert errors == []

      # String values
      errors = Validator.validate_email_config([], %{outbound: %{tls: "always"}})
      assert errors == []

      errors = Validator.validate_email_config([], %{outbound: %{tls: "never"}})
      assert errors == []

      errors = Validator.validate_email_config([], %{outbound: %{tls: "if_available"}})
      assert errors == []

      # Invalid value
      errors = Validator.validate_email_config([], %{outbound: %{tls: "invalid"}})
      assert Enum.any?(errors, &String.contains?(&1, "tls"))
    end

    test "validates email auth config" do
      # Boolean values
      errors = Validator.validate_email_config([], %{outbound: %{auth: true}})
      assert errors == []

      errors = Validator.validate_email_config([], %{outbound: %{auth: false}})
      assert errors == []

      # String values
      errors = Validator.validate_email_config([], %{outbound: %{auth: "always"}})
      assert errors == []

      errors = Validator.validate_email_config([], %{outbound: %{auth: "if_available"}})
      assert errors == []

      # Invalid value
      errors = Validator.validate_email_config([], %{outbound: %{auth: "invalid"}})
      assert Enum.any?(errors, &String.contains?(&1, "auth"))
    end

    test "validates email attachment_max_bytes" do
      errors = Validator.validate_email_config([], %{attachment_max_bytes: 10_000_000})
      assert errors == []

      errors = Validator.validate_email_config([], %{attachment_max_bytes: 0})
      assert Enum.any?(errors, &String.contains?(&1, "attachment_max_bytes"))

      errors = Validator.validate_email_config([], %{attachment_max_bytes: -1})
      assert Enum.any?(errors, &String.contains?(&1, "attachment_max_bytes"))
    end

    test "validates email inbound_enabled boolean" do
      errors = Validator.validate_email_config([], %{inbound_enabled: true})
      assert errors == []

      errors = Validator.validate_email_config([], %{inbound_enabled: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "inbound_enabled"))
    end

    test "validates email webhook_enabled boolean" do
      errors = Validator.validate_email_config([], %{webhook_enabled: true})
      assert errors == []

      errors = Validator.validate_email_config([], %{webhook_enabled: "yes"})
      assert Enum.any?(errors, &String.contains?(&1, "webhook_enabled"))
    end

    test "accepts nil email config" do
      errors = Validator.validate_email_config([], nil)
      assert errors == []
    end

    test "validates complete email config" do
      errors = Validator.validate_email_config([], %{
        inbound: %{
          bind_host: "0.0.0.0",
          bind_port: 8080,
          token: "webhook-secret",
          max_body_bytes: 10_000_000
        },
        outbound: %{
          relay: "smtp.gmail.com",
          port: 587,
          username: "user@example.com",
          password: "secret",
          tls: true,
          auth: true,
          hostname: "example.com",
          from_address: "bot@example.com"
        },
        attachment_max_bytes: 10_000_000,
        inbound_enabled: true,
        webhook_enabled: true
      })
      assert errors == []
    end

    test "validates enable_email boolean" do
      errors = Validator.validate_gateway(%{enable_email: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "enable_email"))

      errors = Validator.validate_gateway(%{enable_email: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "enable_email"))
    end
  end
end
