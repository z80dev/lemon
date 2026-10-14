defmodule LemonAgent.ModelRuntime.ProviderPresetsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, ModelCatalog}
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

  test "config tables for newly named providers resolve keys, including omp spellings" do
    providers = %{
      "xai" => %{api_key: "xai-key"},
      "llama.cpp" => %{api_key: "llama-key"},
      "ollama-cloud" => %{api_key: "cloud-key"}
    }

    get_api_key = Credentials.build_get_api_key(providers)
    assert get_api_key.(:xai) == "xai-key"
    assert get_api_key.(:llama_cpp) == "llama-key"
    assert get_api_key.(:ollama_cloud) == "cloud-key"

    System.put_env("HF_TOKEN", "hf-key")
    assert Credentials.build_get_api_key(%{}).(:huggingface) == "hf-key"
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

    test "configured preset discovery excludes default cached rows and keeps static overrides" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.host do
          "127.0.0.1" ->
            Req.Test.json(conn, %{
              "data" => [
                %{"id" => "old-only", "context_length" => 32_768},
                %{"id" => "shared", "context_length" => 32_768}
              ]
            })

          "configured.test" ->
            assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer configured-key"]
            assert Plug.Conn.get_req_header(conn, "x-team") == ["configured"]
            Req.Test.json(conn, %{"data" => [%{"id" => "new-only"}, %{"id" => "shared"}]})
        end
      end)

      req = [plug: {Req.Test, __MODULE__}]
      assert {:ok, _} = LemonAi.Models.discover_preset(:lm_studio, req_options: req)

      cfg =
        catalog_config(%{
          "lm-studio" => %{
            base_url: "http://configured.test:1234/v1",
            api_key: "configured-key",
            headers: %{"X-Team" => "configured"},
            models: [%{id: "shared", name: "Static Shared", max_tokens: 1024}]
          }
        })

      models =
        ModelCatalog.available_models(config: cfg, preset_req_options: req)
        |> Enum.filter(&(&1.provider == :lm_studio))

      assert Enum.sort(Enum.map(models, & &1.id)) == ["new-only", "shared"]
      shared = Enum.find(models, &(&1.id == "shared"))
      assert shared.name == "Static Shared"
      assert shared.context_window == 128_000
      assert shared.max_tokens == 1024
      assert shared.headers == %{"x-team" => "configured"}
      assert Enum.all?(models, &(&1.base_url == "http://configured.test:1234/v1"))

      Req.Test.stub(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      unreachable = catalog_config(%{"lm-studio" => %{base_url: "http://unreachable.test/v1"}})

      refute Enum.any?(
               ModelCatalog.available_models(config: unreachable, preset_req_options: req),
               &(&1.provider == :lm_studio)
             )
    end

    test "a base URL environment variable activates local preset discovery" do
      System.put_env("LM_STUDIO_BASE_URL", "http://env-configured.test:1234")

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "env-configured.test"
        assert conn.request_path == "/v1/models"
        Req.Test.json(conn, %{"data" => [%{"id" => "env-model"}]})
      end)

      models =
        ModelCatalog.available_models(
          config: catalog_config(%{}),
          preset_req_options: [plug: {Req.Test, __MODULE__}]
        )

      assert %{id: "env-model", base_url: "http://env-configured.test:1234/v1"} =
               Enum.find(models, &(&1.provider == :lm_studio))
    end
  end
end
