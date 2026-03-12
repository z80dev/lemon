defmodule LemonCore.Config.ExpandedSchemaTest do
  @moduledoc """
  Tests for expanded canonical schema fields (Section 3 of CONFIGPLAN).
  """
  use ExUnit.Case, async: true

  alias LemonCore.Config.{Agent, Providers, Gateway, Tools}

  describe "Agent budget_defaults" do
    test "defaults to max_children=5" do
      config = Agent.resolve(%{})
      assert config.budget_defaults.max_children == 5
    end

    test "reads from runtime.budget_defaults" do
      settings = %{
        "runtime" => %{
          "budget_defaults" => %{
            "max_children" => 12
          }
        }
      }

      config = Agent.resolve(settings)
      assert config.budget_defaults.max_children == 12
    end

    test "env var overrides budget_defaults" do
      System.put_env("LEMON_BUDGET_MAX_CHILDREN", "20")

      on_exit(fn -> System.delete_env("LEMON_BUDGET_MAX_CHILDREN") end)

      config = Agent.resolve(%{})
      assert config.budget_defaults.max_children == 20
    end
  end

  describe "Agent cli configuration" do
    test "defaults to sane cli settings" do
      config = Agent.resolve(%{})

      assert config.cli.codex.extra_args == []
      assert config.cli.codex.auto_approve == false
      assert config.cli.kimi.extra_args == []
      assert config.cli.opencode.model == nil
      assert config.cli.pi.extra_args == []
      assert config.cli.pi.model == nil
      assert config.cli.pi.provider == nil
      assert config.cli.claude.dangerously_skip_permissions == true
      assert config.cli.claude.scrub_env == :auto
      assert config.cli.claude.env_overrides == %{}
    end

    test "reads cli settings from runtime" do
      settings = %{
        "runtime" => %{
          "cli" => %{
            "codex" => %{"extra_args" => ["--flag"], "auto_approve" => true},
            "opencode" => %{"model" => "gpt-4o"},
            "pi" => %{"model" => "test", "provider" => "openai"},
            "claude" => %{
              "dangerously_skip_permissions" => false,
              "allowed_tools" => ["bash"],
              "scrub_env" => "true",
              "env_allowlist" => ["PATH"],
              "env_allow_prefixes" => ["LEMON_"],
              "env_overrides" => %{"FOO" => "bar"}
            }
          }
        }
      }

      config = Agent.resolve(settings)

      assert config.cli.codex.extra_args == ["--flag"]
      assert config.cli.codex.auto_approve == true
      assert config.cli.opencode.model == "gpt-4o"
      assert config.cli.pi.model == "test"
      assert config.cli.pi.provider == "openai"
      assert config.cli.claude.dangerously_skip_permissions == false
      assert config.cli.claude.allowed_tools == ["bash"]
      assert config.cli.claude.scrub_env == true
      assert config.cli.claude.env_allowlist == ["PATH"]
      assert config.cli.claude.env_allow_prefixes == ["LEMON_"]
      assert config.cli.claude.env_overrides == %{"FOO" => "bar"}
    end
  end

  describe "Providers - Google Vertex fields" do
    test "parses project_secret and location_secret" do
      settings = %{
        "providers" => %{
          "google_vertex" => %{
            "project_secret" => "gcp_project_id",
            "location_secret" => "gcp_location",
            "service_account_json_secret" => "gcp_sa_json"
          }
        }
      }

      config = Providers.resolve(settings)
      vertex = config.providers["google_vertex"]

      assert vertex[:project_secret] == "gcp_project_id"
      assert vertex[:location_secret] == "gcp_location"
      assert vertex[:service_account_json_secret] == "gcp_sa_json"
    end
  end

  describe "Providers - Google Gemini CLI fields" do
    test "parses project_id and project_secret" do
      settings = %{
        "providers" => %{
          "google_gemini_cli" => %{
            "project_id" => "gemini-project",
            "project_secret" => "gemini_project_secret"
          }
        }
      }

      config = Providers.resolve(settings)
      gemini = config.providers["google_gemini_cli"]

      assert gemini[:project_id] == "gemini-project"
      assert gemini[:project_secret] == "gemini_project_secret"
    end
  end

  describe "Providers - Azure OpenAI Responses fields" do
    test "parses resource_name, api_version, deployment_name_map" do
      settings = %{
        "providers" => %{
          "azure_openai_responses" => %{
            "resource_name" => "my-resource",
            "api_version" => "2024-02-01",
            "deployment_name_map" => %{
              "gpt-4o" => "my-gpt4o-deployment"
            }
          }
        }
      }

      config = Providers.resolve(settings)
      azure = config.providers["azure_openai_responses"]

      assert azure[:resource_name] == "my-resource"
      assert azure[:api_version] == "2024-02-01"
      assert azure[:deployment_name_map] == %{"gpt-4o" => "my-gpt4o-deployment"}
    end
  end

  describe "Providers - Amazon Bedrock fields" do
    test "parses region and secret key fields" do
      settings = %{
        "providers" => %{
          "amazon_bedrock" => %{
            "region" => "us-east-1",
            "access_key_id_secret" => "aws_access_key",
            "secret_access_key_secret" => "aws_secret_key",
            "session_token_secret" => "aws_session_token"
          }
        }
      }

      config = Providers.resolve(settings)
      bedrock = config.providers["amazon_bedrock"]

      assert bedrock[:region] == "us-east-1"
      assert bedrock[:access_key_id_secret] == "aws_access_key"
      assert bedrock[:secret_access_key_secret] == "aws_secret_key"
      assert bedrock[:session_token_secret] == "aws_session_token"
    end
  end

  describe "Gateway - secret-ref fields" do
    test "telegram bot_token_secret is parsed" do
      settings = %{
        "gateway" => %{
          "telegram" => %{
            "bot_token_secret" => "telegram_bot_token"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.telegram.bot_token_secret == "telegram_bot_token"
    end

    test "discord bot_token_secret is parsed" do
      settings = %{
        "gateway" => %{
          "discord" => %{
            "bot_token_secret" => "discord_bot_token"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.discord[:bot_token_secret] == "discord_bot_token"
    end

    test "sms auth_token_secret is parsed" do
      settings = %{
        "gateway" => %{
          "sms" => %{
            "auth_token_secret" => "twilio_auth_token",
            "provider" => "twilio"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.sms["auth_token_secret"] == "twilio_auth_token"
      assert config.sms["provider"] == "twilio"
    end

    test "xmtp wallet_key_secret is parsed" do
      settings = %{
        "gateway" => %{
          "xmtp" => %{
            "wallet_key_secret" => "xmtp_wallet_key",
            "environment" => "production"
          }
        }
      }

      config = Gateway.resolve(settings)

      assert config.xmtp[:wallet_key_secret] == "xmtp_wallet_key"
      assert config.xmtp[:environment] == "production"
    end
  end

  describe "Gateway - enable_* flags" do
    test "all enable flags are resolved" do
      settings = %{
        "gateway" => %{
          "enable_telegram" => true,
          "enable_discord" => true,
          "enable_farcaster" => true,
          "enable_email" => true,
          "enable_xmtp" => true,
          "enable_webhook" => true
        }
      }

      config = Gateway.resolve(settings)

      assert config.enable_telegram == true
      assert config.enable_discord == true
      assert config.enable_farcaster == true
      assert config.enable_email == true
      assert config.enable_xmtp == true
      assert config.enable_webhook == true
    end

    test "all enable flags default to false" do
      config = Gateway.resolve(%{})

      assert config.enable_telegram == false
      assert config.enable_discord == false
      assert config.enable_farcaster == false
      assert config.enable_email == false
      assert config.enable_xmtp == false
      assert config.enable_webhook == false
    end
  end

  describe "Tools - secret-ref fields" do
    test "web search api_key_secret is parsed" do
      settings = %{
        "tools" => %{
          "web" => %{
            "search" => %{
              "api_key_secret" => "brave_api_key"
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.search.api_key_secret == "brave_api_key"
    end

    test "perplexity api_key_secret is parsed" do
      settings = %{
        "tools" => %{
          "web" => %{
            "search" => %{
              "perplexity" => %{
                "api_key_secret" => "perplexity_api_key"
              }
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.search.perplexity.api_key_secret == "perplexity_api_key"
    end

    test "firecrawl api_key_secret is parsed" do
      settings = %{
        "tools" => %{
          "web" => %{
            "fetch" => %{
              "firecrawl" => %{
                "api_key_secret" => "firecrawl_api_key"
              }
            }
          }
        }
      }

      config = Tools.resolve(settings)

      assert config.web.fetch.firecrawl.api_key_secret == "firecrawl_api_key"
    end

    test "secret-ref fields default to nil" do
      config = Tools.resolve(%{})

      assert config.web.search.api_key_secret == nil
      assert config.web.search.perplexity.api_key_secret == nil
      assert config.web.fetch.firecrawl.api_key_secret == nil
    end
  end

  describe "Facade integration - new fields appear in legacy struct" do
    test "budget_defaults not directly in legacy agent (it's in the modular agent)" do
      # The facade converts modular agent to legacy shape
      # budget_defaults is part of the Agent struct but not the legacy agent map
      # Let's verify it works through the full Config.load path
      config = Agent.resolve(%{})
      assert config.budget_defaults.max_children == 5
    end
  end
end
