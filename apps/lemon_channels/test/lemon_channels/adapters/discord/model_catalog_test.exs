defmodule LemonChannels.Adapters.Discord.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Discord.ModelCatalog

  describe "provider_enabled_for_config?/2" do
    test "pool-only credentials enable a provider" do
      env_key = "POOL_DISCORD_CATALOG_ZAI_KEY"
      System.put_env(env_key, "pool-zai-key-value")
      on_exit(fn -> System.delete_env(env_key) end)

      cfg = %{
        providers: %{},
        agent: %{
          provider_routing: %{
            default_pool: "burst",
            credential_pools: %{
              "burst" => %{
                providers: ["zai"],
                strategy: "priority",
                credentials: %{"zai" => [%{source: :env, name: env_key}]}
              }
            }
          }
        }
      }

      assert ModelCatalog.provider_enabled_for_config?("zai", cfg)
      # A provider outside the pool with no other credentials stays disabled.
      refute ModelCatalog.provider_enabled_for_config?("acme-nonexistent", cfg)
    end
  end
end
