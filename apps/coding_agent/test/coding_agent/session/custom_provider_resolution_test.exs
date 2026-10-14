defmodule CodingAgent.Session.CustomProviderResolutionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.ModelResolver
  alias CodingAgent.SettingsManager
  alias LemonAi.Types.Model

  @env_keys ~w(MY_GATEWAY_KEY OPENAI_API_KEY)

  setup do
    saved = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)
    System.put_env("MY_GATEWAY_KEY", "gw-key")

    for provider <- [:openai, :anthropic], do: LemonAi.CircuitBreaker.reset(provider)

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  @providers %{
    "my-gateway" => %{
      api: "openai_completions",
      base_url: "https://llm.internal/v1",
      api_key_env: "MY_GATEWAY_KEY",
      headers: %{"X-Team" => "platform"},
      models: [%{id: "qwen3-coder", name: "Qwen3 Coder", context_window: 131_072}]
    },
    "local" => %{
      api: "openai_responses",
      base_url: "http://127.0.0.1:1234/v1",
      auth: "none",
      discovery: "openai"
    }
  }

  defp settings(overrides \\ %{}) do
    struct(
      %SettingsManager{
        providers: @providers,
        provider_routing: %{enabled: false, fallback_providers: [], require_credentials: true}
      },
      overrides
    )
  end

  test "explicit provider:model, provider/model and bare listed ids resolve custom models" do
    for spec <- ["my-gateway:qwen3-coder", "my-gateway/qwen3-coder", "qwen3-coder"] do
      model = ModelResolver.resolve_session_model(spec, settings())

      assert %Model{provider: "my-gateway", id: "qwen3-coder", api: :openai_completions} = model
      assert model.base_url == "https://llm.internal/v1"
      assert model.context_window == 131_072
      assert model.headers == %{"X-Team" => "platform"}
    end

    assert_raise ArgumentError, ~r/unknown model/, fn ->
      ModelResolver.resolve_session_model("my-gateway:not-listed", settings())
    end
  end

  test "discovery providers accept any model id and are keyless" do
    model = ModelResolver.resolve_session_model("local:qwen2.5-coder-7b", settings())

    assert %Model{provider: "local", id: "qwen2.5-coder-7b", api: :openai_responses} = model
    assert model.compat == %{allow_missing_api_key: true}
  end

  test "the configured default model resolves through config without creating atoms" do
    id = "gw-#{System.unique_integer([:positive])}"

    config = %LemonCore.Config{
      providers: %{id => @providers["my-gateway"]},
      agent: %{default_provider: nil, default_model: "#{id}:qwen3-coder"}
    }

    settings = SettingsManager.from_config(config)
    assert settings.default_model.provider == id
    assert_raise ArgumentError, fn -> String.to_existing_atom(String.replace(id, "-", "_")) end

    model = ModelResolver.resolve_session_model(nil, settings)
    assert %Model{provider: ^id, id: "qwen3-coder"} = model
  end

  test "a default provider with a provider-prefixed model id resolves the bare id" do
    config = %LemonCore.Config{
      providers: @providers,
      agent: %{default_provider: "my-gateway", default_model: "my-gateway:qwen3-coder"}
    }

    settings = SettingsManager.from_config(config)
    model = ModelResolver.resolve_session_model(nil, settings)
    assert %Model{provider: "my-gateway", id: "qwen3-coder", context_window: 131_072} = model
  end

  test "task and compaction selectors resolve custom models" do
    settings =
      settings(%{
        model_roles: %{"task" => "my-gateway:qwen3-coder", "compaction" => "local:summarizer"}
      })

    parent = ModelResolver.resolve_session_model("my-gateway:qwen3-coder", settings)

    assert %Model{provider: "my-gateway"} =
             ModelResolver.resolve_task_model(nil, settings, parent)

    assert %Model{provider: "local", id: "summarizer"} =
             ModelResolver.resolve_compaction_model(nil, settings, parent)
  end

  test "routing falls back to a ready custom provider offering the model id" do
    settings =
      settings(%{
        default_model: %{provider: :openai, model_id: "gpt-4o", base_url: nil},
        providers: Map.put(@providers, "openai", %{}),
        provider_routing: %{
          enabled: true,
          fallback_providers: ["local"],
          require_credentials: true
        }
      })

    model = ModelResolver.resolve_session_model(nil, settings)
    assert %Model{provider: "local", id: "gpt-4o"} = model

    primary = LemonAi.Models.get_model(:openai, "gpt-4o")

    assert [%Model{provider: "local", id: "gpt-4o"}] =
             ModelResolver.runtime_fallback_models(primary, settings)
  end
end
