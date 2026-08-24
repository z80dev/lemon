defmodule LemonRouter.ModelSelectionTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ModelSelection

  test "resolves the highest-precedence model and returns model-only output" do
    assert %{model: "explicit-model"} ==
             ModelSelection.resolve(%{
               explicit_model: "explicit-model",
               meta_model: "meta-model",
               session_model: "session-model",
               profile_model: "profile-model",
               history_model: "history-model",
               default_model: "default-model"
             })

    assert %{model: "session-model"} ==
             ModelSelection.resolve(%{
               explicit_model: nil,
               meta_model: nil,
               session_model: "session-model",
               profile_model: "profile-model",
               history_model: "history-model",
               default_model: "default-model"
             })
  end

  test "uses history_model when higher-precedence slots are empty" do
    assert %{model: "history-model"} ==
             ModelSelection.resolve(%{
               explicit_model: nil,
               meta_model: nil,
               session_model: nil,
               profile_model: nil,
               history_model: "history-model",
               default_model: "default-model"
             })
  end

  test "does not let history_model override profile_model" do
    assert %{model: "profile-model"} ==
             ModelSelection.resolve(%{
               profile_model: "profile-model",
               history_model: "history-model",
               default_model: "default-model"
             })
  end

  test "falls through to default_model when history_model is nil" do
    assert %{model: "default-model"} ==
             ModelSelection.resolve(%{
               history_model: nil,
               default_model: "default-model"
             })
  end

  test "normalizes a selected model without introducing routing fields" do
    assert %{model: "model-name"} ==
             ModelSelection.resolve(%{
               explicit_model: "  model-name  ",
               default_model: "default-model"
             })
  end
end
