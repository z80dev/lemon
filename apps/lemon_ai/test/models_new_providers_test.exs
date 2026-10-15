defmodule LemonAi.ModelsNewProvidersTest do
  use ExUnit.Case, async: true

  alias LemonAi.Models
  alias LemonAi.Types.Model

  test "new provider catalogs are registered and queryable" do
    providers = Models.get_providers()
    all_models = Models.list_models()

    for provider <- [:mistral, :cerebras, :deepseek, :qwen, :minimax, :zai] do
      assert provider in providers
      models = Models.get_models(provider)
      assert models != []
      assert Enum.all?(models, &match?(%Model{provider: ^provider}, &1))
      assert Enum.all?(models, &(&1 in all_models))
      assert Enum.sort(Models.get_model_ids(provider)) == Enum.sort(Enum.map(models, & &1.id))
    end
  end

  test "representative catalogs retain their distinct wire APIs" do
    assert %Model{provider: :mistral, api: :mistral_conversations, input: input} =
             Models.get_model(:mistral, "codestral-latest")

    assert :text in input

    assert %Model{provider: :cerebras, api: :openai_completions} =
             Models.get_model(:cerebras, "llama-3.1-8b")

    assert %Model{provider: :deepseek, api: :openai_completions} =
             Models.get_model(:deepseek, "deepseek-chat")
  end

  test "find_by_id searches the new provider catalogs" do
    assert %Model{provider: :mistral} = Models.find_by_id("codestral-latest")
    assert %Model{provider: :deepseek} = Models.find_by_id("deepseek-reasoner")
    assert %Model{provider: :qwen} = Models.find_by_id("qwen-max")
  end
end
