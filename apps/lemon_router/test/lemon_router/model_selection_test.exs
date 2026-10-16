defmodule LemonRouter.ModelSelectionTest do
  use ExUnit.Case, async: false

  alias LemonRouter.ModelSelection

  test "explicit, meta and session models win and are marked explicit" do
    base = %{
      profile_model: "profile-model",
      history_model: "history-model",
      default_model: "default-model"
    }

    assert %{model: "explicit-model", model_explicit: true} ==
             ModelSelection.resolve(
               Map.merge(base, %{
                 explicit_model: "explicit-model",
                 meta_model: "meta-model",
                 session_model: "session-model"
               })
             )

    assert %{model: "meta-model", model_explicit: true} ==
             ModelSelection.resolve(
               Map.merge(base, %{meta_model: "meta-model", session_model: "session-model"})
             )

    assert %{model: "session-model", model_explicit: true} ==
             ModelSelection.resolve(Map.merge(base, %{session_model: "session-model"}))
  end

  test "request provenance keeps automatic persona defaults non-explicit without changing precedence" do
    for model <- ["persona-model", "@fast"] do
      input = %{
        explicit_model: model,
        meta_model: "meta-model",
        session_model: "session-model",
        profile_model: "profile-model",
        history_model: "history-model",
        default_model: "default-model"
      }

      assert %{model: model, model_explicit: false} ==
               ModelSelection.resolve(Map.put(input, :model_explicit, false))

      for explicit <- [nil, true] do
        assert %{model: model, model_explicit: true} ==
                 ModelSelection.resolve(Map.put(input, :model_explicit, explicit))
      end
    end
  end

  test "request provenance does not change meta or session model provenance when request is absent" do
    for model <- [nil, "", "  "] do
      assert %{model: "meta-model", model_explicit: true} ==
               ModelSelection.resolve(%{
                 explicit_model: model,
                 model_explicit: false,
                 meta_model: "meta-model"
               })

      assert %{model: "session-model", model_explicit: true} ==
               ModelSelection.resolve(%{
                 explicit_model: model,
                 model_explicit: false,
                 session_model: "session-model"
               })
    end

    assert %{model: nil, model_explicit: false} ==
             ModelSelection.resolve(%{model_explicit: true})
  end

  test "inherited explicit intent survives profile, history and default model fallback" do
    for slot <- [:profile_model, :history_model, :default_model] do
      for explicit <- [nil, false, true] do
        assert %{model: "fallback-model", model_explicit: explicit == true} ==
                 ModelSelection.resolve(%{
                   slot => "fallback-model",
                   :model_explicit => explicit
                 })
      end
    end
  end

  test "profile, history and default models are not explicit" do
    assert %{model: "profile-model", model_explicit: false} ==
             ModelSelection.resolve(%{
               explicit_model: "   ",
               profile_model: "profile-model",
               history_model: "history-model",
               default_model: "default-model"
             })

    assert %{model: "history-model", model_explicit: false} ==
             ModelSelection.resolve(%{
               history_model: "history-model",
               default_model: "default-model"
             })

    assert %{model: "default-model", model_explicit: false} ==
             ModelSelection.resolve(%{history_model: nil, default_model: "default-model"})
  end

  test "nil result is not explicit" do
    assert %{model: nil, model_explicit: false} == ModelSelection.resolve(%{})
    assert %{model: nil, model_explicit: false} == ModelSelection.resolve(nil)
  end

  test "normalizes a selected model" do
    assert %{model: "model-name", model_explicit: true} ==
             ModelSelection.resolve(%{
               explicit_model: "  model-name  ",
               default_model: "default-model"
             })
  end
end
