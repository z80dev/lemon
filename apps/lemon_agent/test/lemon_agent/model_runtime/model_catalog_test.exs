defmodule LemonAgent.ModelRuntime.ModelCatalogTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ModelCatalog

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

  describe "provider_enabled_for_config?/2" do
    test "pool-only credentials enable a provider" do
      env_key = "POOL_CATALOG_ZAI_KEY"
      original = System.get_env(env_key)

      on_exit(fn ->
        if original, do: System.put_env(env_key, original), else: System.delete_env(env_key)
      end)

      System.put_env(env_key, "pool-zai-key-value")

      cfg = %{
        providers: %{},
        agent: %{
          provider_routing: %{
            default_pool: "burst",
            credential_pools: %{
              "burst" => %{
                providers: ["zai"],
                strategy: "priority",
                credentials: %{"zai" => [%{source: :env, name: env_key}]}
              }
            }
          }
        }
      }

      assert ModelCatalog.provider_enabled_for_config?("zai", cfg)
      # A provider outside the pool with no other credentials stays disabled.
      refute ModelCatalog.provider_enabled_for_config?("acme-nonexistent", cfg)
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

  describe "sort_for_picker/1" do
    defp ids(models), do: models |> ModelCatalog.sort_for_picker() |> Enum.map(& &1.id)

    test "lists newer versions first instead of lexical order" do
      models =
        for {id, name} <- [
              {"gpt-5.4", "GPT-5.4"},
              {"gpt-6.1-sol", "GPT-6.1 Sol"},
              {"gpt-5.10", "GPT-5.10"},
              {"gpt-6-sol", "GPT-6 Sol"}
            ],
            do: %{provider: "openai-codex", id: id, name: name}

      assert ids(models) == ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.10", "gpt-5.4"]
    end

    test "snapshot dates, parameter counts and vendor prefixes are not versions" do
      models = [
        %{provider: "openai", id: "gpt-4o-2024-11-20", name: "GPT-4o (2024-11-20)"},
        %{provider: "openai", id: "gpt-4o-2024-05-13", name: "GPT-4o (2024-05-13)"},
        %{provider: "openai", id: "gpt-oss-120b", name: "gpt-oss-120b"},
        %{provider: "openrouter", id: "ai21/jamba-large-1.7", name: "AI21: Jamba Large 1.7"},
        %{provider: "minimax", id: "MiniMax-M3", name: "MiniMax-M3"}
      ]

      assert ids(models) == [
               "gpt-4o-2024-11-20",
               "gpt-4o-2024-05-13",
               "MiniMax-M3",
               "ai21/jamba-large-1.7",
               "gpt-oss-120b"
             ]
    end
  end
end
