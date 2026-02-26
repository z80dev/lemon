defmodule Ai.Providers.GoogleStreamingTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Google
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

  defp sse_body(chunks) do
    chunks
    |> Enum.map(&("data: " <> Jason.encode!(&1)))
    |> Enum.join("\n")
  end

  test "streams SSE responses end-to-end" do
    body =
      sse_body([
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
        %{"candidates" => [%{"content" => %{"parts" => [%{"text" => " world"}]}}]},
        %{
          "candidates" => [%{"finishReason" => "STOP"}],
          "usageMetadata" => %{
            "promptTokenCount" => 2,
            "candidatesTokenCount" => 2,
            "thoughtsTokenCount" => 0,
            "cachedContentTokenCount" => 0,
            "totalTokenCount" => 4
          }
        }
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Google.stream(model, context, %StreamOptions{})

    assert EventStream.collect_text(stream) == "Hello world"
    assert {:ok, result} = EventStream.result(stream)
    assert result.stop_reason == :stop
  end

  test "uses OPENCODE_API_KEY for opencode provider when api_key option is missing" do
    test_pid = self()
    prev_opencode = System.get_env("OPENCODE_API_KEY")
    prev_google = System.get_env("GOOGLE_GENERATIVE_AI_API_KEY")

    on_exit(fn ->
      if is_binary(prev_opencode) do
        System.put_env("OPENCODE_API_KEY", prev_opencode)
      else
        System.delete_env("OPENCODE_API_KEY")
      end

      if is_binary(prev_google) do
        System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", prev_google)
      else
        System.delete_env("GOOGLE_GENERATIVE_AI_API_KEY")
      end
    end)

    System.put_env("OPENCODE_API_KEY", "opencode-env-key")
    System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", "google-env-key")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
    end)

    model = %Model{
      id: "gemini-3-pro",
      name: "Gemini 3 Pro",
      api: :google_generative_ai,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Google.stream(model, context, %StreamOptions{})

    assert_receive {:request_headers, headers}, 1000
    assert {"x-goog-api-key", "opencode-env-key"} in headers
    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "request body snapshot includes tools, system, and thinking config" do
    test_pid = self()

    body =
      sse_body([
        %{"candidates" => [%{"finishReason" => "STOP"}]}
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://example.test",
      reasoning: true
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

    opts =
      %StreamOptions{
        temperature: 0.3,
        max_tokens: 256,
        reasoning: :low,
        thinking_budgets: %{level: "LOW"},
        tool_choice: :any
      }

    {:ok, stream} = Google.stream(model, context, opts)

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
              "parameters" => %{
                "type" => "object",
                "properties" => %{"q" => %{"type" => "string"}},
                "required" => ["q"]
              }
            }
          ]
        }
      ],
      "toolConfig" => %{"functionCallingConfig" => %{"mode" => "ANY"}},
      "generationConfig" => %{
        "temperature" => 0.3,
        "maxOutputTokens" => 256,
        "thinkingConfig" => %{"includeThoughts" => true, "thinkingLevel" => "LOW"}
      }
    }

    assert req_body == expected
    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "omits toolConfig when tool_choice is nil" do
    test_pid = self()

    body =
      sse_body([
        %{"candidates" => [%{"finishReason" => "STOP"}]}
      ])

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://example.test"
    }

    tools = [
      %Tool{
        name: "lookup",
        description: "Lookup data",
        parameters: %{"type" => "object", "properties" => %{}, "required" => []}
      }
    ]

    context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)

    {:ok, stream} = Google.stream(model, context, %StreamOptions{})

    assert_receive {:request_body, req_body}, 1000
    refute Map.has_key?(req_body, "toolConfig")

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end
end
