defmodule Ai.Providers.GoogleGeminiCliTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.GoogleGeminiCli
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

  test "request body snapshot includes project, request, and toolConfig" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gemini-1.5-pro",
      name: "Gemini 1.5 Pro",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://example.test"
    }

    tools = [
      %Tool{
        name: "lookup",
        description: "Lookup data",
        parameters: %{
          "type" => "object",
          "properties" => %{"q" => %{"type" => "string"}},
          "required" => ["q"]
        }
      }
    ]

    context =
      Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: tools)

    api_key = Jason.encode!(%{"token" => "token", "projectId" => "proj"})

    opts =
      %StreamOptions{
        api_key: api_key,
        session_id: "sess-1",
        temperature: 0.1,
        max_tokens: 99,
        tool_choice: :auto
      }

    {:ok, stream} = GoogleGeminiCli.stream(model, context, opts)

    assert_receive {:request_body, req_body}, 1000

    request_id = req_body["requestId"]
    assert is_binary(request_id)
    assert Regex.match?(~r/^pi-\d+-[a-f0-9]{12}$/, request_id)

    sanitized = Map.delete(req_body, "requestId")

    expected = %{
      "project" => "proj",
      "model" => "gemini-1.5-pro",
      "userAgent" => "pi-coding-agent",
      "request" => %{
        "contents" => [
          %{"role" => "user", "parts" => [%{"text" => "Hi"}]}
        ],
        "sessionId" => "sess-1",
        "systemInstruction" => %{"parts" => [%{"text" => "System"}]},
        "generationConfig" => %{"temperature" => 0.1, "maxOutputTokens" => 99},
        "tools" => [
          %{
            "functionDeclarations" => [
              %{
                "name" => "lookup",
                "description" => "Lookup data",
                "parameters" => %{
                  "type" => "object",
                  "properties" => %{"q" => %{"type" => "string"}},
                  "required" => ["q"]
                }
              }
            ]
          }
        ],
        "toolConfig" => %{"functionCallingConfig" => %{"mode" => "AUTO"}}
      }
    }

    assert sanitized == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
