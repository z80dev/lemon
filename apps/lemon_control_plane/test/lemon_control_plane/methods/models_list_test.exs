defmodule LemonControlPlane.Methods.ModelsListTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.ModelsList

  test "returns the registered model catalog instead of falling back to defaults" do
    assert ModelsList.name() == "models.list"
    assert ModelsList.scopes() == [:read]

    assert {:ok,
            %{
              "models" => models,
              "summary" => summary,
              "includesCredentials" => false,
              "includesSecretValues" => false
            }} = ModelsList.handle(%{}, %{})

    assert length(models) > 3
    assert summary["source"] in ["ai_models", "fallback"]
    assert summary["total"] == length(models)
    assert summary["providerCount"] >= 1
    assert is_list(summary["providers"])
    assert is_integer(summary["visionModelCount"])
    assert is_integer(summary["thinkingModelCount"])
    assert is_integer(summary["streamingModelCount"])

    assert Enum.any?(models, fn model ->
             model["provider"] == "anthropic" and model["id"] == "claude-3-5-haiku-20241022" and
               model["maxOutput"] == 8192 and model["supportsThinking"] == false and
               model["supportsStreaming"] == true
           end)

    assert Enum.any?(models, &(&1["provider"] == "zai"))
    assert Enum.any?(models, &(&1["provider"] == "openai-codex"))
  end
end
