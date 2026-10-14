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

  test "preset lookups only reuse the current endpoint and account listing" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"data" => [%{"id" => "shared", "context_length" => 32_768}]})
    end)

    with_env(
      [{"LM_STUDIO_BASE_URL", "http://first.test:1234"}, {"LM_STUDIO_API_KEY", "first-key"}],
      fn ->
        assert {:ok, [first]} =
                 Models.discover_preset(:lm_studio, req_options: [plug: {Req.Test, __MODULE__}])

        assert first.base_url == "http://first.test:1234/v1"
        assert Models.get_model(:lm_studio, "shared") == first
        assert Models.known_model(:lm_studio, "shared") == first
        assert Models.get_models(:lm_studio) == [first]

        System.put_env("LM_STUDIO_API_KEY", "second-key")
        assert Models.known_model(:lm_studio, "shared") == nil
        assert Models.get_models(:lm_studio) == []
        assert Models.get_model(:lm_studio, "shared").context_window == 128_000

        System.put_env("LM_STUDIO_API_KEY", "first-key")
        System.put_env("LM_STUDIO_BASE_URL", "http://second.test:1234")
        assert Models.known_model(:lm_studio, "shared") == nil
        assert Models.get_model(:lm_studio, "shared").base_url == "http://second.test:1234/v1"

        System.put_env("LM_STUDIO_BASE_URL", "http://first.test:1234")
        assert Models.known_model(:lm_studio, "shared") == first
      end
    )
  end
end
