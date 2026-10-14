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

  test "preset providers answer any model id; bare-id lookups never synthesize" do
    assert %Model{
             id: "qwen3:32b",
             provider: :ollama,
             api: :openai_completions,
             base_url: "http://127.0.0.1:11434/v1",
             compat: %{allow_missing_api_key: true}
           } = Models.get_model(:ollama, "qwen3:32b")

    # Hosted presets require a key: no keyless flag.
    assert %Model{compat: compat} = Models.get_model(:together, "moonshotai/Kimi-K2.7-Code")
    refute Map.has_key?(compat, :allow_missing_api_key)

    assert Models.known_model(:ollama, "qwen3:32b") == nil
    assert Models.get_model(:anthropic, "qwen3:32b") == nil
    assert Models.find_by_id("qwen3:32b") == nil
    refute Enum.any?(Models.list_models(), &Presets.preset?(&1.provider))
  end

  test "OLLAMA_BASE_URL beats OLLAMA_HOST, whose bind-address forms become client URLs" do
    with_env([{"OLLAMA_BASE_URL", nil}, {"OLLAMA_HOST", "gpu-box"}], fn ->
      assert Presets.base_url(:ollama) == "http://gpu-box:11434/v1"
    end)

    with_env([{"OLLAMA_BASE_URL", "http://ollama.lan:9999"}, {"OLLAMA_HOST", "ignored"}], fn ->
      assert Presets.base_url(:ollama) == "http://ollama.lan:9999/v1"
    end)

    assert Presets.normalize_env_base_url("OLLAMA_HOST", ":12345") == "http://127.0.0.1:12345/v1"
    assert Presets.normalize_env_base_url("OLLAMA_HOST", "[::1]") == "http://[::1]:11434/v1"
  end
end
