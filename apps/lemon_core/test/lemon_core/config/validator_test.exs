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
end
