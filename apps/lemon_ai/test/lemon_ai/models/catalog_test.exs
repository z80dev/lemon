defmodule LemonAi.Models.CatalogTest do
  use ExUnit.Case, async: true

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  describe "compile-time resources" do
    test "provider modules register their catalog as an external resource" do
      path = Catalog.path("deep_seek.json")
      resources = external_resources(LemonAi.Models.DeepSeek)

      assert path in resources
      assert File.regular?(path)
    end

    test "modules with multiple catalogs register every source file" do
      resources = external_resources(LemonAi.Models.Google)

      assert Catalog.path("google.json") in resources
      assert Catalog.path("google_antigravity_extras.json") in resources
    end
  end

  describe "decode!/2" do
    test "rejects a non-object top level with the catalog source" do
      assert_raise ArgumentError,
                   ~r/model catalog "broken.json" must contain a top-level JSON object/,
                   fn -> Catalog.decode!("[]", "broken.json") end
    end

    test "rejects syntactically invalid JSON with the catalog source" do
      assert_raise ArgumentError,
                   ~r/model catalog "broken.json" contains invalid JSON/,
                   fn -> Catalog.decode!("{", "broken.json") end
    end

    test "identifies the model key when an entry is malformed" do
      json = Jason.encode!(%{"broken-alias" => Map.delete(valid_entry(), "name")})

      assert_raise ArgumentError,
                   ~r/invalid model entry "broken-alias" in catalog "broken.json".*key "name" not found/,
                   fn -> Catalog.decode!(json, "broken.json") end
    end

    test "rejects invalid model field types and ranges with entry context" do
      invalid_fields = [
        {["name"], 7, "expected name to be a string"},
        {["base_url"], [], "expected base_url to be a string"},
        {["reasoning"], "false", "expected reasoning to be a boolean"},
        {["input"], %{}, "expected input to be an array"},
        {["context_window"], "large", "expected context_window to be a non-negative integer"},
        {["max_tokens"], -1, "expected max_tokens to be a non-negative integer"},
        {["headers"], [], "expected headers to be an object"},
        {["compat"], [], "expected compat to be an object"},
        {["cost", "input"], "free", "expected cost.input to be non-negative"},
        {["cost", "output"], -1, "expected cost.output to be non-negative"}
      ]

      for {path, value, expected_message} <- invalid_fields do
        entry = put_in(valid_entry(), path, value)
        json = Jason.encode!(%{"broken-model" => entry})

        error =
          assert_raise ArgumentError, fn ->
            Catalog.decode!(json, "broken.json")
          end

        assert error.message =~
                 ~s(invalid model entry "broken-model" in catalog "broken.json")

        assert error.message =~ expected_message
      end
    end

    test "normalizes only explicitly supported atom fields" do
      json = Jason.encode!(%{"safe-model" => valid_entry()})

      assert %{
               "safe-model" => %Model{
                 api: :openai_responses,
                 provider: :openai,
                 input: [:text, :image]
               }
             } = Catalog.decode!(json, "safe.json")

      unknown = "catalog_unknown_#{System.unique_integer([:positive])}"
      refute_existing_atom(unknown)

      unsafe_json =
        Jason.encode!(%{
          "unsafe-model" => Map.put(valid_entry(), "api", unknown)
        })

      assert_raise ArgumentError,
                   ~r/invalid model entry "unsafe-model".*unsupported api value/,
                   fn -> Catalog.decode!(unsafe_json, "unsafe.json") end

      refute_existing_atom(unknown)

      for {field, entry} <- [
            {:provider, Map.put(valid_entry(), "provider", unknown)},
            {:input, Map.put(valid_entry(), "input", [unknown])}
          ] do
        unsafe_json = Jason.encode!(%{"unsafe-model" => entry})

        assert_raise ArgumentError,
                     ~r/invalid model entry "unsafe-model".*unsupported #{field} value/,
                     fn -> Catalog.decode!(unsafe_json, "unsafe.json") end

        refute_existing_atom(unknown)
      end
    end

    test "normalizes every supported compatibility override" do
      compat = %{
        "supports_store" => false,
        "supports_developer_role" => true,
        "supports_reasoning_effort" => false,
        "supports_usage_in_streaming" => true,
        "requires_tool_result_name" => true,
        "requires_assistant_after_tool_result" => false,
        "requires_thinking_as_text" => true,
        "requires_mistral_tool_ids" => false,
        "max_tokens_field" => "max_tokens",
        "thinking_format" => "zai",
        "open_router_routing" => %{
          "order" => ["anthropic", "openai"],
          "preferences" => %{"sort" => "price", "allow_fallbacks" => true}
        }
      }

      entry = Map.put(valid_entry(), "compat", compat)
      model = Catalog.decode!(Jason.encode!(%{"compatible-model" => entry}), "compat.json")

      assert model["compatible-model"].compat == %{
               supports_store: false,
               supports_developer_role: true,
               supports_reasoning_effort: false,
               supports_usage_in_streaming: true,
               requires_tool_result_name: true,
               requires_assistant_after_tool_result: false,
               requires_thinking_as_text: true,
               requires_mistral_tool_ids: false,
               max_tokens_field: "max_tokens",
               thinking_format: "zai",
               open_router_routing: %{
                 "order" => ["anthropic", "openai"],
                 "preferences" => %{"sort" => "price", "allow_fallbacks" => true}
               }
             }
    end

    test "accepts the alternate compatibility enums and null routing semantics" do
      compat = %{
        "max_tokens_field" => "max_completion_tokens",
        "thinking_format" => "openai",
        "open_router_routing" => nil
      }

      entry = Map.put(valid_entry(), "compat", compat)
      model = Catalog.decode!(Jason.encode!(%{"compatible-model" => entry}), "compat.json")

      assert model["compatible-model"].compat == %{
               max_tokens_field: "max_completion_tokens",
               thinking_format: "openai",
               open_router_routing: nil
             }

      entry = Map.put(valid_entry(), "compat", nil)
      model = Catalog.decode!(Jason.encode!(%{"compatible-model" => entry}), "compat.json")
      assert model["compatible-model"].compat == nil
    end

    test "rejects invalid compatibility values with source and model context" do
      invalid_compat = [
        {%{"supports_store" => "false"}, "expected compat.supports_store to be a boolean"},
        {%{"max_tokens_field" => false}, "expected compat.max_tokens_field to be a string"},
        {%{"max_tokens_field" => "tokens"},
         ~s(unsupported compat.max_tokens_field value: "tokens")},
        {%{"thinking_format" => false}, "expected compat.thinking_format to be a string"},
        {%{"thinking_format" => "anthropic"},
         ~s(unsupported compat.thinking_format value: "anthropic")},
        {%{"open_router_routing" => []}, "expected compat.open_router_routing to be an object"},
        {%{"not_a_compat_flag" => true}, ~s(unsupported compat key: "not_a_compat_flag")}
      ]

      for {compat, expected_message} <- invalid_compat do
        entry = Map.put(valid_entry(), "compat", compat)
        json = Jason.encode!(%{"broken-compat-model" => entry})

        error =
          assert_raise ArgumentError, fn ->
            Catalog.decode!(json, "broken-compat.json")
          end

        assert error.message =~
                 ~s(invalid model entry "broken-compat-model" in catalog "broken-compat.json")

        assert error.message =~ expected_message
      end
    end

    test "rejecting an unknown compatibility key does not create an atom" do
      unknown = "catalog_unknown_compat_#{System.unique_integer([:positive])}"
      refute_existing_atom(unknown)

      entry = Map.put(valid_entry(), "compat", %{unknown => true})
      json = Jason.encode!(%{"unsafe-model" => entry})

      assert_raise ArgumentError,
                   ~r/invalid model entry "unsafe-model".*unsupported compat key/,
                   fn -> Catalog.decode!(json, "unsafe.json") end

      refute_existing_atom(unknown)
    end
  end

  defp valid_entry do
    %{
      "id" => "safe-model",
      "name" => "Safe Model",
      "api" => "openai_responses",
      "provider" => "openai",
      "base_url" => "https://example.test/v1",
      "reasoning" => true,
      "input" => ["text", "image"],
      "cost" => %{
        "input" => 1.0,
        "output" => 2.0,
        "cache_read" => 0.5,
        "cache_write" => 0.0
      },
      "context_window" => 128_000,
      "max_tokens" => 32_000
    }
  end

  defp refute_existing_atom(value) do
    assert_raise ArgumentError, fn -> String.to_existing_atom(value) end
  end

  defp external_resources(module) do
    module.__info__(:attributes)
    |> Keyword.get_values(:external_resource)
    |> List.flatten()
  end
end
