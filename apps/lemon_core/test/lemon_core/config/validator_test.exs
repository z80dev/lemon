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
          max_iterations: 50,
          timeout_seconds: 300,
          enable_approval: true
        },
        gateway: %{
          web_port: 4000,
          enable_telegram: false,
          enable_sms: false,
          enable_discord: false
        },
        logging: %{
          level: :info,
          file_path: "/tmp/test.log",
          max_size_mb: 100,
          max_files: 5
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
          timeout_ms: 30_000,
          enable_web_search: true,
          enable_file_access: true,
          max_file_size_mb: 10
        },
        tui: %{
          theme: :default,
          debug: false,
          compact: false
        }
      }

      assert :ok = Validator.validate(config)
    end

    test "returns errors for invalid config" do
      config = %Modular{
        agent: %{
          default_model: "",
          max_iterations: -1,
          timeout_seconds: -5,
          enable_approval: "yes"
        },
        gateway: %{
          web_port: 100_000,
          enable_telegram: "true"
        },
        logging: %{
          level: :invalid_level,
          max_size_mb: 0
        },
        providers: %{
          providers: %{
            anthropic: %{
              api_key: "",
              base_url: "not-a-url"
            }
          }
        },
        tools: %{
          timeout_ms: -100
        },
        tui: %{
          theme: :invalid_theme
        }
      }

      assert {:error, errors} = Validator.validate(config)
      assert is_list(errors)
      assert length(errors) > 0

      # Check for specific errors
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
      assert Enum.any?(errors, &String.contains?(&1, "agent.max_iterations"))
      assert Enum.any?(errors, &String.contains?(&1, "gateway.web_port"))
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

    test "validates max_iterations" do
      errors = Validator.validate_agent(%{max_iterations: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.max_iterations"))

      errors = Validator.validate_agent(%{max_iterations: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.max_iterations"))

      errors = Validator.validate_agent(%{max_iterations: 50}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.max_iterations"))
    end

    test "validates timeout_seconds" do
      errors = Validator.validate_agent(%{timeout_seconds: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.timeout_seconds"))

      errors = Validator.validate_agent(%{timeout_seconds: 0}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.timeout_seconds"))
    end

    test "validates enable_approval" do
      errors = Validator.validate_agent(%{enable_approval: "yes"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "agent.enable_approval"))

      errors = Validator.validate_agent(%{enable_approval: true}, [])
      refute Enum.any?(errors, &String.contains?(&1, "agent.enable_approval"))
    end
  end

  describe "validate_gateway/2" do
    test "validates web_port" do
      errors = Validator.validate_gateway(%{web_port: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.web_port"))

      errors = Validator.validate_gateway(%{web_port: 100_000}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.web_port"))

      errors = Validator.validate_gateway(%{web_port: 4000}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.web_port"))
    end

    test "accepts nil port" do
      errors = Validator.validate_gateway(%{web_port: nil}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.web_port"))
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

    test "validates file_path" do
      errors = Validator.validate_logging(%{file_path: ""}, [])
      assert Enum.any?(errors, &String.contains?(&1, "logging.file_path"))

      errors = Validator.validate_logging(%{file_path: "/valid/path.log"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "logging.file_path"))
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
    test "validates timeout_ms" do
      errors = Validator.validate_tools(%{timeout_ms: -1}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tools.timeout_ms"))

      errors = Validator.validate_tools(%{timeout_ms: 0}, [])
      refute Enum.any?(errors, &String.contains?(&1, "tools.timeout_ms"))
    end

    test "validates max_file_size_mb" do
      errors = Validator.validate_tools(%{max_file_size_mb: 0}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tools.max_file_size_mb"))

      errors = Validator.validate_tools(%{max_file_size_mb: 10}, [])
      refute Enum.any?(errors, &String.contains?(&1, "tools.max_file_size_mb"))
    end
  end

  describe "validate_tui/2" do
    test "validates theme" do
      valid_themes = [:default, :dark, :light, :high_contrast]

      for theme <- valid_themes do
        errors = Validator.validate_tui(%{theme: theme}, [])
        refute Enum.any?(errors, &String.contains?(&1, "tui.theme")),
               "Theme #{theme} should be valid"
      end

      errors = Validator.validate_tui(%{theme: :invalid}, [])
      assert Enum.any?(errors, &String.contains?(&1, "tui.theme"))
    end
  end

  describe "nil values" do
    test "accepts nil for optional fields" do
      config = %Modular{
        agent: %{
          default_model: "test-model",
          max_iterations: nil,
          timeout_seconds: nil,
          enable_approval: nil
        },
        gateway: %{
          web_port: nil
        },
        logging: %{
          level: nil,
          file_path: nil
        },
        providers: %{
          providers: nil
        },
        tools: %{
          timeout_ms: nil
        },
        tui: %{
          theme: nil
        }
      }

      assert :ok = Validator.validate(config)
    end
  end
end
