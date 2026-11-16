defmodule CodingAgent.Eval.TypeScriptTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Eval.TypeScript
  alias LemonAgent.Types.AgentTool

  test "catalog and object property order are byte stable and names are quoted" do
    schema = %{
      "type" => "object",
      "required" => ["a"],
      "properties" => %{
        "z" => %{"type" => "array", "items" => %{"type" => "string"}},
        "a" => %{"type" => "integer"}
      }
    }

    a = %AgentTool{name: "a\";evil", parameters: schema}
    z = %AgentTool{name: "z", parameters: %{"type" => "object"}}
    rendered = TypeScript.render([z, a])
    assert rendered == TypeScript.render(%{"z" => z, "a" => a})
    assert rendered =~ ~S|"a\";evil": (args: { "a": number; "z"?: Array<string>; }|
    assert rendered =~ "Promise<ToolResult>"
  end

  test "renders enums, nullable types, compositions and unsafe references conservatively" do
    properties = %{
      "enum" => %{"enum" => ["b", "a", nil]},
      "nullable" => %{"type" => ["string", "null"]},
      "union" => %{"anyOf" => [%{"type" => "number"}, %{"type" => "boolean"}]},
      "intersection" => %{
        "allOf" => [%{"type" => "object", "properties" => %{"x" => %{"type" => "string"}}}, true]
      },
      "reference" => %{"$ref" => "#/definitions/Foo"},
      "unknown" => %{"type" => "surprise"},
      "never" => false
    }

    rendered =
      TypeScript.render([
        %AgentTool{name: "test", parameters: %{"type" => "object", "properties" => properties}}
      ])

    assert rendered =~ ~S("enum"?: "a" | "b" | null;)
    assert rendered =~ ~S/"nullable"?: (null | string);/
    assert rendered =~ ~S/"union"?: (boolean | number);/
    assert rendered =~ ~S("reference"?: unknown;)
    assert rendered =~ ~S("unknown"?: unknown;)
    assert rendered =~ ~S("never"?: never;)
    assert rendered =~ " & "
  end

  test "empty catalog and open dictionaries remain valid declarations" do
    assert TypeScript.render([]) =~ "declare const tools: {\n\n};"

    rendered =
      TypeScript.render([
        %AgentTool{
          name: "dict",
          parameters: %{"type" => "object", "additionalProperties" => %{"type" => "boolean"}}
        }
      ])

    assert rendered =~ "Record<string, boolean>"
  end
end
