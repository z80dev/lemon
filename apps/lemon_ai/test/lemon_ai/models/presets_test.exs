defmodule LemonAi.Models.PresetsTest do
  use ExUnit.Case, async: false

  alias LemonAi.{ModelCache, Models}
  alias LemonAi.Models.Presets
  alias LemonAi.Types.Model

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    ModelCache.invalidate_all()
    on_exit(&ModelCache.invalidate_all/0)
    :ok
  end

  defp with_env(vars, fun) do
    previous = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end

  test "local presets are keyless with omp default endpoints" do
    expected = %{
      ollama: "http://127.0.0.1:11434/v1",
      lm_studio: "http://127.0.0.1:1234/v1",
      llama_cpp: "http://127.0.0.1:8080/v1",
      vllm: "http://127.0.0.1:8000/v1",
      litellm: "http://localhost:4000/v1"
    }

    for {id, base_url} <- expected do
      preset = Presets.get(id)
      assert preset.base_url == base_url
      assert preset.local and preset.keyless
      assert Presets.keyless?(id)
    end

    refute Presets.keyless?(:together)
    refute Presets.keyless?(:anthropic)
    assert Presets.get(:ollama).discovery == :ollama
    assert Presets.get(:ollama_cloud).discovery == :ollama
    assert Presets.get(:together).discovery == :openai_models
  end

  test "resolve maps omp ids and aliases without creating atoms" do
    assert Presets.resolve("lm-studio") == :lm_studio
    assert Presets.resolve("llama.cpp") == :llama_cpp
    assert Presets.resolve("ollama-cloud") == :ollama_cloud
    assert Presets.resolve(:ollama) == :ollama
    assert Presets.resolve(" Together ") == :together
    assert Presets.resolve("no-such-provider-#{System.unique_integer()}") == nil
  end

  test "get_model synthesizes any id for presets with conservative defaults" do
    assert %Model{
             id: "qwen3:32b",
             name: "qwen3:32b",
             provider: :ollama,
             api: :openai_completions,
             base_url: "http://127.0.0.1:11434/v1",
             context_window: 128_000,
             max_tokens: 8_192,
             input: [:text],
             reasoning: false,
             compat: %{allow_missing_api_key: true}
           } = Models.get_model(:ollama, "qwen3:32b")

    assert %Model{provider: :together, max_tokens: 16_384, compat: compat} =
             Models.get_model(:together, "moonshotai/Kimi-K2.7-Code")

    refute Map.has_key?(compat, :allow_missing_api_key)
    assert Models.get_model(:ollama, "") == nil
    assert Models.known_model(:ollama, "qwen3:32b") == nil
    assert Models.get_model(:anthropic, "qwen3:32b") == nil
  end

  test "registry listings include presets but stay static and offline" do
    providers = Models.get_providers()
    assert :ollama in providers and :lm_studio in providers and :together in providers
    assert Models.get_models(:ollama) == []
    assert Models.get_model_ids(:ollama) == []
    refute Enum.any?(Models.list_models(), &Presets.preset?(&1.provider))
    assert Models.find_by_id("qwen3:32b") == nil
  end

  test "base_url honors omp base-url environment variables" do
    with_env(
      [
        {"OLLAMA_BASE_URL", nil},
        {"OLLAMA_HOST", "gpu-box"},
        {"LLAMA_CPP_BASE_URL", "http://llama.lan:8080/"},
        {"LM_STUDIO_BASE_URL", nil}
      ],
      fn ->
        assert Presets.base_url(:ollama) == "http://gpu-box:11434/v1"
        assert Presets.base_url(:llama_cpp) == "http://llama.lan:8080/v1"
        assert Presets.base_url(:lm_studio) == "http://127.0.0.1:1234/v1"
      end
    )

    with_env([{"OLLAMA_BASE_URL", "http://ollama.lan:9999"}, {"OLLAMA_HOST", "ignored"}], fn ->
      assert Presets.base_url(:ollama) == "http://ollama.lan:9999/v1"
    end)

    assert Presets.normalize_env_base_url("OLLAMA_HOST", ":12345") == "http://127.0.0.1:12345/v1"

    assert Presets.normalize_env_base_url("OLLAMA_HOST", "https://ollama.example") ==
             "https://ollama.example/v1"

    assert Presets.normalize_env_base_url("OLLAMA_HOST", "[::1]") == "http://[::1]:11434/v1"
  end

  test "env_api_key reads only the preset's own variables" do
    with_env(
      [
        {"TOGETHER_API_KEY", "together-key"},
        {"DEEPINFRA_API_KEY", nil},
        {"OPENAI_API_KEY", "openai-key"}
      ],
      fn ->
        assert Presets.env_api_key(:together) == "together-key"
        assert Presets.env_api_key(:deepinfra) == nil
        assert Presets.env_api_key(:anthropic) == nil
      end
    )
  end
end
