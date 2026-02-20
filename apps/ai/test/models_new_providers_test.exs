defmodule Ai.ModelsNewProvidersTest do
  @moduledoc """
  Tests for newly added model providers (Mistral, Cerebras, DeepSeek, Qwen, MiniMax, Z.ai).
  """
  use ExUnit.Case, async: true

  alias Ai.Models

  describe "Mistral models" do
    test "codestral-latest is available" do
      model = Models.get_model(:mistral, "codestral-latest")
      assert model != nil
      assert model.name == "Codestral"
      assert model.provider == :mistral
      assert model.api == :openai_completions
      assert :text in model.input
    end

    test "devstral-latest is available" do
      model = Models.get_model(:mistral, "devstral-latest")
      assert model != nil
      assert model.name == "Devstral"
      assert model.reasoning == true
    end

    test "mistral-large-latest is available" do
      model = Models.get_model(:mistral, "mistral-large-latest")
      assert model != nil
      assert model.name == "Mistral Large"
      assert :image in model.input
    end

    test "mistral-small-latest is available" do
      model = Models.get_model(:mistral, "mistral-small-latest")
      assert model != nil
      assert model.name == "Mistral Small"
    end

    test "pixtral-large-latest is available" do
      model = Models.get_model(:mistral, "pixtral-large-latest")
      assert model != nil
      assert model.name == "Pixtral Large"
      assert :image in model.input
    end

    test "all Mistral models can be listed" do
      models = Models.get_models(:mistral)
      assert length(models) == 7

      ids = Models.get_model_ids(:mistral)
      assert "codestral-latest" in ids
      assert "mistral-large-latest" in ids
    end
  end

  describe "Cerebras models" do
    test "llama-3.1-8b is available" do
      model = Models.get_model(:cerebras, "llama-3.1-8b")
      assert model != nil
      assert model.name == "Llama 3.1 8B"
      assert model.provider == :cerebras
      assert model.api == :openai_completions
    end

    test "llama-3.3-70b is available" do
      model = Models.get_model(:cerebras, "llama-3.3-70b")
      assert model != nil
      assert model.name == "Llama 3.3 70B"
    end

    test "qwen-3-32b is available" do
      model = Models.get_model(:cerebras, "qwen-3-32b")
      assert model != nil
      assert model.name == "Qwen 3 32B"
      assert model.reasoning == true
    end

    test "all Cerebras models can be listed" do
      models = Models.get_models(:cerebras)
      assert length(models) == 3
    end
  end

  describe "DeepSeek models" do
    test "deepseek-chat is available" do
      model = Models.get_model(:deepseek, "deepseek-chat")
      assert model != nil
      assert model.name == "DeepSeek V3"
      assert model.provider == :deepseek
      assert model.api == :openai_completions
      assert model.reasoning == false
    end

    test "deepseek-reasoner is available" do
      model = Models.get_model(:deepseek, "deepseek-reasoner")
      assert model != nil
      assert model.name == "DeepSeek R1"
      assert model.reasoning == true
    end

    test "deepseek-r1 alias is available" do
      model = Models.get_model(:deepseek, "deepseek-r1")
      assert model != nil
      assert model.name == "DeepSeek R1 (Alias)"
    end

    test "all DeepSeek models can be listed" do
      models = Models.get_models(:deepseek)
      assert length(models) == 3
    end
  end

  describe "Qwen models" do
    test "qwen-turbo is available" do
      model = Models.get_model(:qwen, "qwen-turbo")
      assert model != nil
      assert model.name == "Qwen Turbo"
      assert model.provider == :qwen
      assert :image in model.input
    end

    test "qwen-max is available" do
      model = Models.get_model(:qwen, "qwen-max")
      assert model != nil
      assert model.name == "Qwen Max"
      assert model.reasoning == true
    end

    test "qwen-coder-plus is available" do
      model = Models.get_model(:qwen, "qwen-coder-plus")
      assert model != nil
      assert model.name == "Qwen Coder Plus"
    end

    test "qwen-vl-max is available" do
      model = Models.get_model(:qwen, "qwen-vl-max")
      assert model != nil
      assert model.name == "Qwen VL Max"
      assert :image in model.input
    end

    test "all Qwen models can be listed" do
      models = Models.get_models(:qwen)
      assert length(models) == 5
    end
  end

  describe "MiniMax models" do
    test "minimax-m2 is available" do
      model = Models.get_model(:minimax, "minimax-m2")
      assert model != nil
      assert model.name == "MiniMax M2"
      assert model.provider == :minimax
      assert model.reasoning == true
    end

    test "minimax-m2.1 is available" do
      model = Models.get_model(:minimax, "minimax-m2.1")
      assert model != nil
      assert model.name == "MiniMax M2.1"
    end

    test "minimax-m2.5 is available" do
      model = Models.get_model(:minimax, "minimax-m2.5")
      assert model != nil
      assert model.name == "MiniMax M2.5"
    end

    test "all MiniMax models can be listed" do
      models = Models.get_models(:minimax)
      assert length(models) == 3
    end
  end

  describe "Z.ai models" do
    test "glm-4.5-flash is available" do
      model = Models.get_model(:zai, "glm-4.5-flash")
      assert model != nil
      assert model.name == "GLM 4.5 Flash"
      assert model.provider == :zai
    end

    test "glm-4.5 is available" do
      model = Models.get_model(:zai, "glm-4.5")
      assert model != nil
      assert model.name == "GLM 4.5"
      assert model.reasoning == true
    end

    test "glm-4.7 is available" do
      model = Models.get_model(:zai, "glm-4.7")
      assert model != nil
      assert model.name == "GLM 4.7"
    end

    test "glm-5 is available" do
      model = Models.get_model(:zai, "glm-5")
      assert model != nil
      assert model.name == "GLM 5"
      assert :image in model.input
    end

    test "all Z.ai models can be listed" do
      models = Models.get_models(:zai)
      assert length(models) == 5
    end
  end

  describe "New providers are in providers list" do
    test "all new providers are registered" do
      providers = Models.get_providers()
      assert :mistral in providers
      assert :cerebras in providers
      assert :deepseek in providers
      assert :qwen in providers
      assert :minimax in providers
      assert :zai in providers
    end
  end

  describe "find_by_id works for new models" do
    test "can find Mistral models by ID" do
      model = Models.find_by_id("codestral-latest")
      assert model != nil
      assert model.provider == :mistral
    end

    test "can find DeepSeek models by ID" do
      model = Models.find_by_id("deepseek-reasoner")
      assert model != nil
      assert model.provider == :deepseek
    end

    test "can find Qwen models by ID" do
      model = Models.find_by_id("qwen-max")
      assert model != nil
      assert model.provider == :qwen
    end
  end

  describe "list_models includes new providers" do
    test "all models are in list_models output" do
      all_models = Models.list_models()

      mistral_count = Enum.count(all_models, &(&1.provider == :mistral))
      cerebras_count = Enum.count(all_models, &(&1.provider == :cerebras))
      deepseek_count = Enum.count(all_models, &(&1.provider == :deepseek))
      qwen_count = Enum.count(all_models, &(&1.provider == :qwen))
      minimax_count = Enum.count(all_models, &(&1.provider == :minimax))
      zai_count = Enum.count(all_models, &(&1.provider == :zai))

      assert mistral_count == 7
      assert cerebras_count == 3
      assert deepseek_count == 3
      assert qwen_count == 5
      assert minimax_count == 3
      assert zai_count == 5
    end
  end
end
