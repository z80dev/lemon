defmodule Ai.Providers.GoogleVertexTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.GoogleVertex
  alias Ai.Types.{Context, Model, StreamOptions, Tool, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "request body snapshot includes tools, system, and thinking config" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://example.test",
      reasoning: true
    }

    tools = [
      %Tool{
        name: "lookup",
        description: "Lookup data",
        parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
      }
    ]

    context = Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: tools)

    opts =
      %StreamOptions{
        project: "proj",
        location: "us-central1",
        access_token: "token",
        temperature: 0.4,
        max_tokens: 128,
        reasoning: :low,
        thinking_budgets: %{level: "LOW"},
        tool_choice: :auto
      }

    {:ok, stream} = GoogleVertex.stream(model, context, opts)

    assert_receive {:request_body, req_body}, 1000

    expected = %{
      "contents" => [
        %{"role" => "user", "parts" => [%{"text" => "Hi"}]}
      ],
      "systemInstruction" => %{"parts" => [%{"text" => "System"}]},
      "tools" => [
        %{
          "functionDeclarations" => [
            %{
              "name" => "lookup",
              "description" => "Lookup data",
              "parameters" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
            }
          ]
        }
      ],
      "toolConfig" => %{"functionCallingConfig" => %{"mode" => "AUTO"}},
      "generationConfig" => %{
        "temperature" => 0.4,
        "maxOutputTokens" => 128,
        "thinkingConfig" => %{"includeThoughts" => true, "thinkingLevel" => "LOW"}
      }
    }

    assert req_body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
