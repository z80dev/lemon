defmodule LemonAi.Providers.MoonshotToolSchemaTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.{MoonshotToolSchema, OpenAICompletions}
  alias LemonAi.Types.{Context, Model, StreamOptions, Tool, UserMessage}

  @schema %{
    "type" => "object",
    "title" => "Args",
    "properties" => %{
      "mode" => %{"const" => "fast"},
      "level" => %{"oneOf" => [%{"const" => 1}, %{"const" => 2}]},
      "maybe" => %{"anyOf" => [%{"const" => "on"}, %{"const" => nil}]},
      "name" => %{
        "type" => ["string", "null"],
        "nullable" => true,
        "minLength" => 1,
        "pattern" => "^[a-z]+$",
        "description" => "Lower-case name"
      },
      "kind" => %{"enum" => ["a", "b"]},
      "tags" => %{
        "type" => "array",
        "items" => %{"type" => "string", "format" => "uri"},
        "maxItems" => 3,
        "prefixItems" => [%{"type" => "string"}]
      },
      "target" => %{
        "oneOf" => [%{"type" => "string"}, %{"type" => "integer"}],
        "default" => "x"
      },
      "flags" => %{"enum" => [true, false]},
      "open" => true,
      "extra" => %{"type" => "object", "additionalProperties" => %{"const" => "y"}}
    },
    "required" => ["mode"]
  }

  test "normalizes JSON Schema to Moonshot Flavored JSON Schema" do
    normalized = MoonshotToolSchema.normalize(@schema)
    properties = normalized["properties"]

    refute Map.has_key?(normalized, "title")
    assert normalized["required"] == ["mode"]
    assert properties["mode"] == %{"enum" => ["fast"], "type" => "string"}
    assert properties["level"] == %{"enum" => [1, 2], "type" => "number"}
    # MFJS enums hold only strings and numbers; a nullable const union keeps its type.
    assert properties["maybe"] == %{"type" => "string"}

    assert properties["name"] == %{
             "type" => "string",
             "description" => ~s(Lower-case name\n\n{minLength: 1, pattern: "^[a-z]+$"})
           }

    assert properties["kind"] == %{"enum" => ["a", "b"], "type" => "string"}

    assert properties["tags"] == %{
             "type" => "array",
             "items" => %{"type" => "string", "description" => ~s({format: "uri"})},
             "description" => "{maxItems: 3}"
           }

    assert properties["target"] == %{
             "anyOf" => [%{"type" => "string"}, %{"type" => "integer"}],
             "default" => "x"
           }

    assert properties["flags"] == %{"type" => "boolean"}
    assert properties["open"] == %{}

    assert properties["extra"]["additionalProperties"] == %{"enum" => ["y"], "type" => "string"}
  end

  # Generated with omp's `normalizeSchemaForMoonshot` (packages/ai/src/utils/schema).
  @omp_fixtures_path Path.expand("../fixtures/moonshot_tool_schema_omp.json", __DIR__)
  @external_resource @omp_fixtures_path
  @omp_fixtures @omp_fixtures_path |> File.read!() |> Jason.decode!()

  for %{"name" => name} = fixture <- @omp_fixtures do
    @fixture fixture
    test "matches omp on local $ref inlining: #{name}" do
      assert MoonshotToolSchema.normalize(@fixture["input"]) == @fixture["expected"]
    end
  end

  test "inlining is bounded for exponentially shared definitions" do
    defs =
      Map.new(1..24, fn level ->
        ref = %{"$ref" => "#/$defs/D#{level - 1}"}
        {"D#{level}", %{"type" => "object", "properties" => %{"a" => ref, "b" => ref}}}
      end)
      |> Map.put("D0", %{"type" => "string"})

    schema = %{
      "$defs" => defs,
      "type" => "object",
      "properties" => %{"x" => %{"$ref" => "#/$defs/D24"}}
    }

    {micros, normalized} = :timer.tc(fn -> MoonshotToolSchema.normalize(schema) end)
    assert micros < 5_000_000
    refute Map.has_key?(normalized, "$defs")
    assert normalized |> Jason.encode!() |> byte_size() < 1_000_000
    refute Jason.encode!(normalized) =~ "$ref"
  end

  test "detects Moonshot-native hosts only" do
    for url <- [
          "https://api.moonshot.ai/v1",
          "https://api.moonshot.cn/v1",
          "https://api.kimi.com/coding/v1",
          "https://API.KIMI.AI/coding/v1"
        ] do
      assert MoonshotToolSchema.native_host?(url), url
    end

    for url <- ["https://openrouter.ai/api/v1", "https://example.test/api.moonshot.ai", nil] do
      refute MoonshotToolSchema.native_host?(url)
    end
  end

  describe "OpenAI Chat Completions" do
    setup do
      {:ok, _} = Application.ensure_all_started(:lemon_ai)
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, "data: [DONE]\n")
      end)

      :ok
    end

    test "Moonshot-native hosts receive MFJS tool parameters; other hosts the original schema" do
      assert parameters("https://api.moonshot.ai/v1", %{}) ==
               MoonshotToolSchema.normalize(@schema)

      assert parameters("https://example.test/v1", %{}) == @schema

      assert parameters("https://example.test/v1", %{moonshot_tool_schema: true}) ==
               MoonshotToolSchema.normalize(@schema)
    end
  end

  defp parameters(base_url, compat) do
    model = %Model{
      id: "kimi-k2",
      name: "Kimi K2",
      api: :openai_completions,
      provider: "moonshot",
      base_url: base_url,
      compat: compat
    }

    context =
      Context.new(
        messages: [%UserMessage{content: "hi"}],
        tools: [%Tool{name: "lookup", description: "Look up", parameters: @schema}]
      )

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})
    assert_receive {:request_body, %{"tools" => [%{"function" => function}]}}, 1000
    assert {:ok, _} = EventStream.result(stream, 1000)
    function["parameters"]
  end
end
