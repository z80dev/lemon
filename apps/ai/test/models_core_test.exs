defmodule Ai.ModelsCoreTest do
  @moduledoc """
  Tests for Ai.Models core API: get_model, get_models, get_providers,
  list_models, find_by_id, supports_vision?, supports_reasoning?,
  and get_model_ids.
  """
  use ExUnit.Case, async: true

  alias Ai.Models
  alias Ai.Types.Model

  # ============================================================================
  # get_model/2
  # ============================================================================

  describe "get_model/2" do
    test "returns a model struct for a known provider and model ID" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert %Model{} = model
      assert model.provider == :anthropic
      assert model.id == "claude-sonnet-4-20250514"
    end

    test "returns nil for unknown provider" do
      assert nil == Models.get_model(:nonexistent_provider, "some-model")
    end

    test "returns nil for unknown model ID under known provider" do
      assert nil == Models.get_model(:anthropic, "nonexistent-model-id")
    end

    test "returns models for OpenAI provider" do
      model = Models.get_model(:openai, "gpt-4o")
      assert %Model{} = model
      assert model.provider == :openai
    end
  end

  # ============================================================================
  # get_models/1
  # ============================================================================

  describe "get_models/1" do
    test "returns non-empty list for known provider" do
      models = Models.get_models(:anthropic)
      assert is_list(models)
      assert length(models) > 0
      assert Enum.all?(models, &match?(%Model{}, &1))
    end

    test "returns empty list for unknown provider" do
      assert [] == Models.get_models(:nonexistent_provider)
    end

    test "all returned models have correct provider" do
      models = Models.get_models(:openai)
      assert Enum.all?(models, fn m -> m.provider == :openai end)
    end
  end

  # ============================================================================
  # get_providers/0
  # ============================================================================

  describe "get_providers/0" do
    test "returns a list of atoms" do
      providers = Models.get_providers()
      assert is_list(providers)
      assert length(providers) > 0
      assert Enum.all?(providers, &is_atom/1)
    end

    test "includes major providers" do
      providers = Models.get_providers()
      assert :anthropic in providers
      assert :openai in providers
    end
  end

  # ============================================================================
  # list_models/0
  # ============================================================================

  describe "list_models/0" do
    test "returns non-empty list of all models" do
      models = Models.list_models()
      assert is_list(models)
      assert length(models) > 10
    end

    test "includes models from multiple providers" do
      models = Models.list_models()
      providers = models |> Enum.map(& &1.provider) |> Enum.uniq()
      assert length(providers) > 1
    end

    test "all entries are Model structs" do
      models = Models.list_models()
      assert Enum.all?(models, &match?(%Model{}, &1))
    end
  end

  # ============================================================================
  # find_by_id/1
  # ============================================================================

  describe "find_by_id/1" do
    test "finds an Anthropic model by ID" do
      model = Models.find_by_id("claude-sonnet-4-20250514")
      assert %Model{} = model
      assert model.provider == :anthropic
    end

    test "finds an OpenAI model by ID" do
      model = Models.find_by_id("gpt-4o")
      assert %Model{} = model
      assert model.provider == :openai
    end

    test "returns nil for unknown model ID" do
      assert nil == Models.find_by_id("totally-fake-model")
    end
  end

  # ============================================================================
  # supports_vision?/1
  # ============================================================================

  describe "supports_vision?/1" do
    test "returns true for model with image input" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_vision?(model)
    end

    test "returns false for text-only model" do
      model = Models.get_model(:openai, "o3-mini")

      if model do
        refute Models.supports_vision?(model)
      end
    end

    test "works with manually constructed model struct" do
      model = %Model{
        id: "test",
        name: "Test",
        api: :test,
        provider: :test,
        base_url: "http://example.com",
        input: [:text, :image]
      }

      assert Models.supports_vision?(model)
    end
  end

  # ============================================================================
  # supports_reasoning?/1
  # ============================================================================

  describe "supports_reasoning?/1" do
    test "returns true for reasoning model" do
      model = Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      assert Models.supports_reasoning?(model)
    end

    test "returns false for non-reasoning model" do
      model = Models.get_model(:anthropic, "claude-3-5-haiku-20241022")
      refute Models.supports_reasoning?(model)
    end

    test "works with manually constructed model struct" do
      model = %Model{
        id: "test",
        name: "Test",
        api: :test,
        provider: :test,
        base_url: "http://example.com",
        reasoning: false
      }

      refute Models.supports_reasoning?(model)
    end
  end

  # ============================================================================
  # get_model_ids/1
  # ============================================================================

  describe "get_model_ids/1" do
    test "returns list of string IDs for known provider" do
      ids = Models.get_model_ids(:anthropic)
      assert is_list(ids)
      assert length(ids) > 0
      assert Enum.all?(ids, &is_binary/1)
    end

    test "includes known model IDs" do
      ids = Models.get_model_ids(:anthropic)
      assert "claude-sonnet-4-20250514" in ids
    end

    test "returns empty list for unknown provider" do
      assert [] == Models.get_model_ids(:nonexistent_provider)
    end
  end

  # ============================================================================
  # Model struct integrity
  # ============================================================================

  describe "model struct integrity" do
    test "all models have required fields populated" do
      models = Models.list_models()

      for model <- models do
        assert is_binary(model.id), "model.id must be binary, got: #{inspect(model.id)}"
        assert is_binary(model.name), "model.name must be binary for #{model.id}"
        assert is_atom(model.api), "model.api must be atom for #{model.id}"
        assert is_atom(model.provider), "model.provider must be atom for #{model.id}"
        assert is_binary(model.base_url), "model.base_url must be binary for #{model.id}"
        assert is_list(model.input), "model.input must be list for #{model.id}"
        assert is_boolean(model.reasoning), "model.reasoning must be boolean for #{model.id}"
      end
    end

    test "all models have valid cost structs" do
      models = Models.list_models()

      for model <- models do
        if model.cost do
          assert is_number(model.cost.input), "cost.input must be number for #{model.id}"
          assert is_number(model.cost.output), "cost.output must be number for #{model.id}"
        end
      end
    end
  end
end
