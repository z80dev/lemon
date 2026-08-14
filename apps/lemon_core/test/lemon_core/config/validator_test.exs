defmodule LemonCore.Config.ValidatorTest.StubChannel do
  @behaviour LemonCore.Config.Gateway.Channel

  @impl true
  def id, do: :stub

  @impl true
  def resolve(section), do: %{resolved: true, raw: section}

  @impl true
  def enabled?(configured), do: configured

  @impl true
  def validate(section, errors) do
    if Map.get(section, :resolved), do: errors, else: ["gateway.stub: invalid" | errors]
  end
end

defmodule LemonCore.Config.ValidatorTest do
  @moduledoc """
  Tests for the Config.Validator module.

  Platform-specific validation is owned by the channel modules registered under
  `config :lemon_core, :gateway_channels` and asserted in lemon_channels'
  adapter config tests. These tests cover the generic gateway scalars and the
  hook that routes per-platform sections through registered channel modules,
  exercised with a stub.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Config.Validator
  alias LemonCore.Config.Modular

  setup do
    previous = Application.get_env(:lemon_core, :gateway_channels)
    Application.put_env(:lemon_core, :gateway_channels, [__MODULE__.StubChannel])

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:lemon_core, :gateway_channels),
        else: Application.put_env(:lemon_core, :gateway_channels, previous)
    end)

    :ok
  end

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
          enabled_channels: %{stub: false},
          channels: %{stub: %{resolved: true, raw: %{}}},
          require_engine_lock: true,
          engine_lock_timeout_ms: 30_000
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
      assert errors != []

      # Check for specific errors
      assert Enum.any?(errors, &String.contains?(&1, "agent.default_model"))
      assert Enum.any?(errors, &String.contains?(&1, "gateway.max_concurrent_runs"))
      assert Enum.any?(errors, &String.contains?(&1, "logging.level"))
    end

    test "rejects malformed provider secret references" do
      config = %Modular{
        agent: %{
          default_model: "claude-sonnet-4",
          default_provider: "anthropic"
        },
        gateway: %{},
        logging: %{},
        providers: %{
          providers: %{
            openai: %{
              api_key_secret: 123,
              oauth_secret: "",
              project_secret: "vertex_project"
            },
            amazon_bedrock: %{
              access_key_id_secret: ["bad"],
              secret_access_key_secret: "aws_secret"
            }
          }
        },
        tools: %{},
        tui: %{},
        features: %{}
      }

      assert {:error, errors} = Validator.validate(config)

      assert Enum.any?(errors, &String.contains?(&1, "providers.providers.openai.api_key_secret"))
      assert Enum.any?(errors, &String.contains?(&1, "providers.providers.openai.oauth_secret"))

      assert Enum.any?(
               errors,
               &String.contains?(&1, "providers.providers.amazon_bedrock.access_key_id_secret")
             )

      refute Enum.any?(errors, &String.contains?(&1, "project_secret"))
      refute Enum.any?(errors, &String.contains?(&1, "secret_access_key_secret"))
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

      # Legacy flat-map shape: enable_<id> flags are validated per registered id.
      errors = Validator.validate_gateway(%{enable_stub: "true"}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.enable_stub"))

      # Modular shape: flags live in enabled_channels.
      errors = Validator.validate_gateway(%{enabled_channels: %{stub: "yes"}}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.enable_stub"))

      errors = Validator.validate_gateway(%{auto_resume: true, enable_stub: false}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.auto_resume"))
      refute Enum.any?(errors, &String.contains?(&1, "gateway.enable_stub"))
    end

    test "accepts nil values" do
      errors = Validator.validate_gateway(%{}, [])
      assert errors == []
    end

    test "invokes a registered channel's validate/2 and surfaces its errors" do
      # Modular shape: the resolved section lives under channels.
      errors = Validator.validate_gateway(%{channels: %{stub: %{resolved: false}}}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.stub: invalid"))

      # Legacy flat-map shape: the section sits directly on the gateway map.
      errors = Validator.validate_gateway(%{stub: %{resolved: false}}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.stub: invalid"))

      errors = Validator.validate_gateway(%{channels: %{stub: %{resolved: true}}}, [])
      refute Enum.any?(errors, &String.contains?(&1, "gateway.stub"))
    end

    test "a non-map channel section produces a must-be-a-map error" do
      errors = Validator.validate_gateway(%{channels: %{stub: "not-a-map"}}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.stub: must be a map"))

      errors = Validator.validate_gateway(%{stub: 42}, [])
      assert Enum.any?(errors, &String.contains?(&1, "gateway.stub: must be a map"))
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
      errors =
        Validator.validate_providers(
          %{
            providers: %{anthropic: %{api_key: ""}}
          },
          []
        )

      assert Enum.any?(errors, &String.contains?(&1, "api_key"))
    end

    test "validates provider base_url" do
      errors =
        Validator.validate_providers(
          %{
            providers: %{anthropic: %{base_url: "not-a-url"}}
          },
          []
        )

      assert Enum.any?(errors, &String.contains?(&1, "base_url"))

      errors =
        Validator.validate_providers(
          %{
            providers: %{anthropic: %{base_url: "https://api.anthropic.com"}}
          },
          []
        )

      refute Enum.any?(errors, &String.contains?(&1, "base_url"))
    end

    test "accepts nil provider config" do
      errors = Validator.validate_providers(%{providers: nil}, [])
      assert errors == []
    end

    test "requires auth_source for openai-codex" do
      errors = Validator.validate_providers(%{providers: %{"openai-codex" => %{}}}, [])
      assert Enum.any?(errors, &String.contains?(&1, "openai-codex.auth_source"))
    end

    test "accepts valid openai-codex auth_source values" do
      oauth_errors =
        Validator.validate_providers(
          %{providers: %{"openai-codex" => %{auth_source: "oauth"}}},
          []
        )

      api_key_errors =
        Validator.validate_providers(
          %{providers: %{"openai-codex" => %{auth_source: "api_key"}}},
          []
        )

      refute Enum.any?(oauth_errors, &String.contains?(&1, "openai-codex.auth_source"))
      refute Enum.any?(api_key_errors, &String.contains?(&1, "openai-codex.auth_source"))
    end

    test "rejects invalid openai-codex auth_source value" do
      errors =
        Validator.validate_providers(
          %{providers: %{"openai-codex" => %{auth_source: "something_else"}}},
          []
        )

      assert Enum.any?(errors, &String.contains?(&1, "openai-codex.auth_source"))
    end

    test "anthropic auth_source is optional" do
      errors = Validator.validate_providers(%{providers: %{"anthropic" => %{}}}, [])
      refute Enum.any?(errors, &String.contains?(&1, "anthropic.auth_source"))
    end

    test "accepts valid anthropic auth_source values" do
      api_key_errors =
        Validator.validate_providers(
          %{providers: %{"anthropic" => %{auth_source: "api_key"}}},
          []
        )

      oauth_errors =
        Validator.validate_providers(
          %{providers: %{"anthropic" => %{auth_source: "oauth"}}},
          []
        )

      refute Enum.any?(api_key_errors, &String.contains?(&1, "anthropic.auth_source"))
      refute Enum.any?(oauth_errors, &String.contains?(&1, "anthropic.auth_source"))
    end

    test "rejects invalid anthropic auth_source value" do
      errors =
        Validator.validate_providers(
          %{providers: %{"anthropic" => %{auth_source: "bad_value"}}},
          []
        )

      assert Enum.any?(errors, &String.contains?(&1, "anthropic.auth_source"))
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

  describe "validate_queue_config/2" do
    test "validates queue mode" do
      errors = Validator.validate_queue_config([], %{mode: "fifo"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "lifo"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "priority"})
      assert errors == []

      errors = Validator.validate_queue_config([], %{mode: "collect"})
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

    test "example config queue section passes validation" do
      # Regression: config.example.toml uses mode = "collect" which was previously rejected
      example_queue = %{mode: "collect", cap: 50, drop: "oldest"}
      errors = Validator.validate_queue_config([], example_queue)
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
      errors =
        Validator.validate_web_dashboard_config([], %{
          secret_key_base: "${LEMON_WEB_SECRET_KEY_BASE}"
        })

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
      errors =
        Validator.validate_web_dashboard_config([], %{access_token: "${LEMON_WEB_ACCESS_TOKEN}"})

      assert errors == []
    end

    test "accepts nil web dashboard config" do
      errors = Validator.validate_web_dashboard_config([], nil)
      assert errors == []
    end

    test "validates complete web dashboard config" do
      errors =
        Validator.validate_web_dashboard_config([], %{
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

  describe "public generic helpers" do
    test "validate_boolean/3" do
      assert Validator.validate_boolean([], nil, "x") == []
      assert Validator.validate_boolean([], true, "x") == []
      assert Validator.validate_boolean([], false, "x") == []

      assert Validator.validate_boolean([], "yes", "gateway.enable_stub") ==
               ["gateway.enable_stub: must be a boolean"]
    end

    test "validate_positive_integer/3" do
      assert Validator.validate_positive_integer([], nil, "x") == []
      assert Validator.validate_positive_integer([], 5, "x") == []

      assert Validator.validate_positive_integer([], 0, "gateway.stub.limit") ==
               ["gateway.stub.limit: must be a positive integer"]

      assert Validator.validate_positive_integer([], -1, "gateway.stub.limit") ==
               ["gateway.stub.limit: must be a positive integer"]

      assert Validator.validate_positive_integer([], "5", "gateway.stub.limit") ==
               ["gateway.stub.limit: must be a positive integer"]
    end

    test "validate_non_negative_integer/3" do
      assert Validator.validate_non_negative_integer([], nil, "x") == []
      assert Validator.validate_non_negative_integer([], 0, "x") == []

      assert Validator.validate_non_negative_integer([], -1, "gateway.stub.timeout_ms") ==
               ["gateway.stub.timeout_ms: must be a non-negative integer"]
    end

    test "validate_ratio/3" do
      assert Validator.validate_ratio([], nil, "x") == []
      assert Validator.validate_ratio([], 0.0, "x") == []
      assert Validator.validate_ratio([], 1.0, "x") == []
      assert Validator.validate_ratio([], 0.5, "x") == []

      assert Validator.validate_ratio([], 1.5, "gateway.stub.ratio") ==
               ["gateway.stub.ratio: must be between 0.0 and 1.0"]

      assert Validator.validate_ratio([], "0.5", "gateway.stub.ratio") ==
               ["gateway.stub.ratio: must be a number between 0.0 and 1.0"]
    end

    test "env_var_reference?/1" do
      assert Validator.env_var_reference?("${MY_SECRET}") == true
      assert Validator.env_var_reference?("MY_SECRET") == false
      assert Validator.env_var_reference?("${UNCLOSED") == false
      assert Validator.env_var_reference?(nil) == false
      assert Validator.env_var_reference?(123) == false
    end
  end

  describe "validate_email_config/2" do
    test "validates email inbound config" do
      errors =
        Validator.validate_email_config([], %{
          inbound: %{
            bind_host: "0.0.0.0",
            bind_port: 8080,
            token: "webhook-secret-token",
            max_body_bytes: 10_000_000
          }
        })

      assert errors == []

      # Invalid port
      errors =
        Validator.validate_email_config([], %{
          inbound: %{bind_port: 70_000}
        })

      assert Enum.any?(errors, &String.contains?(&1, "bind_port"))

      # Empty host
      errors =
        Validator.validate_email_config([], %{
          inbound: %{bind_host: ""}
        })

      assert Enum.any?(errors, &String.contains?(&1, "bind_host"))
    end

    test "validates email outbound config" do
      errors =
        Validator.validate_email_config([], %{
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
      errors =
        Validator.validate_email_config([], %{
          outbound: %{port: 0}
        })

      assert Enum.any?(errors, &String.contains?(&1, "port"))

      # Empty relay
      errors =
        Validator.validate_email_config([], %{
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
      errors =
        Validator.validate_email_config([], %{
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
  end
end
