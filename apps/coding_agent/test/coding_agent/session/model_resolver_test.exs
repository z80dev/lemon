Code.require_file(
  "../../../../../scripts/support/custom_pool_discovery_probe.exs",
  __DIR__
)

Code.require_file(
  "../../../../../scripts/support/preset_native_scope_probe.exs",
  __DIR__
)

defmodule CodingAgent.Session.ModelResolverTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager

  setup do
    saved_env =
      Map.new(
        ~w(OPENAI_API_KEY AZURE_OPENAI_API_KEY LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL),
        fn key -> {key, System.get_env(key)} end
      )

    System.delete_env("OPENAI_API_KEY")
    System.delete_env("AZURE_OPENAI_API_KEY")
    System.delete_env("LEMON_DEFAULT_PROVIDER")
    System.delete_env("LEMON_DEFAULT_MODEL")

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

  test "public catalog discovery and native resolution preserve the selected credential pool" do
    home =
      Path.join(System.tmp_dir!(), "catalog_pool_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    report = LemonScripts.CustomPoolDiscoveryProbe.run!(home)
    assert report.loopback_requests == 5
    assert report.principals == [:a, :b, :c, :missing]
  end

  test "dynamic preset metadata follows the native endpoint and selected principal" do
    home =
      Path.join(
        System.tmp_dir!(),
        "preset_native_scope_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    report = LemonScripts.PresetNativeScopeProbe.run!(home)
    assert report.failures == []
    assert report.loopback_requests == 12
  end

  test "explicit preset model structs retain caller metadata when the endpoint is overridden" do
    model = %LemonAi.Types.Model{
      provider: :ollama,
      id: "caller-model",
      api: :openai_completions,
      base_url: "http://caller.invalid/v1",
      context_window: 2_048,
      max_tokens: 512,
      reasoning: true,
      input: [:text, :image]
    }

    settings = %SettingsManager{
      providers: %{"ollama" => %{base_url: "http://configured.invalid/v1"}}
    }

    assert ModelResolver.resolve_session_model(model, settings) ==
             %{model | base_url: "http://configured.invalid/v1"}
  end

  test "preset aliases synthesize with the effective provider configuration" do
    settings = %SettingsManager{
      providers: %{
        "llama.cpp" => %{
          base_url: "http://configured.invalid/v1",
          headers: %{"X-Team" => "configured"}
        }
      }
    }

    for selector <- ["llama.cpp:uncached", "llama_cpp:uncached", "llama-cpp/uncached"] do
      model = ModelResolver.resolve_session_model(selector, settings)

      assert {model.provider, model.id, model.base_url} ==
               {:llama_cpp, "uncached", "http://configured.invalid/v1"}

      assert model.context_window == 128_000
      assert model.input == [:text]
      refute model.reasoning
      assert model.headers == %{"x-team" => "configured"}
    end

    settings = %{
      settings
      | default_model: %{
          provider: :llama_cpp,
          model_id: "uncached",
          base_url: "http://default.invalid/v1"
        }
    }

    assert ModelResolver.resolve_session_model(nil, settings).base_url ==
             "http://configured.invalid/v1"
  end

  test "in-memory persisted atom providers retain their API when restoring a branch" do
    session =
      CodingAgent.SessionManager.new("/workspace")
      |> CodingAgent.SessionManager.append_entry(
        CodingAgent.SessionManager.SessionEntry.model_change(:"openai-codex", "gpt-6.1-sol")
      )

    context = CodingAgent.SessionManager.build_session_context(session)
    model = ModelResolver.resolve_session_model(context.model, %SettingsManager{})
    assert model.provider == :"openai-codex"
    assert model.api == :openai_codex_responses
    assert model.id == "gpt-6.1-sol"
  end

  test "qualified custom defaults use the same model as an explicit selector" do
    providers = %{
      "resolver-gateway" => %{
        api: "openai_completions",
        base_url: "http://127.0.0.1:1/v1",
        auth: "none",
        models: [%{id: "execution"}]
      }
    }

    for selector <- ["resolver-gateway:execution", "resolver-gateway/execution"] do
      agent =
        LemonCore.Config.Agent.resolve(%{
          "defaults" => %{"model" => selector},
          "runtime" => %{"provider_routing" => %{"enabled" => false}}
        })

      settings =
        SettingsManager.from_config(%LemonCore.Config{
          agent: Map.from_struct(agent),
          providers: providers
        })

      model = ModelResolver.resolve_session_model(nil, settings)
      assert model == ModelResolver.resolve_session_model(selector, settings)

      assert {model.provider, model.id, model.api} ==
               {"resolver-gateway", "execution", :openai_completions}

      assert model.base_url == "http://127.0.0.1:1/v1"
      assert model.compat.allow_missing_api_key
    end
  end

  test "a qualified default routes candidates for its selected provider and unqualified id" do
    settings = %SettingsManager{
      default_model: %{provider: :anthropic, model_id: "openai:gpt-4", base_url: nil},
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
    assert {model.provider, model.id} == {:azure_openai_responses, "gpt-4"}
  end

  test "default resolution preserves provider-native colon ids" do
    settings = %SettingsManager{
      default_model: %{provider: :ollama, model_id: "qwen3:32b", base_url: nil},
      provider_routing: %{enabled: false}
    }

    model = ModelResolver.resolve_session_model(nil, settings)
    assert {model.provider, model.id, model.api} == {:ollama, "qwen3:32b", :openai_completions}
  end

  test "cold preset defaults preserve native colon ids with registered provider prefixes" do
    base_url = "http://127.0.0.1:1/cold-#{System.unique_integer([:positive])}/v1"

    settings = %SettingsManager{
      default_model: %{provider: :ollama, model_id: "qwen:7b"},
      providers: %{
        "ollama" => %{base_url: base_url, headers: %{"X-Team" => "cold-native"}}
      },
      provider_routing: %{enabled: false}
    }

    model = ModelResolver.resolve_session_model(nil, settings)
    assert {model.provider, model.id, model.api} == {:ollama, "qwen:7b", :openai_completions}
    assert model.base_url == base_url
    assert model.context_window == 128_000
    assert model.max_tokens == 8_192
    assert model.headers == %{"x-team" => "cold-native"}
    assert model.input == [:text]
    refute model.reasoning
  end

  test "a configured provider's own qualified-looking model id remains authoritative" do
    settings = %SettingsManager{
      default_model: %{provider: "resolver-gateway", model_id: "openai:gpt-4", base_url: nil},
      providers: %{
        "resolver-gateway" => %{
          api: "openai_completions",
          base_url: "http://127.0.0.1:1/v1",
          auth: "none",
          models: [%{id: "openai:gpt-4"}]
        }
      },
      provider_routing: %{enabled: false}
    }

    model = ModelResolver.resolve_session_model(nil, settings)
    assert {model.provider, model.id} == {"resolver-gateway", "openai:gpt-4"}

    assert model ==
             ModelResolver.resolve_session_model(
               %{provider: "resolver-gateway", model_id: "openai:gpt-4"},
               settings
             )
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

  test "default model canonicalizes underscored Codex config provider to its registry API" do
    settings = %SettingsManager{
      default_model: %{provider: :openai_codex, model_id: "gpt-5.6-sol", base_url: nil},
      providers: %{},
      provider_routing: %{enabled: false, fallback_providers: [], require_credentials: true}
    }

    model = ModelResolver.resolve_session_model(nil, settings)

    assert model.provider == :"openai-codex"
    assert model.api == :openai_codex_responses
    assert model.id == "gpt-5.6-sol"
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

  describe "OpenAI-compatible presets" do
    test "provider:model specs keep colons in the model id and apply the configured base url" do
      settings = %SettingsManager{
        providers: %{"lm_studio" => %{base_url: "http://gpu-box:1234/v1"}}
      }

      model = ModelResolver.resolve_session_model("ollama:qwen3:32b", settings)
      assert {model.provider, model.id, model.api} == {:ollama, "qwen3:32b", :openai_completions}
      assert model.base_url == "http://127.0.0.1:11434/v1"
      assert model.compat.allow_missing_api_key

      model = ModelResolver.resolve_session_model("lm-studio:qwen2.5-coder", settings)
      assert {model.provider, model.base_url} == {:lm_studio, "http://gpu-box:1234/v1"}

      model = ModelResolver.resolve_session_model("llama.cpp:qwen3", settings)
      assert {model.provider, model.id} == {:llama_cpp, "qwen3"}
    end

    test "a configured preset does not capture bare catalog model ids" do
      settings = %SettingsManager{
        providers: %{"together" => %{api_key: "together-key"}}
      }

      model = ModelResolver.resolve_session_model("claude-sonnet-5", settings)
      assert model.provider == :anthropic
    end
  end

  test "ordered model fallbacks expand roles, retain same-provider models and dedup pairs" do
    agent =
      LemonCore.Config.Agent.resolve(%{
        "runtime" => %{
          "provider_routing" => %{
            "fallback_models" => [
              " openai:gpt-4 ",
              "@smol",
              "azure_openai_responses:gpt-4o",
              "openai:gpt-4o"
            ],
            "fallback_providers" => ["azure_openai_responses"]
          }
        }
      })

    settings =
      SettingsManager.from_config(%LemonCore.Config{
        agent: Map.from_struct(agent),
        model_roles: %{"smol" => "openai:gpt-4o"},
        providers: %{
          "openai" => %{api_key: "fake"},
          "azure_openai_responses" => %{api_key: "fake"}
        }
      })

    primary = LemonAi.Models.get_model(:openai, "gpt-4")

    assert Enum.map(
             ModelResolver.runtime_fallback_models(primary, settings),
             &{&1.provider, &1.id}
           ) ==
             [
               {:openai, "gpt-4o"},
               {:azure_openai_responses, "gpt-4o"},
               {:azure_openai_responses, "gpt-4"}
             ]
  end

  test "auto thinking prefers configured tiny and applies the destination base URL" do
    settings = %SettingsManager{
      model_roles: %{
        "tiny" => "@classifier",
        "classifier" => "openai:gpt-4o",
        "smol" => "openai:gpt-4"
      },
      providers: %{"openai" => %{base_url: "https://fake.invalid/v1"}}
    }

    assert %{provider: :openai, id: "gpt-4o", base_url: "https://fake.invalid/v1"} =
             ModelResolver.resolve_auto_thinking_model(settings)
  end

  test "auto thinking tries configured smol when tiny cannot resolve" do
    settings = %SettingsManager{
      model_roles: %{"tiny" => "missing-provider:missing", "smol" => "openai:gpt-4o"}
    }

    assert %{id: "gpt-4o"} = ModelResolver.resolve_auto_thinking_model(settings)
  end

  test "auto thinking never falls back to the active or default model" do
    for roles <- [
          %{},
          %{"tiny" => "@default"},
          %{"tiny" => "@smol"},
          %{"tiny" => "missing-provider:missing"}
        ] do
      settings = %SettingsManager{
        default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
        model_roles: roles
      }

      assert ModelResolver.resolve_auto_thinking_model(settings) == nil
    end
  end
end
