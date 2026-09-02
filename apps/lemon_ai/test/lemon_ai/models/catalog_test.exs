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
