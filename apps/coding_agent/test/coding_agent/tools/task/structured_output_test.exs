defmodule CodingAgent.Tools.Task.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Task.StructuredOutput

  test "expensive schema patterns reject the response without raising" do
    pattern = %{"type" => "string", "pattern" => "(a+)+$"}

    for schema <- [
          pattern,
          %{"not" => pattern},
          %{"anyOf" => [pattern, true]},
          %{"oneOf" => [pattern, true]}
        ] do
      assert {:error, message} =
               StructuredOutput.decode(Jason.encode!(String.duplicate("a", 100) <> "!"), schema)

      assert message =~ "pattern exceeded its match budget"
    end
  end

  describe "validate_schema/1" do
    test "accepts disabled, boolean, empty, and annotated schemas" do
      for schema <- [nil, true, false, %{}] do
        assert :ok = StructuredOutput.validate_schema(schema)
      end

      assert :ok =
               StructuredOutput.validate_schema(%{
                 "$schema" => "https://json-schema.org/draft/2020-12/schema",
                 "title" => "Result",
                 "description" => "A child result",
                 "default" => %{"any" => [1, nil, false]},
                 "examples" => [%{"message" => "ok"}]
               })

      assert :ok = StructuredOutput.validate_schema(%{"minItems" => 1.0})
      assert {:ok, [1]} = StructuredOutput.decode("[1]", %{"minItems" => 1.0})
      assert {:error, _} = StructuredOutput.decode("[]", %{"minItems" => 1.0})
    end

    test "rejects unsupported keywords, including nested references and annotations with semantics" do
      for keyword <- [
            "$ref",
            "$defs",
            "definitions",
            "format",
            "patternProperties",
            "dependentRequired",
            "prefixItems",
            "contains",
            "nullable",
            "unknown"
          ] do
        assert {:error, message} = StructuredOutput.validate_schema(%{keyword => "unsupported"})
        assert message =~ "unsupported schema keyword"
        assert message =~ "$["
      end

      assert {:error, message} =
               StructuredOutput.validate_schema(%{
                 "properties" => %{"child" => %{"$ref" => "#/definitions/child"}}
               })

      assert message =~ ~s($["properties"]["child"]["$ref"])
    end

    test "rejects invalid schemas before decoding any response" do
      schemas = [
        [],
        "object",
        %{type: "object"},
        %{"default" => self()},
        %{"default" => %{atom_key: "value"}},
        %{"description" => <<255>>},
        %{"type" => "date"},
        %{"type" => []},
        %{"type" => ["string", "string"]},
        %{"type" => ["string", nil]},
        %{"properties" => []},
        %{"properties" => %{"bad" => nil}},
        %{"required" => "name"},
        %{"required" => ["name", "name"]},
        %{"required" => [false]},
        %{"additionalProperties" => nil},
        %{"items" => [%{"type" => "integer"}]},
        %{"enum" => []},
        %{"enum" => [1, 1.0]},
        %{"enum" => [%{"n" => [1]}, %{"n" => [1.0]}]},
        %{"anyOf" => []},
        %{"oneOf" => %{}},
        %{"allOf" => [nil]},
        %{"not" => nil},
        %{"minimum" => false},
        %{"exclusiveMaximum" => true},
        %{"multipleOf" => 0},
        %{"multipleOf" => -1},
        %{"minLength" => -1},
        %{"maxItems" => 1.5},
        %{"minProperties" => "1"},
        %{"uniqueItems" => "true"},
        %{"pattern" => "["},
        %{"pattern" => 3},
        %{"title" => []},
        %{"examples" => %{}}
      ]

      for schema <- schemas do
        assert {:error, message} = StructuredOutput.validate_schema(schema)
        assert String.starts_with?(message, "$")
        assert {:error, ^message} = StructuredOutput.decode("not json", schema)
      end
    end

    test "bounds exact encoded schema size and nesting, including ignored annotations" do
      # {"description":""} occupies 18 bytes before the description contents.
      assert :ok =
               StructuredOutput.validate_schema(%{"description" => String.duplicate("x", 65_518)})

      assert {:error, size_error} =
               StructuredOutput.validate_schema(%{"description" => String.duplicate("x", 65_519)})

      assert size_error =~ "maximum encoded size"

      assert {:error, _} =
               StructuredOutput.validate_schema(%{
                 "description" => String.duplicate("\n", 40_000)
               })

      nested = Enum.reduce(1..33, %{}, fn _, schema -> %{"items" => schema} end)
      assert {:error, depth_error} = StructuredOutput.validate_schema(nested)
      assert depth_error =~ "maximum nesting"

      nested_default = Enum.reduce(1..33, nil, fn _, value -> [value] end)
      assert {:error, _} = StructuredOutput.validate_schema(%{"default" => nested_default})
    end
  end

  describe "instruction/1" do
    test "requires unfenced JSON matching the exact encoded schema" do
      assert StructuredOutput.instruction(nil) == ""
      schema = %{"type" => "object", "required" => ["answer"]}
      instruction = StructuredOutput.instruction(schema)
      assert instruction =~ "ONLY valid JSON"
      assert instruction =~ "Do not include Markdown fences"
      assert instruction =~ "any other prose"
      assert String.ends_with?(instruction, Jason.encode!(schema))
    end
  end

  describe "decode/2" do
    test "decodes a positive nested schema without coercion" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "results" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "name" => %{"type" => "string"},
                "score" => %{"type" => ["number", "null"]},
                "done" => %{"type" => "boolean"}
              },
              "required" => ["name", "score", "done"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["results"],
        "additionalProperties" => false
      }

      value = %{"results" => [%{"name" => "one", "score" => nil, "done" => true}]}
      assert {:ok, ^value} = StructuredOutput.decode(Jason.encode!(value), schema)

      assert {:error, missing} = StructuredOutput.decode(~s({"results":[{"name":"one"}]}), schema)
      assert missing =~ ~s($["results"][0][)
      assert missing =~ "required property is missing"

      assert {:error, extra} =
               StructuredOutput.decode(~s({"results":[],"private-key":"private-value"}), schema)

      assert extra == "$: additional properties are forbidden"
    end

    test "strictly checks each JSON type, including null, booleans and whole numbers" do
      cases = [
        {"string", ~s("3"), ["3", "true", "null", "[]", "{}"]},
        {"object", "{}", ["[]", "null", "false", ~s("{}")]},
        {"array", "[]", ["{}", "null", ~s("[]")]},
        {"integer", "3", ["3.5", "true", "false", "null", ~s("3")]},
        {"number", "3.5", ["true", "false", "null", ~s("3.5")]},
        {"boolean", "false", ["0", "1", "null", ~s("false")]},
        {"null", "null", ["false", "0", ~s("null")]}
      ]

      for {type, valid, invalid} <- cases do
        schema = %{"type" => type}
        assert {:ok, _} = StructuredOutput.decode(valid, schema)

        for text <- invalid do
          assert {:error, "$: type mismatch"} = StructuredOutput.decode(text, schema)
        end
      end

      assert {:ok, 1.0} = StructuredOutput.decode("1.0", %{"type" => "integer"})
      assert {:ok, nil} = StructuredOutput.decode("null", %{"type" => ["string", "null"]})
      assert {:error, _} = StructuredOutput.decode("false", %{"type" => ["string", "null"]})
    end

    test "rejects malformed JSON, fences, prose, multiple documents, and non-text safely" do
      for text <- [
            "{",
            "",
            "```json\n{}\n```",
            "Here is {}",
            "{} {}",
            "{\"secret\":NaN}",
            "private-secret",
            nil,
            %{}
          ] do
        assert {:error, message} = StructuredOutput.decode(text, %{})
        assert String.starts_with?(message, "$: response")
        refute message =~ "private-secret"
        refute message =~ "secret"
      end

      assert {:ok, %{}} = StructuredOutput.decode(" \n {} \t", %{})
      assert {:ok, nil} = StructuredOutput.decode("not parsed", nil)
      assert {:ok, false} = StructuredOutput.decode("false", true)
      assert {:error, _} = StructuredOutput.decode("false", false)
    end

    test "additional property schemas validate without echoing dynamic private keys or values" do
      schema = %{
        "properties" => %{"fixed" => true},
        "additionalProperties" => %{"type" => "integer"}
      }

      assert {:ok, _} = StructuredOutput.decode(~s({"fixed":null,"other":2}), schema)

      assert {:error, message} =
               StructuredOutput.decode(~s({"private-key":"private-value"}), schema)

      assert message == "$[additional property]: type mismatch"
      refute message =~ "private"

      assert {:ok, _} = StructuredOutput.decode(~s({"anything":null}), %{})

      assert {:ok, _} =
               StructuredOutput.decode(~s({"anything":null}), %{"additionalProperties" => true})
    end

    test "enum and const use recursive JSON equality without conflating booleans with numbers" do
      schema = %{"enum" => [%{"items" => [1, nil, false]}]}
      assert {:ok, _} = StructuredOutput.decode(~s({"items":[1.0,null,false]}), schema)
      assert {:error, _} = StructuredOutput.decode(~s({"items":[1,null,0]}), schema)
      assert {:ok, nil} = StructuredOutput.decode("null", %{"const" => nil})
      assert {:error, _} = StructuredOutput.decode("false", %{"const" => nil})
      assert {:error, message} = StructuredOutput.decode(~s("private-value"), %{"enum" => ["ok"]})
      refute message =~ "private-value"
    end

    test "combinators validate branches and preserve sibling constraints" do
      any = %{"anyOf" => [%{"type" => "integer"}, %{"const" => "ok"}]}
      assert {:ok, 2} = StructuredOutput.decode("2", any)
      assert {:ok, "ok"} = StructuredOutput.decode(~s("ok"), any)
      assert {:error, _} = StructuredOutput.decode("false", any)

      one = %{"oneOf" => [%{"type" => "number"}, %{"type" => "integer"}]}
      assert {:ok, 2.5} = StructuredOutput.decode("2.5", one)
      assert {:error, _} = StructuredOutput.decode("2", one)
      assert {:error, _} = StructuredOutput.decode("false", one)

      all = %{
        "allOf" => [%{"minimum" => 1}, %{"maximum" => 3}],
        "type" => "integer",
        "not" => %{"const" => 2}
      }

      assert {:ok, 1} = StructuredOutput.decode("1", all)

      for text <- ["0", "2", "4", "1.5", ~s("1")] do
        assert {:error, _} = StructuredOutput.decode(text, all)
      end

      assert {:ok, 1} = StructuredOutput.decode("1", %{"not" => false})
      assert {:error, _} = StructuredOutput.decode("1", %{"not" => true})
    end

    test "numeric bounds and exact decimal multiples" do
      schema = %{"minimum" => -1, "maximum" => 1, "multipleOf" => 0.1}

      for text <- ["-1", "0", "0.3", "1"] do
        assert {:ok, _} = StructuredOutput.decode(text, schema)
      end

      for text <- ["-1.1", "1.1", "0.31", "0.30000000000000004"] do
        assert {:error, _} = StructuredOutput.decode(text, schema)
      end

      exclusive = %{"exclusiveMinimum" => 1, "exclusiveMaximum" => 3}
      assert {:ok, 2} = StructuredOutput.decode("2", exclusive)
      assert {:error, _} = StructuredOutput.decode("1", exclusive)
      assert {:error, _} = StructuredOutput.decode("3", exclusive)
      assert {:ok, _} = StructuredOutput.decode("3e-7", %{"multipleOf" => 1.0e-7})
      assert {:ok, _} = StructuredOutput.decode("3e20", %{"multipleOf" => 1.0e20})
      assert {:error, _} = StructuredOutput.decode("3", %{"multipleOf" => 2})
    end

    test "string bounds count code points and patterns search without implicit anchoring" do
      schema = %{"type" => "string", "minLength" => 2, "maxLength" => 3, "pattern" => "é"}
      assert {:ok, "éx"} = StructuredOutput.decode(Jason.encode!("éx"), schema)
      assert {:ok, "xéx"} = StructuredOutput.decode(Jason.encode!("xéx"), schema)

      for value <- ["é", "xéxx", "xxx"] do
        assert {:error, _} = StructuredOutput.decode(Jason.encode!(value), schema)
      end

      assert {:ok, _} =
               StructuredOutput.decode(Jason.encode!("e\u0301"), %{
                 "minLength" => 2,
                 "maxLength" => 2
               })

      assert {:ok, _} =
               StructuredOutput.decode(Jason.encode!("😀"), %{"minLength" => 1, "maxLength" => 1})
    end

    test "array bounds, uniqueness and item errors" do
      schema = %{
        "type" => "array",
        "minItems" => 1,
        "maxItems" => 2,
        "uniqueItems" => true,
        "items" => %{"type" => "integer"}
      }

      assert {:ok, [1, 2]} = StructuredOutput.decode("[1,2]", schema)

      for text <- ["[]", "[1,2,3]", "[1,1.0]"] do
        assert {:error, _} = StructuredOutput.decode(text, schema)
      end

      assert {:error, "$[1]: type mismatch"} = StructuredOutput.decode("[1,false]", schema)

      assert {:error, _} =
               StructuredOutput.decode(~s([{"n":[1]},{"n":[1.0]}]), %{"uniqueItems" => true})

      assert {:ok, _} = StructuredOutput.decode("[false,0,null]", %{"uniqueItems" => true})

      assert {:ok, _} =
               StructuredOutput.decode(
                 "[9007199254740992,9007199254740993]",
                 %{"uniqueItems" => true}
               )

      assert {:ok, _} = StructuredOutput.decode("[1,1]", %{"uniqueItems" => false})
      assert {:ok, []} = StructuredOutput.decode("[]", %{"items" => false})
      assert {:error, _} = StructuredOutput.decode("[1]", %{"items" => false})
    end

    test "object bounds and type-specific keyword applicability" do
      schema = %{"minProperties" => 1, "maxProperties" => 2}
      assert {:ok, _} = StructuredOutput.decode(~s({"a":1}), schema)
      assert {:ok, _} = StructuredOutput.decode(~s({"a":1,"b":2}), schema)
      assert {:error, _} = StructuredOutput.decode("{}", schema)
      assert {:error, _} = StructuredOutput.decode(~s({"a":1,"b":2,"c":3}), schema)

      schema = %{
        "minimum" => 1,
        "minLength" => 1,
        "minItems" => 1,
        "minProperties" => 1,
        "required" => ["x"],
        "items" => false,
        "pattern" => "x",
        "additionalProperties" => false
      }

      assert {:ok, nil} = StructuredOutput.decode("null", schema)
      assert {:ok, false} = StructuredOutput.decode("false", schema)
    end
  end
end
