defmodule LemonAgent.ModelRuntime.ProviderNamesTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, ModelCatalog, ProviderNames}
  alias LemonAi.ModelCache

  @env_keys ~w(
    GROQ_API_KEY XAI_API_KEY CEREBRAS_API_KEY DEEPSEEK_API_KEY MISTRAL_API_KEY
    HUGGINGFACE_HUB_TOKEN HF_TOKEN DASHSCOPE_API_KEY AI_GATEWAY_API_KEY
    TOGETHER_API_KEY OLLAMA_API_KEY LM_STUDIO_API_KEY LLAMA_CPP_API_KEY VLLM_API_KEY
    LITELLM_API_KEY OLLAMA_CLOUD_API_KEY OLLAMA_BASE_URL OLLAMA_HOST LM_STUDIO_BASE_URL
    LLAMA_CPP_BASE_URL LITELLM_BASE_URL OPENAI_API_KEY
  )

  setup do
    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    ModelCache.invalidate_all()

    on_exit(fn ->
      System.delete_env("LEMON_SECRETS_MASTER_KEY")
      ModelCache.invalidate_all()

      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "catalog providers carry omp env vars and default secrets" do
    expected = %{
      "groq" => ["GROQ_API_KEY"],
      "xai" => ["XAI_API_KEY"],
      "cerebras" => ["CEREBRAS_API_KEY"],
      "deepseek" => ["DEEPSEEK_API_KEY"],
      "mistral" => ["MISTRAL_API_KEY"],
      "huggingface" => ["HUGGINGFACE_HUB_TOKEN", "HF_TOKEN"],
      "qwen" => ["DASHSCOPE_API_KEY"],
      "vercel_ai_gateway" => ["AI_GATEWAY_API_KEY"]
    }

    for {provider, vars} <- expected do
      assert ProviderNames.env_vars(provider) == vars
      assert ProviderNames.default_secret_name(provider) == "llm_#{provider}_api_key"
      assert ProviderNames.provider_atom(provider) == String.to_existing_atom(provider)
    end

    assert ProviderNames.canonical_name("vercel-ai-gateway") == "vercel_ai_gateway"
    assert ProviderNames.canonical_name("hf") == "huggingface"
  end

  test "presets are named, aliased and keyless per omp" do
    assert ProviderNames.canonical_name("lm-studio") == "lm_studio"
    assert ProviderNames.canonical_name("llama.cpp") == "llama_cpp"
    assert ProviderNames.canonical_name("ollama-cloud") == "ollama_cloud"
    assert ProviderNames.provider_atom("llama.cpp") == :llama_cpp
    assert ProviderNames.env_vars(:ollama) == ["OLLAMA_API_KEY"]
    assert ProviderNames.env_vars("ollama-cloud") == ["OLLAMA_CLOUD_API_KEY"]
    assert ProviderNames.env_vars(:together) == ["TOGETHER_API_KEY"]
    assert ProviderNames.default_secret_name("lm-studio") == "llm_lm_studio_api_key"

    for provider <- ~w(ollama lm_studio llama_cpp vllm litellm),
        do: assert(ProviderNames.keyless?(provider))

    for provider <- ~w(ollama_cloud together anthropic),
        do: refute(ProviderNames.keyless?(provider))

    assert ProviderNames.provider_config(%{"llama.cpp" => %{base_url: "http://x/v1"}}, :llama_cpp) ==
             %{base_url: "http://x/v1"}
  end

  test "keyless local presets are credential-ready; cloud presets need a key" do
    assert Credentials.provider_has_credentials?(:ollama, %{})
    assert Credentials.provider_has_credentials?("lm-studio", %{})
    refute Credentials.provider_has_credentials?(:together, %{})
    refute Credentials.provider_has_credentials?(:deepseek, %{})

    System.put_env("TOGETHER_API_KEY", "together-key")
    assert Credentials.provider_has_credentials?(:together, %{})
    assert Credentials.build_get_api_key(%{}).(:together) == "together-key"

    System.put_env("DEEPSEEK_API_KEY", "deepseek-key")
    assert Credentials.build_get_api_key(%{}).(:deepseek) == "deepseek-key"
  end

  describe "ModelCatalog.available_models/1" do
    defp catalog_config(providers), do: %{providers: providers, agent: %{}}

    test "includes discovered models for configured local presets and keyed cloud presets" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.host, conn.request_path, conn.req_headers})

        case conn.host do
          "ollama.test" ->
            case conn.request_path do
              "/api/tags" ->
                Req.Test.json(conn, %{"models" => [%{"name" => "qwen3:32b"}]})

              "/api/show" ->
                Req.Test.json(conn, %{"model_info" => %{"qwen3.context_length" => 40_960}})
            end

          "api.together.xyz" ->
            Req.Test.json(conn, %{"data" => [%{"id" => "moonshotai/Kimi-K2.7-Code"}]})
        end
      end)

      System.put_env("TOGETHER_API_KEY", "together-key")

      cfg = catalog_config(%{"ollama" => %{base_url: "http://ollama.test:11434/v1"}})

      models =
        ModelCatalog.available_models(
          config: cfg,
          preset_req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert %{context_window: 40_960, base_url: "http://ollama.test:11434/v1"} =
               Enum.find(models, &(&1.provider == :ollama and &1.id == "qwen3:32b"))

      assert Enum.any?(
               models,
               &(&1.provider == :together and &1.id == "moonshotai/Kimi-K2.7-Code")
             )

      assert_receive {:request, "api.together.xyz", "/v1/models", headers}
      assert {"authorization", "Bearer together-key"} in headers

      # Unconfigured local servers are never probed.
      refute_received {:request, "127.0.0.1", _, _}
      refute Enum.any?(models, &(&1.provider in [:lm_studio, :llama_cpp, :vllm, :litellm]))
    end

    test "an unreachable preset endpoint contributes no models" do
      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))

      cfg = catalog_config(%{"lm-studio" => %{base_url: "http://lmstudio.test:1234/v1"}})

      models =
        ModelCatalog.available_models(
          config: cfg,
          preset_req_options: [plug: {Req.Test, __MODULE__}],
          preset_discovery_timeout_ms: 200
        )

      refute Enum.any?(models, &(&1.provider == :lm_studio))
    end
  end
end
