defmodule CodingAgent.Tools.EditSchemaProviderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Edit
  alias LemonAi.{EventStream, Providers.Anthropic}
  alias LemonAi.Types.{Context, Model, ModelCost, StreamOptions, Tool, UserMessage}

  test "actual Anthropic request preserves the edit mode and per-field guidance" do
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
    end)

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "invalid request")
    end)

    edit = Edit.tool("/workspace")
    tool = %Tool{name: edit.name, description: edit.description, parameters: edit.parameters}

    model = %Model{
      id: "kimi-for-coding",
      name: "Kimi",
      api: :anthropic_messages,
      provider: :kimi_coding,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 16_384,
      headers: %{}
    }

    context = Context.new(messages: [%UserMessage{content: "Edit the file"}], tools: [tool])
    {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{api_key: "test-key"})
    assert_receive {:request_body, body}, 2_000
    assert [%{"name" => "edit", "input_schema" => schema}] = body["tools"]
    assert schema["type"] == "object"
    assert schema["required"] == ["path"]
    refute Map.has_key?(schema, "oneOf")
    refute Map.has_key?(schema, "anyOf")
    refute Map.has_key?(schema, "allOf")
    assert schema["properties"]["mode"]["enum"] == ["anchored", "text"]
    assert schema["properties"]["snapshot"]["description"] =~ "Omit old_text"
    assert schema["properties"]["new_text"]["description"] =~ "omit this top-level field"
    assert {:error, _} = EventStream.result(stream, 2_000)
  end
end
