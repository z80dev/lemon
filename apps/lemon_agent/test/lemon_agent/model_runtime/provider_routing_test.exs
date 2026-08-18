defmodule LemonAgent.ModelRuntime.ProviderRoutingTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ProviderRouting
  alias LemonCore.Config

  defp config(routing, agent_extra \\ %{}) do
    %Config{agent: Map.merge(%{provider_routing: routing}, agent_extra)}
  end

  defp provider_ids(candidates), do: Enum.map(candidates, & &1.provider)

  defp open_breaker!(provider_atom) do
    {:ok, _} = LemonAi.CircuitBreaker.ensure_started(provider_atom, failure_threshold: 1)

    Enum.each(1..20, fn _ ->
      LemonAi.CircuitBreaker.record_failure(provider_atom, :test_failure)
    end)

    assert LemonAi.CircuitBreaker.open?(provider_atom)
  end

  defp rotation_config do
    config(%{
      enabled: true,
      default_pool: "burst",
      fallback_providers: [],
      credential_pools: %{
        "burst" => %{
          providers: ["zai", "anthropic", "openai"],
          strategy: "round_robin"
        }
      },
      require_credentials: true
    })
  end

  describe "plan/3 precedence" do
    test "orders primary, profile fallbacks, distribution, pool, then global fallbacks" do
      config =
        config(%{
          enabled: true,
          default_profile: "ops",
          fallback_providers: ["google"],
          credential_pools: %{
            "burst" => %{providers: ["openai"], strategy: "priority"}
          },
          profiles: %{
            "ops" => %{
              fallback_providers: ["kimi"],
              credential_pool: "burst",
              distribution: %{"zai" => 80, "anthropic" => 20}
            }
          },
          require_credentials: true
        })

      candidates = ProviderRouting.plan(%{"provider" => "minimax"}, config)

      assert provider_ids(candidates) == [
               "minimax",
               "kimi",
               "zai",
               "anthropic",
               "openai",
               "google"
             ]

      assert [%{role: :primary} | rest] = candidates
      assert Enum.all?(rest, &(&1.role == :fallback))

      pool_candidate = Enum.find(candidates, &(&1.provider == "openai"))
      assert pool_candidate.pool == "burst"
      assert pool_candidate.strategy == "priority"

      non_pool = Enum.find(candidates, &(&1.provider == "kimi"))
      assert non_pool.pool == nil
      assert non_pool.strategy == nil
    end

    test "explicit params fallbackProviders override configured precedence" do
      config =
        config(%{
          enabled: true,
          fallback_providers: ["google"],
          credential_pools: %{"burst" => %{providers: ["openai"], strategy: "priority"}},
          default_pool: "burst",
          require_credentials: true
        })

      candidates =
        ProviderRouting.plan(
          %{"provider" => "zai", "fallbackProviders" => ["anthropic", "kimi"]},
          config
        )

      assert provider_ids(candidates) == ["zai", "anthropic", "kimi"]
    end

    test "candidates are unique with the primary provider winning" do
      config =
        config(%{
          enabled: true,
          fallback_providers: ["zai", "anthropic", "zai"],
          require_credentials: true
        })

      candidates = ProviderRouting.plan(%{"provider" => "zai"}, config)

      assert provider_ids(candidates) == ["zai", "anthropic"]
      assert [%{provider: "zai", role: :primary} | _] = candidates
    end

    test "statuses fill known, credential readiness, and selectability" do
      config = config(%{enabled: true, fallback_providers: ["zai"], require_credentials: true})

      statuses = [
        %{
          "provider" => "openai",
          "known" => true,
          "configured" => true,
          "credentialReady" => false
        },
        %{"provider" => "zai", "known" => true, "configured" => true, "credentialReady" => true}
      ]

      [primary, fallback] =
        ProviderRouting.plan(%{"provider" => "openai"}, config, statuses: statuses)

      assert %{provider: "openai", known: true, credential_ready: false, selectable: false} =
               primary

      assert %{provider: "zai", known: true, credential_ready: true, selectable: true} = fallback
    end
  end

  describe "plan/3 circuit breaker demotion" do
    setup do
      on_exit(fn -> LemonAi.CircuitBreaker.reset(:zai) end)
      :ok
    end

    test "open-circuit candidates are demoted to the end, never dropped" do
      open_breaker!(:zai)

      config =
        config(%{
          enabled: true,
          fallback_providers: ["anthropic", "openai"],
          require_credentials: true
        })

      candidates = ProviderRouting.plan(%{"provider" => "zai"}, config)

      assert provider_ids(candidates) == ["anthropic", "openai", "zai"]

      demoted = List.last(candidates)
      assert demoted.provider == "zai"
      assert demoted.role == :primary
      assert demoted.demotions == [:circuit_open]

      assert Enum.all?(Enum.drop(candidates, -1), &(&1.demotions == []))
    end

    test "check_breakers?: false keeps the configured order" do
      open_breaker!(:zai)

      config =
        config(%{
          enabled: true,
          fallback_providers: ["anthropic", "openai"],
          require_credentials: true
        })

      candidates = ProviderRouting.plan(%{"provider" => "zai"}, config, check_breakers?: false)

      assert provider_ids(candidates) == ["zai", "anthropic", "openai"]
      assert Enum.all?(candidates, &(&1.demotions == []))
    end
  end

  describe "plan/3 rotation" do
    test "rotate?: true advances the pool per resolution under the global scope" do
      config = rotation_config()
      params = %{"model" => "rotation-model-#{System.unique_integer([:positive])}"}

      assert params |> ProviderRouting.plan(config, rotate?: true) |> provider_ids() ==
               ["zai", "anthropic", "openai"]

      assert params |> ProviderRouting.plan(config, rotate?: true) |> provider_ids() ==
               ["anthropic", "openai", "zai"]

      assert params |> ProviderRouting.plan(config, rotate?: true) |> provider_ids() ==
               ["openai", "zai", "anthropic"]
    end

    test "a stable rotation_key keeps the same rotation slot" do
      config = rotation_config()
      params = %{"model" => "rotation-model-#{System.unique_integer([:positive])}"}

      first =
        params
        |> ProviderRouting.plan(config, rotate?: true, rotation_key: "sess-a")
        |> provider_ids()

      other =
        params
        |> ProviderRouting.plan(config, rotate?: true, rotation_key: "sess-b")
        |> provider_ids()

      refute first == other

      for _ <- 1..3 do
        assert params
               |> ProviderRouting.plan(config, rotate?: true, rotation_key: "sess-a")
               |> provider_ids() == first
      end
    end

    test "rotate?: false leaves the pool order untouched" do
      config = rotation_config()
      params = %{"model" => "rotation-model-#{System.unique_integer([:positive])}"}

      for _ <- 1..3 do
        assert params |> ProviderRouting.plan(config) |> provider_ids() ==
                 ["zai", "anthropic", "openai"]
      end
    end
  end

  describe "preview/3" do
    test "renders the stable string-keyed report from the plan" do
      config =
        config(
          %{enabled: true, fallback_providers: ["zai", "anthropic"], require_credentials: true},
          %{default_provider: "openai", default_model: "gpt-5-mini"}
        )

      statuses = [
        %{
          "provider" => "openai",
          "configName" => "openai",
          "known" => true,
          "configured" => true,
          "credentialReady" => false
        },
        %{
          "provider" => "zai",
          "configName" => "zai",
          "known" => true,
          "configured" => true,
          "credentialReady" => true
        },
        %{
          "provider" => "anthropic",
          "configName" => "anthropic",
          "known" => true,
          "configured" => false,
          "credentialReady" => false
        }
      ]

      preview = ProviderRouting.preview(%{}, config, statuses)

      assert Enum.sort(Map.keys(preview)) == [
               "candidateProviders",
               "cleanup",
               "credentialPool",
               "decision",
               "enabled",
               "fallbackProviders",
               "profileDistribution",
               "requestedModel",
               "requestedProvider",
               "selectedCredentialPool",
               "selectedModel",
               "selectedProfile",
               "selectedProvider"
             ]

      assert preview["enabled"] == true
      assert preview["requestedProvider"] == "openai"
      assert preview["requestedModel"] == "gpt-5-mini"
      assert preview["selectedProvider"] == "zai"
      assert preview["selectedModel"] == "gpt-5-mini"
      assert preview["decision"] == "selected_fallback"
      assert preview["selectedProfile"] == nil
      assert preview["selectedCredentialPool"] == nil
      assert preview["fallbackProviders"] == ["zai", "anthropic"]
      assert preview["profileDistribution"] == []

      assert [
               %{
                 "provider" => "openai",
                 "role" => "primary",
                 "known" => true,
                 "configured" => true,
                 "credentialReady" => false,
                 "selected" => false,
                 "demotions" => []
               },
               %{
                 "provider" => "zai",
                 "role" => "fallback",
                 "known" => true,
                 "configured" => true,
                 "credentialReady" => true,
                 "selected" => true,
                 "demotions" => []
               },
               %{
                 "provider" => "anthropic",
                 "role" => "fallback",
                 "known" => true,
                 "configured" => false,
                 "credentialReady" => false,
                 "selected" => false,
                 "demotions" => []
               }
             ] = preview["candidateProviders"]

      assert preview["credentialPool"]["selectedPool"] == nil
      assert preview["credentialPool"]["strategy"] == "priority"
      assert preview["credentialPool"]["configuredProviders"] == []
      assert length(preview["credentialPool"]["providers"]) == 3

      assert preview["cleanup"] == %{
               "includesRawApiKeys" => false,
               "includesSecretNames" => false,
               "includesRawBaseUrls" => false,
               "includesEnvVarNames" => false
             }
    end

    test "credential pool preview surfaces credential counts only" do
      config =
        config(
          %{
            enabled: true,
            default_pool: "burst",
            fallback_providers: [],
            credential_pools: %{
              "burst" => %{
                providers: ["openai", "zai"],
                strategy: "priority",
                credentials: %{
                  "openai" => [
                    %{source: :secret, name: "llm_openai_api_key_alt"},
                    %{source: :env, name: "OPENAI_API_KEY_2"}
                  ],
                  "zai" => [%{source: :secret, name: "llm_zai_api_key"}]
                }
              }
            },
            require_credentials: true
          },
          %{default_provider: "openai"}
        )

      preview = ProviderRouting.preview(%{}, config, [])

      assert preview["credentialPool"]["selectedPool"] == "burst"

      assert preview["credentialPool"]["credentialCounts"] == %{
               "openai" => 2,
               "zai" => 1
             }

      # Counts only - ref names/values never enter the preview.
      refute inspect(preview) =~ "llm_openai_api_key_alt"
      refute inspect(preview) =~ "OPENAI_API_KEY_2"
    end

    test "routing_disabled decision is preserved" do
      config =
        config(
          %{enabled: false, fallback_providers: ["zai"], require_credentials: true},
          %{default_provider: "openai"}
        )

      preview = ProviderRouting.preview(%{}, config, [])

      assert preview["enabled"] == false
      assert preview["selectedProvider"] == nil
      assert preview["decision"] == "routing_disabled"
    end
  end

  describe "candidate_provider_ids/2" do
    test "returns the normalized unique candidate ids" do
      config =
        config(
          %{
            enabled: true,
            fallback_providers: ["ZAI", "anthropic", "zai"],
            require_credentials: true
          },
          %{default_provider: "openai"}
        )

      assert ProviderRouting.candidate_provider_ids(%{}, config) ==
               ["openai", "zai", "anthropic"]
    end
  end
end
