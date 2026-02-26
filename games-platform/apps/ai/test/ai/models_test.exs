defmodule Ai.ModelsTest do
  @moduledoc """
  Comprehensive tests for the Ai.Models module.

  Tests the static model registry, capability queries, token adjustment,
  and model lookup functions.
  """
  use ExUnit.Case, async: true

  alias Ai.Models
  alias Ai.Types.{Model, ModelCost}

  # ============================================================================
  # get_model/2
  # ============================================================================

  describe "get_model/2" do
    test "returns a model struct for a known anthropic model" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert %Model{} = model
      assert model.id == "claude-sonnet-4-20250514"
      assert model.name == "Claude Sonnet 4"
      assert model.provider == :anthropic
      assert model.api == :anthropic_messages
    end

    test "returns a model struct for a known openai model" do
      model = Models.get_model(:openai, "gpt-4o")
      assert %Model{} = model
      assert model.id == "gpt-4o"
      assert model.provider == :openai
    end

    test "returns nil for an unknown model ID" do
      assert Models.get_model(:anthropic, "nonexistent-model") == nil
    end

    test "returns nil for an unknown provider" do
      assert Models.get_model(:unknown_provider, "gpt-4o") == nil
    end

    test "model includes cost information" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert %ModelCost{} = model.cost
      assert model.cost.input > 0
      assert model.cost.output > 0
    end

    test "model includes context_window and max_tokens" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert model.context_window == 200_000
      assert model.max_tokens == 64_000
    end
  end

  # ============================================================================
  # get_models/1
  # ============================================================================

  describe "get_models/1" do
    test "returns a list of models for a known provider" do
      models = Models.get_models(:anthropic)
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :anthropic}, &1))
    end

    test "returns an empty list for an unknown provider" do
      assert Models.get_models(:unknown_provider) == []
    end

    test "returns models for openai provider" do
      models = Models.get_models(:openai)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{provider: :openai}, &1))
    end
  end

  # ============================================================================
  # get_providers/0
  # ============================================================================

  describe "get_providers/0" do
    test "returns a list of provider atoms" do
      providers = Models.get_providers()
      assert is_list(providers)
      assert length(providers) > 0
      assert Enum.all?(providers, &is_atom/1)
    end

    test "includes anthropic and openai providers" do
      providers = Models.get_providers()
      assert :anthropic in providers
      assert :openai in providers
    end

    test "includes all expected providers" do
      providers = Models.get_providers()
      assert :google in providers
      assert :deepseek in providers
      assert :xai in providers
      assert :mistral in providers
    end
  end

  # ============================================================================
  # list_models/0 (and deprecated all/0)
  # ============================================================================

  describe "list_models/0" do
    test "returns all models across all providers" do
      models = Models.list_models()
      assert is_list(models)
      assert length(models) > 10

      providers = models |> Enum.map(& &1.provider) |> Enum.uniq()
      assert length(providers) > 1
    end

    test "every model is a Model struct" do
      models = Models.list_models()
      assert Enum.all?(models, &match?(%Model{}, &1))
    end
  end

  describe "all/0 (deprecated)" do
    test "returns the same result as list_models/0" do
      # Call via apply/3 to avoid compile-time deprecation warnings in tests.
      assert apply(Models, :all, []) == Models.list_models()
    end
  end

  # ============================================================================
  # get_model_ids/1
  # ============================================================================

  describe "get_model_ids/1" do
    test "returns model ID strings for a known provider" do
      ids = Models.get_model_ids(:anthropic)
      assert is_list(ids)
      assert length(ids) > 0
      assert Enum.all?(ids, &is_binary/1)
      assert "claude-sonnet-4-20250514" in ids
    end

    test "returns an empty list for an unknown provider" do
      assert Models.get_model_ids(:unknown_provider) == []
    end

    test "every ID resolves to a model via get_model" do
      ids = Models.get_model_ids(:openai)

      for id <- ids do
        assert %Model{} = Models.get_model(:openai, id),
               "get_model_ids returned #{id} but get_model(:openai, #{inspect(id)}) is nil"
      end
    end
  end

  # ============================================================================
  # supports_vision?/1
  # ============================================================================

  describe "supports_vision?/1" do
    test "returns true for a model with image input" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_vision?(model) == true
    end

    test "returns false for a text-only model" do
      model = Models.get_model(:openai, "o3-mini")
      assert Models.supports_vision?(model) == false
    end

    test "returns true for gpt-4o (multimodal)" do
      model = Models.get_model(:openai, "gpt-4o")
      assert Models.supports_vision?(model) == true
    end

    test "returns false for kimi coding models (text only)" do
      model = Models.get_model(:kimi_coding, "kimi-k2-coding")
      assert Models.supports_vision?(model) == false
    end
  end

  # ============================================================================
  # supports_reasoning?/1
  # ============================================================================

  describe "supports_reasoning?/1" do
    test "returns true for a reasoning model" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_reasoning?(model) == true
    end

    test "returns false for a non-reasoning model" do
      model = Models.get_model(:openai, "gpt-4o")
      assert Models.supports_reasoning?(model) == false
    end

    test "returns true for o3-mini (reasoning model)" do
      model = Models.get_model(:openai, "o3-mini")
      assert Models.supports_reasoning?(model) == true
    end

    test "returns false for older claude models without reasoning" do
      model = Models.get_model(:anthropic, "claude-3-5-haiku-20241022")
      assert Models.supports_reasoning?(model) == false
    end
  end

  # ============================================================================
  # supports_xhigh/1 and supports_xhigh?/1
  # ============================================================================

  describe "supports_xhigh/1" do
    test "returns true for gpt-5.2 model" do
      model = Models.get_model(:openai, "gpt-5.2")
      assert Models.supports_xhigh(model) == true
    end

    test "returns true for claude-opus-4-6 model" do
      model = Models.get_model(:anthropic, "claude-opus-4-6")
      assert Models.supports_xhigh(model) == true
    end

    test "returns true for claude-opus-4-6-thinking model" do
      model = Models.get_model(:anthropic, "claude-opus-4-6-thinking")
      assert Models.supports_xhigh(model) == true
    end

    test "returns false for claude-sonnet-4 model" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_xhigh(model) == false
    end

    test "returns false for gpt-4o model" do
      model = Models.get_model(:openai, "gpt-4o")
      assert Models.supports_xhigh(model) == false
    end

    test "returns false for gpt-5 (non 5.2/5.3)" do
      model = Models.get_model(:openai, "gpt-5")
      assert Models.supports_xhigh(model) == false
    end
  end

  describe "supports_xhigh?/1" do
    test "is an alias for supports_xhigh/1" do
      model = Models.get_model(:openai, "gpt-5.2")
      assert Models.supports_xhigh?(model) == Models.supports_xhigh(model)

      model2 = Models.get_model(:openai, "gpt-4o")
      assert Models.supports_xhigh?(model2) == Models.supports_xhigh(model2)
    end
  end

  # ============================================================================
  # find_by_id/1
  # ============================================================================

  describe "find_by_id/1" do
    test "finds a model by ID across providers" do
      model = Models.find_by_id("gpt-4o")
      assert %Model{} = model
      assert model.id == "gpt-4o"
      assert model.provider == :openai
    end

    test "finds an anthropic model by ID" do
      model = Models.find_by_id("claude-sonnet-4-20250514")
      assert %Model{} = model
      assert model.provider == :anthropic
    end

    test "returns nil for a nonexistent model ID" do
      assert Models.find_by_id("nonexistent-model-id") == nil
    end
  end

  # ============================================================================
  # models_equal?/2
  # ============================================================================

  describe "models_equal?/2" do
    test "returns true for the same model" do
      model1 = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      model2 = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.models_equal?(model1, model2) == true
    end

    test "returns false for different models" do
      model1 = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      model2 = Models.get_model(:openai, "gpt-4o")
      assert Models.models_equal?(model1, model2) == false
    end

    test "returns false when first argument is nil" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.models_equal?(nil, model) == false
    end

    test "returns false when second argument is nil" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.models_equal?(model, nil) == false
    end

    test "returns false when both arguments are nil" do
      assert Models.models_equal?(nil, nil) == false
    end
  end

  # ============================================================================
  # clamp_reasoning/1
  # ============================================================================

  describe "clamp_reasoning/1" do
    test "maps :xhigh to :high" do
      assert Models.clamp_reasoning(:xhigh) == :high
    end

    test "passes through :minimal" do
      assert Models.clamp_reasoning(:minimal) == :minimal
    end

    test "passes through :low" do
      assert Models.clamp_reasoning(:low) == :low
    end

    test "passes through :medium" do
      assert Models.clamp_reasoning(:medium) == :medium
    end

    test "passes through :high" do
      assert Models.clamp_reasoning(:high) == :high
    end

    test "returns nil for nil" do
      assert Models.clamp_reasoning(nil) == nil
    end

    test "returns nil for unknown level" do
      assert Models.clamp_reasoning(:unknown_level) == nil
    end
  end

  # ============================================================================
  # adjust_max_tokens_for_thinking/4
  # ============================================================================

  describe "adjust_max_tokens_for_thinking/4" do
    test "adjusts tokens for :high reasoning level" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)

      assert thinking_budget == 16_384
      assert max_tokens == 8192 + 16_384
    end

    test "adjusts tokens for :medium reasoning level" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium)

      assert thinking_budget == 8192
      assert max_tokens == 8192 + 8192
    end

    test "adjusts tokens for :low reasoning level" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, :low)

      assert thinking_budget == 2048
      assert max_tokens == 8192 + 2048
    end

    test "adjusts tokens for :minimal reasoning level" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, :minimal)

      assert thinking_budget == 1024
      assert max_tokens == 8192 + 1024
    end

    test "clamps max_tokens to model_max_tokens" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(190_000, 200_000, :high)

      assert max_tokens == 200_000
      assert thinking_budget == 16_384
    end

    test "reduces thinking budget when constrained by model max" do
      # When base + budget > model_max, and model_max <= budget
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(500, 1500, :high)

      # max_tokens = min(500 + 16384, 1500) = 1500
      # Since 1500 <= 16384, thinking_budget = max(0, 1500 - 1024) = 476
      assert max_tokens == 1500
      assert thinking_budget == 476
    end

    test "supports custom budgets override" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, :medium, %{medium: 4096})

      assert thinking_budget == 4096
      assert max_tokens == 8192 + 4096
    end

    test "xhigh is clamped to high" do
      result_xhigh = Models.adjust_max_tokens_for_thinking(8192, 200_000, :xhigh)
      result_high = Models.adjust_max_tokens_for_thinking(8192, 200_000, :high)
      assert result_xhigh == result_high
    end

    test "nil reasoning level returns zero thinking budget" do
      {max_tokens, thinking_budget} =
        Models.adjust_max_tokens_for_thinking(8192, 200_000, nil)

      assert thinking_budget == 0
      assert max_tokens == 8192
    end
  end

  # ============================================================================
  # list_models/1 (with options, no network)
  # ============================================================================

  describe "list_models/1" do
    test "without discovery returns same as list_models/0" do
      assert Models.list_models(discover_openai: false) == Models.list_models()
    end

    test "with empty options returns same as list_models/0" do
      assert Models.list_models([]) == Models.list_models()
    end
  end

  # ============================================================================
  # Model data integrity
  # ============================================================================

  describe "model data integrity" do
    test "all models have required fields populated" do
      for model <- Models.list_models() do
        assert is_binary(model.id), "model missing id: #{inspect(model)}"
        assert is_binary(model.name), "model missing name: #{inspect(model)}"
        assert is_atom(model.provider), "model missing provider: #{inspect(model)}"
        assert is_atom(model.api), "model missing api: #{inspect(model)}"
        assert is_binary(model.base_url), "model missing base_url: #{inspect(model)}"
        assert is_boolean(model.reasoning), "model missing reasoning: #{inspect(model)}"
        assert is_list(model.input), "model missing input: #{inspect(model)}"
        assert %ModelCost{} = model.cost, "model missing cost: #{inspect(model)}"
        assert is_integer(model.context_window), "model missing context_window: #{inspect(model)}"
        assert model.context_window > 0, "model context_window must be positive: #{inspect(model)}"
        assert is_integer(model.max_tokens), "model missing max_tokens: #{inspect(model)}"
        assert model.max_tokens > 0, "model max_tokens must be positive: #{inspect(model)}"
      end
    end

    test "every provider in get_providers has at least one model" do
      for provider <- Models.get_providers() do
        models = Models.get_models(provider)
        assert length(models) > 0, "provider #{provider} has no models"
      end
    end
  end
end
