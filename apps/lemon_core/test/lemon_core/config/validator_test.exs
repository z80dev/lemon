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

  alias LemonCore.Config.Modular
  alias LemonCore.Config.Validator

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
          channels: %{stub: %{resolved: true, raw: %{}}}
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

      assert Enum.any?(errors, &String.contains?(&1, "providers.openai.api_key_secret"))
      assert Enum.any?(errors, &String.contains?(&1, "providers.openai.oauth_secret"))

      assert Enum.any?(
               errors,
               &String.contains?(&1, "providers.amazon_bedrock.access_key_id_secret")
             )

      refute Enum.any?(errors, &String.contains?(&1, "project_secret"))
      refute Enum.any?(errors, &String.contains?(&1, "secret_access_key_secret"))
    end

    test "provider paths match TOML and values never appear in diagnostics" do
      secret = "credential-that-must-not-be-echoed"

      for value <- [secret, %{secret => secret}, [secret], false, 123] do
        errors =
          Validator.validate_providers(
            %{
              providers: %{
                "custom" => %{api: value},
                "openai-codex" => %{auth_source: value, api_key_secret: [secret]},
                "anthropic" => %{auth_source: value, base_url: "ftp://invalid"}
              }
            },
            []
          )

        assert Enum.any?(errors, &String.starts_with?(&1, "providers.custom.api:"))
        assert Enum.any?(errors, &String.starts_with?(&1, "providers.anthropic.base_url:"))
        refute Enum.any?(errors, &String.contains?(&1, "providers.providers."))
        refute Enum.any?(errors, &String.contains?(&1, secret))
        refute Enum.any?(errors, &String.contains?(&1, "%{"))
      end
    end
  end

  describe "validate_deprecated_sections/1" do
    test "rejects removed engine routing settings at every configuration level" do
      settings = %{
        "engine" => "codex",
        "defaults" => %{"engine" => "codex"},
        "runtime" => %{"default_engine" => "claude"},
        "gateway" => %{
          "default_engine" => "codex",
          "engines" => %{"custom" => %{"command" => "custom-cli"}},
          "projects" => %{"workspace" => %{"default_engine" => "claude"}},
          "bindings" => [%{"default_engine" => "opencode"}],
          "webhook" => %{"engine" => "pi"}
        },
        "profiles" => %{
          "default" => %{"engine" => "claude"},
          "reviewer" => %{"default_engine" => "codex"}
        },
        "custom_engine" => %{"command" => "lemon"},
        "custom_engines" => %{"local" => %{"command" => "lemon"}},
        "preferred_engine" => "claude",
        "engine_preference" => "claude",
        "preferred_engines" => ["claude", "codex"],
        "preferred-engine" => "claude",
        "preferred-engines" => ["claude", "codex"],
        "preferredEngine" => "claude",
        "preferredEngines" => ["claude", "codex"],
        "known_engine" => "claude",
        "known_engines" => ["claude", "codex"],
        "engine_registry" => %{"custom" => "Custom.Engine"},
        "engine_module" => "Custom.Engine",
        "engine_modules" => ["Custom.Engine"],
        "gateway_engines" => ["lemon"]
      }

      assert {:error, errors} = Validator.validate_deprecated_sections(settings)

      for path <- [
            "defaults.engine",
            "engine",
            "runtime.default_engine",
            "gateway.default_engine",
            "gateway.engines",
            "gateway.projects.workspace.default_engine",
            "gateway.bindings[0].default_engine",
            "gateway.webhook.engine",
            "profiles.default.engine",
            "profiles.reviewer.default_engine",
            "custom_engine",
            "custom_engines",
            "engine_preference",
            "preferred_engine",
            "preferred_engines",
            "preferred-engine",
            "preferred-engines",
            "preferredEngine",
            "preferredEngines",
            "known_engine",
            "known_engines",
            "engine_registry",
            "engine_module",
            "engine_modules",
            "gateway_engines"
          ] do
        assert Enum.any?(errors, &String.contains?(&1, path))
      end

      assert Enum.all?(errors, &String.contains?(&1, "Lemon runs natively"))
      refute Enum.any?(errors, &String.contains?(&1, "engine_lock"))
    end

    test "rejects runtime CLI settings because subagent tasks run natively" do
      settings = %{
        "runtime" => %{
          "cli" => %{
            "codex" => %{"engine" => "vendor-internal"}
          }
        }
      }

      assert {:error, errors} = Validator.validate_deprecated_sections(settings)

      assert "The [runtime.cli] section has been removed; all subagent tasks run natively." in errors
      assert Enum.any?(errors, &String.contains?(&1, "runtime.cli.codex.engine"))
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
      assert Enum.any?(errors, &String.contains?(&1, "defaults.thinking_level"))

      errors = Validator.validate_agent(%{default_thinking_level: "medium"}, [])
      refute Enum.any?(errors, &String.contains?(&1, "defaults.thinking_level"))
    end

    test "validates compaction thresholds" do
      assert [] ==
               Validator.validate_agent(
                 %{compaction: %{threshold_percent: 80, threshold_tokens: 150_000}},
                 []
               )

      assert [] == Validator.validate_agent(%{compaction: %{threshold_percent: nil}}, [])

      for percent <- [0, 101, -5, 50.5, "80"] do
        errors = Validator.validate_agent(%{compaction: %{threshold_percent: percent}}, [])
        assert Enum.any?(errors, &String.contains?(&1, "agent.compaction.threshold_percent"))
      end

      for tokens <- [0, -1, 1.5, "9000"] do
        errors = Validator.validate_agent(%{compaction: %{threshold_tokens: tokens}}, [])
        assert Enum.any?(errors, &String.contains?(&1, "agent.compaction.threshold_tokens"))
      end
    end

    test "accepts nil values" do
      errors = Validator.validate_agent(%{}, [])
      assert errors == []
    end

    test "validates runtime.task settings" do
      valid = %{
        max_depth: -1,
        max_runtime_ms: 0,
        idle_ttl_ms: 0,
        request_budget: 0,
        request_budget_notice: false,
        speculative_launch: true,
        worktree_merge: "patch",
        disabled_agents: ["scout"],
        agent_models: %{"scout" => "@smol"},
        per_call_model: "on",
        per_call_model_allow: ["openai/gpt-4o", "openrouter/qwen/qwen3:8b", "@smol"]
      }

      assert Validator.validate_agent(%{task: valid}, []) == []

      errors =
        Validator.validate_agent(
          %{
            task: %{
              max_depth: -2,
              max_runtime_ms: -1,
              idle_ttl_ms: -1,
              request_budget: -1,
              request_budget_notice: "yes",
              speculative_launch: "sometimes",
              worktree_merge: "rebase",
              disabled_agents: "scout",
              agent_models: %{"scout" => ""},
              per_call_model: "always",
              per_call_model_allow: ["gpt-4o"]
            }
          },
          []
        )

      for key <-
            ~w(max_depth max_runtime_ms idle_ttl_ms request_budget request_budget_notice speculative_launch worktree_merge disabled_agents agent_models per_call_model per_call_model_allow) do
        assert Enum.any?(errors, &String.starts_with?(&1, "runtime.task.#{key}:"))
      end
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

    test "accepts omp_broker on any provider and scopes omp_provider/omp_account to it" do
      errors =
        Validator.validate_providers(
          %{
            providers: %{
              "openai-codex" => %{auth_source: "omp_broker", omp_account: "account:a"},
              "anthropic" => %{auth_source: "omp_broker"},
              "my-xai" => %{auth_source: "omp_broker", omp_provider: "xai-oauth"}
            }
          },
          []
        )

      assert errors == []

      errors =
        Validator.validate_providers(
          %{
            providers: %{
              "anthropic" => %{auth_source: "oauth", omp_account: "account:a"},
              "openrouter" => %{omp_provider: 42}
            }
          },
          []
        )

      assert ~s(providers.anthropic.omp_account: requires auth_source = "omp_broker") in errors
      assert "providers.openrouter.omp_provider: must be a string (got integer)" in errors
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

    test "kimi_coding auth_source is optional and accepts OAuth, API keys, and omp" do
      for name <- [:kimi_coding, "kimi_coding", "kimi-coding", "kimi-for-coding"],
          source <- [nil, "oauth", "api_key", "omp", " OMP "] do
        assert Validator.validate_providers(
                 %{providers: %{name => %{auth_source: source}}},
                 []
               ) == []
      end
    end

    test "validates kimi_coding auth_source without exposing invalid values" do
      secret = "private-auth-source-value"

      for source <- ["", secret, 123, true, [secret], %{"token" => secret}] do
        errors =
          Validator.validate_providers(
            %{providers: %{"kimi_coding" => %{auth_source: source}}},
            []
          )

        assert Enum.any?(errors, &String.starts_with?(&1, "providers.kimi_coding.auth_source:"))
        refute Enum.any?(errors, &String.contains?(&1, secret))
      end
    end

    test "rejects omp for other providers, including the onboarding-only kimi-code alias" do
      for name <- [
            "anthropic",
            "openai-codex",
            "openai_codex",
            "openai",
            "xai",
            "kimi",
            "kimi-code",
            "custom"
          ],
          source <- ["omp", " OMP "] do
        errors =
          Validator.validate_providers(
            %{providers: %{name => %{auth_source: source}}},
            []
          )

        assert Enum.any?(errors, &String.starts_with?(&1, "providers.#{name}.auth_source:"))
      end
    end

    test "accepts optional absolute omp paths without checking filesystem existence" do
      for path <- [nil, "/not-installed/lemon-test/omp", "/opt/My Tools/omp"] do
        assert Validator.validate_providers(
                 %{providers: %{kimi_coding: %{auth_source: "omp", omp_path: path}}},
                 []
               ) == []
      end
    end

    test "rejects malformed omp paths without exposing their values" do
      secret = "private-omp-path"

      for path <- [
            "",
            " ",
            "omp",
            "./omp",
            "~/.bun/bin/omp",
            "/",
            "/opt/bin/",
            "/#{secret}\0/omp",
            <<"/opt/", 255>>,
            123,
            true,
            [secret],
            %{"path" => secret}
          ] do
        errors =
          Validator.validate_providers(
            %{providers: %{kimi_coding: %{auth_source: "omp", omp_path: path}}},
            []
          )

        assert Enum.any?(errors, &String.starts_with?(&1, "providers.kimi_coding.omp_path:"))
        refute Enum.any?(errors, &String.contains?(&1, secret))
      end
    end

    test "validates configured omp_path even when another Kimi auth mode is selected" do
      errors =
        Validator.validate_providers(
          %{providers: %{kimi_coding: %{auth_source: "oauth", omp_path: "relative/omp"}}},
          []
        )

      assert Enum.any?(errors, &String.starts_with?(&1, "providers.kimi_coding.omp_path:"))
    end

    test "validates string-keyed auth_source and omp_path in legacy provider maps" do
      assert Validator.validate_legacy_providers(
               %{"kimi_coding" => %{"auth_source" => "omp", "omp_path" => "/opt/bin/omp"}},
               []
             ) == []

      errors =
        Validator.validate_legacy_providers(
          %{
            "kimi_coding" => %{"auth_source" => "invalid", "omp_path" => "relative/omp"},
            "openai" => %{"auth_source" => "omp"}
          },
          []
        )

      for path <- [
            "providers.kimi_coding.auth_source:",
            "providers.kimi_coding.omp_path:",
            "providers.openai.auth_source:"
          ] do
        assert Enum.any?(errors, &String.starts_with?(&1, path))
      end
    end
  end

  describe "validate_tools/2" do
    test "validates the computer_use section" do
      ok = %{
        computer_use: %{
          enabled: true,
          lcu_root: "/opt/lcu/current",
          node: nil,
          declined_origins: ["https://bot.example.ts.net", "http://127.0.0.1:4081"],
          lasting_grant_apps: ["com.apple.calculator"]
        }
      }

      assert Validator.validate_tools(ok, []) == []

      bad = %{
        computer_use: %{
          enabled: "yes",
          lcu_root: "",
          declined_origins: ["ftp://x"],
          lasting_grant_apps: [""]
        }
      }

      errors = Validator.validate_tools(bad, [])

      for path <- ~w(enabled lcu_root declined_origins lasting_grant_apps) do
        assert Enum.any?(errors, &String.contains?(&1, "tools.computer_use." <> path)), path
      end
    end

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

  describe "validate_sms_config/2" do
    test "accepts the fields the SMS adapter reads, keyed as atoms or TOML strings" do
      valid = %{
        "webhook_enabled" => true,
        "webhook_port" => 4041,
        "webhook_bind" => "127.0.0.1",
        "inbox_number" => "+15550001111",
        "inbox_ttl_ms" => 86_400_000,
        "handoff_grace_ms" => 600_000,
        "auth_token_secret" => "twilio_auth_token",
        "webhook_url" => "https://example.com/webhooks/twilio/sms"
      }

      assert Validator.validate_sms_config([], valid) == []

      assert Validator.validate_sms_config(
               [],
               Map.new(valid, fn {k, v} -> {String.to_atom(k), v} end)
             ) == []
    end

    test "rejects wrongly typed string-keyed fields" do
      for {key, value} <- [
            {"webhook_enabled", "yes"},
            {"webhook_port", 70_000},
            {"webhook_bind", ""},
            {"inbox_number", 15_550_001_111},
            {"inbox_ttl_ms", 0},
            {"handoff_grace_ms", 0},
            {"auth_token", ""},
            {"auth_token_secret", 7},
            {"webhook_url", "example.com/sms"},
            {"webhook_url", "ftp://example.com/sms"},
            {"webhook_url", "https://user:pw@example.com/sms"}
          ] do
        errors = Validator.validate_sms_config([], %{key => value})

        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.sms.#{key}:")),
               "#{key}=#{inspect(value)}"
      end

      assert Validator.validate_sms_config([], "x") == ["gateway.sms: must be a map"]
    end
  end

  describe "validate_voice_config/2" do
    test "accepts the fields the voice transport reads" do
      assert Validator.validate_voice_config([], %{
               enabled: true,
               websocket_port: 4047,
               public_url: "https://voice.example.com",
               twilio_phone_number: "+15550001111",
               elevenlabs_output_format: "ulaw_8000",
               max_call_duration_seconds: 600,
               silence_timeout_ms: 5000
             }) == []
    end

    test "requires an absolute https public_url" do
      for url <- [
            "http://voice.example.com",
            "voice.example.com",
            "wss://voice.example.com",
            "https://",
            " https://voice.example.com",
            "https://voice.example.com ",
            "HTTPS://voice.example.com",
            "https://voice example.com"
          ] do
        assert "gateway.voice.public_url: must be an absolute https URL" in Validator.validate_voice_config(
                 [],
                 %{"public_url" => url}
               ),
               url
      end
    end

    test "rejects wrongly typed fields" do
      for {key, value} <- [
            {:enabled, "true"},
            {:websocket_port, 0},
            {:max_call_duration_seconds, -1},
            {:silence_timeout_ms, "5000"},
            {:twilio_auth_token, 123},
            {:llm_model, ""},
            {:public_url, 42}
          ] do
        errors = Validator.validate_voice_config([], %{key => value})

        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.voice.#{key}:")),
               "#{key}=#{inspect(value)}"
      end

      assert Validator.validate_voice_config([], "x") == ["gateway.voice: must be a map"]
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
            enabled: true,
            bind: "0.0.0.0",
            port: 8080,
            path: "/email",
            token: "webhook-secret-token"
          }
        })

      assert errors == []

      # Invalid port
      errors = Validator.validate_email_config([], %{inbound: %{port: 70_000}})
      assert "gateway.email.inbound.port: must be between 1 and 65535" in errors

      # Empty bind
      errors = Validator.validate_email_config([], %{inbound: %{bind: ""}})
      assert "gateway.email.inbound.bind: cannot be empty" in errors
    end

    test "validates nested tables keyed as decoded TOML strings" do
      errors =
        Validator.validate_email_config([], %{
          "inbound" => %{"port" => 0, "token" => ""},
          "outbound" => %{"tls" => "nope", "port" => 70_000, "ssl" => "true"}
        })

      for path <- ~w(
            gateway.email.inbound.port gateway.email.inbound.token gateway.email.outbound.tls
            gateway.email.outbound.port gateway.email.outbound.ssl
          ) do
        assert Enum.any?(errors, &String.starts_with?(&1, path <> ":")), path
      end

      assert Validator.validate_email_config([], %{"inbound" => "x"}) == [
               "gateway.email.inbound: must be a map"
             ]
    end

    test "validates flat smtp_* aliases" do
      assert Validator.validate_email_config([], %{
               smtp_relay: "smtp.example.com",
               smtp_port: 465,
               smtp_ssl: true,
               smtp_tls: "never",
               smtp_auth: "always",
               smtp_timeout: 30_000,
               smtp_tls_versions: ["tlsv1.3"]
             }) == []

      for {key, value} <- [
            smtp_relay: "",
            smtp_port: 0,
            smtp_ssl: "on",
            smtp_tls: "required",
            smtp_auth: true,
            smtp_timeout: 0,
            smtp_tls_versions: ["sslv3"]
          ] do
        errors = Validator.validate_email_config([], %{key => value})
        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.email.#{key}:")), "#{key}"
      end
    end

    test "validates inbound sender authorization keys in atom and TOML string form" do
      for inbound <- [
            %{allowed_senders: ["owner@example.com"], authserv_id: "mx.provider.test"},
            %{"allowed_senders" => [" Owner@Example.com "], "authserv_id" => "mx.provider.test"},
            %{allowed_senders: []},
            %{"sender_auth" => "from_only_unsafe"},
            %{sender_auth: "authentication_results"}
          ] do
        assert Validator.validate_email_config([], %{inbound: inbound}) == []
      end

      for {inbound, field} <- [
            {%{allowed_senders: "owner@example.com"}, "allowed_senders"},
            {%{"allowed_senders" => ["Owner <owner@example.com>"]}, "allowed_senders"},
            {%{allowed_senders: ["example.com"]}, "allowed_senders"},
            {%{allowed_senders: [42]}, "allowed_senders"},
            {%{"authserv_id" => "  "}, "authserv_id"},
            {%{authserv_id: "mx.provider.test; dmarc=pass"}, "authserv_id"},
            {%{authserv_id: :mx}, "authserv_id"},
            {%{sender_auth: "off"}, "sender_auth"},
            {%{"sender_auth" => true}, "sender_auth"}
          ] do
        errors = Validator.validate_email_config([], %{inbound: inbound})

        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.email.inbound.#{field}:")),
               "expected a #{field} error for #{inspect(inbound)}, got #{inspect(errors)}"
      end
    end

    test "validates email outbound config" do
      errors =
        Validator.validate_email_config([], %{
          outbound: %{
            relay: "smtp.gmail.com",
            port: 587,
            username: "user@example.com",
            password: "secret",
            tls: "always",
            auth: "if_available",
            hostname: "example.com",
            from: "bot@example.com"
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

    test "validates email tls and auth modes the SMTP adapter honors" do
      for key <- [:tls, :auth], mode <- ["always", "never", "if_available", " Always ", :never] do
        assert Validator.validate_email_config([], %{outbound: %{key => mode}}) == []
      end

      # Anything else would be silently replaced by the adapter's default mode.
      for key <- [:tls, :auth], mode <- [true, false, "true", "false", "invalid"] do
        errors = Validator.validate_email_config([], %{outbound: %{key => mode}})

        assert Enum.any?(errors, &String.starts_with?(&1, "gateway.email.outbound.#{key}:")),
               "#{key}=#{inspect(mode)}"
      end
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
            bind: "0.0.0.0",
            port: 8080,
            token: "webhook-secret",
            allowed_senders: ["owner@example.com"]
          },
          outbound: %{
            relay: "smtp.gmail.com",
            port: 587,
            username: "user@example.com",
            password: "secret",
            tls: "always",
            auth: "always",
            hostname: "example.com",
            from: "bot@example.com"
          },
          attachment_max_bytes: 10_000_000,
          inbound_enabled: true,
          webhook_enabled: true
        })

      assert errors == []
    end
  end
end
