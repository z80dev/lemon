defmodule LemonControlPlane.Methods.ModelsListTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.ModelsList

  test "returns the registered model catalog instead of falling back to defaults" do
    assert ModelsList.name() == "models.list"
    assert ModelsList.scopes() == [:read]

    assert {:ok, %{"models" => models}} = ModelsList.handle(%{}, %{})

    assert length(models) > 3

    assert Enum.any?(models, fn model ->
             model["provider"] == "anthropic" and model["id"] == "claude-3-5-haiku-20241022" and
               model["maxOutput"] == 8192 and model["supportsThinking"] == false and
               model["supportsStreaming"] == true
           end)

    assert Enum.any?(models, &(&1["provider"] == "zai"))
    assert Enum.any?(models, &(&1["provider"] == "openai-codex"))
  end
end
