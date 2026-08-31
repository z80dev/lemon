defmodule LemonCore.Config.SecretsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.Secrets

  test "resolves exact source schemas with deterministic priority" do
    config =
      Secrets.resolve(%{
        "secrets" => %{
          "sources" => %{
            "helper" => %{
              "type" => "command",
              "enabled" => true,
              "priority" => 20,
              "argv" => ["vault-helper", "dump"],
              "timeout_ms" => 500,
              "max_output_bytes" => 4_096,
              "pass_env" => ["VAULT_ADDR"],
              "secret_env" => %{"VAULT_TOKEN" => "vault_bootstrap"}
            },
            "personal" => %{
              "type" => "onepassword",
              "enabled" => true,
              "priority" => 10,
              "refs" => %{"ANTHROPIC_API_KEY" => "op://Private/Anthropic/credential"}
            }
          }
        }
      })

    assert config.errors == []
    assert Enum.map(config.sources, & &1.id) == ["personal", "helper"]
    assert Enum.all?(config.sources, & &1.valid?)
  end

  test "rejects unknown keys, string enablement, shell commands, and unsafe bounds" do
    config =
      Secrets.resolve(%{
        "secrets" => %{
          "unexpected" => true,
          "sources" => %{
            "helper" => %{
              "type" => "command",
              "enabled" => "true",
              "command" => "sh -c 'printenv'",
              "argv" => ["./relative/helper"],
              "timeout_ms" => 0,
              "max_output_bytes" => 1_048_577,
              "cache_ttl_ms" => 300_001
            }
          }
        }
      })

    refute hd(config.sources).enabled
    refute hd(config.sources).valid?
    assert Enum.any?(config.errors, &String.contains?(&1, "secrets.unexpected: unknown"))
    assert Enum.any?(config.errors, &String.contains?(&1, ".command: unknown"))
    assert Enum.any?(config.errors, &String.contains?(&1, ".enabled: must be a boolean"))
    assert Enum.any?(config.errors, &String.contains?(&1, ".timeout_ms:"))
    assert Enum.any?(config.errors, &String.contains?(&1, ".max_output_bytes:"))
    assert Enum.any?(config.errors, &String.contains?(&1, ".cache_ttl_ms:"))
    refute inspect(config.errors) =~ "printenv"
  end

  test "rejects invalid 1Password refs and Bitwarden project/url option injection" do
    config =
      Secrets.resolve(%{
        "secrets" => %{
          "sources" => %{
            "op" => %{
              "type" => "onepassword",
              "enabled" => true,
              "refs" => %{"API_KEY" => "https://not-a-secret-ref"}
            },
            "bws" => %{
              "type" => "bitwarden",
              "enabled" => true,
              "project_id" => "--help",
              "server_url" => "http://vault.example.test?token=hidden"
            }
          }
        }
      })

    assert Enum.any?(config.errors, &String.contains?(&1, "op://"))
    assert Enum.any?(config.errors, &String.contains?(&1, "project_id"))
    assert Enum.any?(config.errors, &String.contains?(&1, "HTTPS URL"))
    refute inspect(config.errors) =~ "hidden"
  end
end
