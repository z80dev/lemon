defmodule AgentCore.ModelRuntime.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias AgentCore.ModelRuntime.ModelCatalog

  @catalog [
    %{
      provider: "anthropic",
      models: [
        %{provider: "anthropic", id: "claude-opus-4", name: "Claude Opus 4"},
        %{provider: "anthropic", id: "claude-haiku-4", name: "Claude Haiku 4"}
      ]
    },
    %{
      provider: "openai",
      models: [%{provider: "openai", id: "gpt-4o", name: "GPT-4o"}]
    }
  ]

  describe "providers/1" do
    test "returns provider ids in catalog order" do
      assert ModelCatalog.providers(@catalog) == ["anthropic", "openai"]
    end

    test "returns [] for an empty catalog" do
      assert ModelCatalog.providers([]) == []
    end
  end

  describe "models_for_provider/2" do
    test "returns the models grouped under a known provider" do
      assert ModelCatalog.models_for_provider(@catalog, "anthropic") == [
               %{provider: "anthropic", id: "claude-opus-4", name: "Claude Opus 4"},
               %{provider: "anthropic", id: "claude-haiku-4", name: "Claude Haiku 4"}
             ]
    end

    test "returns [] for an unknown provider" do
      assert ModelCatalog.models_for_provider(@catalog, "google") == []
    end

    test "returns [] for non-binary provider input" do
      assert ModelCatalog.models_for_provider(@catalog, nil) == []
    end
  end

  describe "model_at_index/3" do
    test "returns the model at a valid index" do
      assert ModelCatalog.model_at_index(@catalog, "openai", 0) == %{
               provider: "openai",
               id: "gpt-4o",
               name: "GPT-4o"
             }
    end

    test "returns nil for an out-of-range index" do
      assert ModelCatalog.model_at_index(@catalog, "openai", 5) == nil
    end

    test "returns nil for a negative index" do
      assert ModelCatalog.model_at_index(@catalog, "openai", -1) == nil
    end

    test "returns nil for an unknown provider" do
      assert ModelCatalog.model_at_index(@catalog, "unknown", 0) == nil
    end
  end

  describe "model_spec/1" do
    test "formats provider:id" do
      assert ModelCatalog.model_spec(%{provider: "openai", id: "gpt-4o"}) == "openai:gpt-4o"
    end

    test "returns nil when provider or id is missing" do
      assert ModelCatalog.model_spec(%{provider: "openai"}) == nil
      assert ModelCatalog.model_spec(%{}) == nil
    end
  end

  describe "model_label/1" do
    test "prefers name over id when name is present" do
      assert ModelCatalog.model_label(%{name: "GPT-4o", id: "gpt-4o"}) == "GPT-4o (gpt-4o)"
    end

    test "falls back to id when name is blank" do
      assert ModelCatalog.model_label(%{name: "", id: "gpt-4o"}) == "gpt-4o"
    end

    test "falls back to id when name is absent" do
      assert ModelCatalog.model_label(%{id: "gpt-4o"}) == "gpt-4o"
    end

    test "inspects unrecognized shapes" do
      assert ModelCatalog.model_label(:not_a_model) == ":not_a_model"
    end
  end

  describe "available_catalog/0" do
    test "returns provider groups shaped as {provider, models} sorted by provider" do
      catalog = ModelCatalog.available_catalog()

      assert is_list(catalog)

      providers = Enum.map(catalog, & &1.provider)
      assert providers == Enum.sort(providers)

      Enum.each(catalog, fn group ->
        assert is_binary(group.provider)
        assert is_list(group.models)

        Enum.each(group.models, fn model ->
          assert is_binary(model.provider)
          assert is_binary(model.id)
          assert is_binary(model.name)
        end)
      end)
    end

    test "is deterministic across repeated calls" do
      assert ModelCatalog.available_catalog() == ModelCatalog.available_catalog()
    end
  end
end
