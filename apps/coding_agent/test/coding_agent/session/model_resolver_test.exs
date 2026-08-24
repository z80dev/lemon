defmodule CodingAgent.Session.ModelResolverTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager

  setup do
    saved_env =
      Map.new(["OPENAI_API_KEY", "AZURE_OPENAI_API_KEY"], fn key -> {key, System.get_env(key)} end)

    System.delete_env("OPENAI_API_KEY")
    System.delete_env("AZURE_OPENAI_API_KEY")

    # Other tests in the suite may trip the global LemonAi circuit breakers
    # for these real provider names; open breakers demote candidates in
    # ProviderRouting.plan/3 and would reorder the assertions below.
    for provider <- [:openai, :zai, :kimi, :anthropic, :azure_openai_responses] do
      LemonAi.CircuitBreaker.reset(provider)
    end

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "default model routing falls back to a ready provider with the same model id" do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{},
        "azure_openai_responses" => %{api_key: "azure-ready-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model(nil, settings)

    assert model.provider == :azure_openai_responses
    assert model.id == "gpt-4"
  end

  test "default model routing keeps primary provider when it is ready" do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{api_key: "openai-ready-key"},
        "azure_openai_responses" => %{api_key: "azure-ready-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model(nil, settings)

    assert model.provider == :openai
    assert model.id == "gpt-4"
  end

  test "default model routing uses default profile and credential pool ordering" do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{},
        "azure_openai_responses" => %{api_key: "azure-ready-key"}
      },
      provider_routing: %{
        enabled: true,
        default_profile: "ops",
        default_pool: "burst",
        fallback_providers: [],
        credential_pools: %{
          "burst" => %{providers: ["azure_openai_responses"], strategy: "priority"}
        },
        profiles: %{
          "ops" => %{
            fallback_providers: [],
            credential_pool: "burst",
            distribution: %{"openai" => 80, "azure_openai_responses" => 20}
          }
        },
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model(nil, settings)

    assert model.provider == :azure_openai_responses
    assert model.id == "gpt-4"
  end

  test "default model routing rotates round-robin credential pools" do
    pool = "burst_#{System.unique_integer([:positive])}"

    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{},
        "azure_openai_responses" => %{api_key: "azure-ready-key"},
        "zai" => %{api_key: "zai-ready-key"}
      },
      provider_routing: %{
        enabled: true,
        default_pool: pool,
        fallback_providers: [],
        credential_pools: %{
          pool => %{providers: ["azure_openai_responses", "zai"], strategy: "round_robin"}
        },
        profiles: %{},
        require_credentials: true
      }
    }

    first = ModelResolver.resolve_session_model(nil, settings)
    second = ModelResolver.resolve_session_model(nil, settings)
    third = ModelResolver.resolve_session_model(nil, settings)

    assert first.provider == :azure_openai_responses
    assert second.provider == :zai
    assert third.provider == :azure_openai_responses
  end

  test "runtime fallback models follow profile, distribution, pool, then global ordering" do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "zai" => %{api_key: "zai-ready-key"},
        "kimi" => %{api_key: "kimi-ready-key"},
        "anthropic" => %{api_key: "anthropic-ready-key"},
        "azure_openai_responses" => %{api_key: "azure-ready-key"}
      },
      provider_routing: %{
        enabled: true,
        default_profile: "ops",
        fallback_providers: ["anthropic"],
        credential_pools: %{
          "burst" => %{providers: ["azure_openai_responses"], strategy: "priority"}
        },
        profiles: %{
          "ops" => %{
            fallback_providers: ["zai"],
            credential_pool: "burst",
            distribution: %{"kimi" => 70, "anthropic" => 30}
          }
        },
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model("openai:gpt-4", settings)
    candidates = ModelResolver.runtime_fallback_models(model, settings)

    # Same ordering routing_fallback_providers/2 produced before the shared
    # plan: profile fallbacks -> distribution (desc weight) -> pool providers
    # -> global fallbacks, deduped, primary provider excluded.
    assert Enum.map(candidates, &to_string(&1.provider)) ==
             ["zai", "kimi", "anthropic", "azure_openai_responses"]

    assert Enum.all?(candidates, &(&1.id == "gpt-4"))
  end

  test "runtime fallback models offer the same model id for explicit-model sessions" do
    settings = %SettingsManager{
      default_model: nil,
      providers: %{"azure_openai_responses" => %{api_key: "azure-ready-key"}},
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model("openai:gpt-4", settings)
    candidates = ModelResolver.runtime_fallback_models(model, settings)

    assert [fallback] = candidates
    assert fallback.provider == :azure_openai_responses
    assert fallback.id == "gpt-4"
  end

  test "runtime fallback models are empty when routing is disabled" do
    settings = %SettingsManager{
      default_model: nil,
      providers: %{"azure_openai_responses" => %{api_key: "azure-ready-key"}},
      provider_routing: %{
        enabled: false,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model("openai:gpt-4", settings)

    assert ModelResolver.runtime_fallback_models(model, settings) == []
  end

  test "explicit model specs are not rewritten by provider routing" do
    settings = %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{"azure_openai_responses" => %{api_key: "azure-ready-key"}},
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    model = ModelResolver.resolve_session_model("openai:gpt-4", settings)

    assert model.provider == :openai
    assert model.id == "gpt-4"
  end
end
