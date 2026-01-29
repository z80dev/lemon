defmodule Ai.Providers.AnthropicStreamingTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Anthropic
  alias Ai.Types.{Context, Model, ModelCost, StreamOptions, TextContent, Tool, UserMessage}

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

  defp sse_event(event, data) do
    "event: #{event}\n" <> "data: #{Jason.encode!(data)}\n\n"
  end

  test "usage cost uses model pricing" do
    body =
      sse_event("message_start", %{
        "message" => %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cache_read_input_tokens" => 10,
            "cache_creation_input_tokens" => 5
          }
        }
      }) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "claude-test",
      name: "Claude Test",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 20.0, cache_read: 1.0, cache_write: 2.0},
      context_window: 100_000,
      max_tokens: 2048,
      headers: %{}
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    assert result.usage.input == 100
    assert result.usage.output == 50
    assert result.usage.cache_read == 10
    assert result.usage.cache_write == 5

    # 100*10 + 50*20 + 10*1 + 5*2 = 2020 per million tokens => 0.00202
    assert_in_delta result.usage.cost.total, 0.00202, 0.0000001
    assert_in_delta result.usage.cost.input, 0.001, 0.0000001
    assert_in_delta result.usage.cost.output, 0.001, 0.0000001
    assert_in_delta result.usage.cost.cache_read, 0.00001, 0.0000001
    assert_in_delta result.usage.cost.cache_write, 0.00001, 0.0000001
  end

  test "request body snapshot includes system, tools, and thinking config" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "claude-3-7-sonnet-20250219",
      name: "Claude Sonnet 3.7",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://example.test",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{},
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{}
    }

    tool = %Tool{
      name: "lookup",
      description: "Lookup data",
      parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
    }

    context =
      Context.new(
        system_prompt: "System",
        messages: [%UserMessage{content: [%TextContent{text: "Hi"}]}],
        tools: [tool]
      )

    opts = %StreamOptions{api_key: "test-key", max_tokens: 123, temperature: 0.2, reasoning: :low}

    {:ok, stream} = Anthropic.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "claude-3-7-sonnet-20250219",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Hi", "cache_control" => %{"type" => "ephemeral"}}
          ]
        }
      ],
      "max_tokens" => 123,
      "stream" => true,
      "system" => [
        %{"type" => "text", "text" => "System", "cache_control" => %{"type" => "ephemeral"}}
      ],
      "temperature" => 0.2,
      "tools" => [
        %{
          "name" => "lookup",
          "description" => "Lookup data",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          }
        }
      ],
      "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
