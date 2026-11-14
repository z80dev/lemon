defmodule LemonAi.ModelsTest do
  @moduledoc """
  Comprehensive tests for the LemonAi.Models module.

  Tests the static model registry, capability queries, token adjustment,
  and model lookup functions.
  """
  use ExUnit.Case, async: true

  alias LemonAi.Models
  alias LemonAi.Types.{Model, ModelCost}

  # ============================================================================
  # get_model/2
  # ============================================================================

  describe "get_model/2" do
    test "returns a model struct for a known anthropic model" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert %Model{} = model
      assert model.id == "claude-sonnet-4-20250514"
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

    test "Claude 4.6 model lookups use Anthropic API IDs" do
      assert Models.get_model(:anthropic, "claude-sonnet-4-6").id == "claude-sonnet-4-6"
      assert Models.get_model(:anthropic, "claude-opus-4-6").id == "claude-opus-4-6"
    end
  end

  # ============================================================================
  # get_models/1
  # ============================================================================

  describe "get_models/1" do
    test "returns a list of models for a known provider" do
      models = Models.get_models(:anthropic)
      assert is_list(models)
      assert models != []
      assert Enum.all?(models, &match?(%Model{provider: :anthropic}, &1))
    end

    test "returns an empty list for an unknown provider" do
      assert Models.get_models(:unknown_provider) == []
    end

    test "returns models for openai provider" do
      models = Models.get_models(:openai)
      assert models != []
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
      assert match?([_ | _], providers)
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
  # list_models/0
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

        assert model.context_window > 0,
               "model context_window must be positive: #{inspect(model)}"

        assert is_integer(model.max_tokens), "model missing max_tokens: #{inspect(model)}"
        assert model.max_tokens > 0, "model max_tokens must be positive: #{inspect(model)}"
      end
    end

    test "every static catalog provider has at least one model" do
      for provider <- Models.get_providers(), not LemonAi.Models.Presets.preset?(provider) do
        models = Models.get_models(provider)
        assert models != [], "provider #{provider} has no models"
      end
    end
  end
end
