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

  defp model(base_url \\ "https://example.test") do
    %Model{
      id: "claude-test",
      name: "Claude Test",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 20.0, cache_read: 1.0, cache_write: 2.0},
      context_window: 100_000,
      max_tokens: 2048,
      headers: %{}
    }
  end

  defp kimi_model(base_url \\ "https://example.test") do
    %Model{
      id: "kimi-for-coding",
      name: "Kimi for Coding",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 20.0, cache_read: 1.0, cache_write: 2.0},
      context_window: 128_000,
      max_tokens: 16_384,
      headers: %{}
    }
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

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

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
      parameters: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      }
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

  test "kimi model reports provider-specific missing key guidance" do
    with_env(
      %{
        "KIMI_API_KEY" => nil,
        "MOONSHOT_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => nil
      },
      fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(kimi_model(), context, %StreamOptions{})

        assert {:error, %{error_message: msg}} = EventStream.result(stream, 1_000)
        assert msg =~ "No API key provided for Kimi"
        assert msg =~ "KIMI_API_KEY"
      end
    )
  end

  test "kimi model can fall back to ANTHROPIC_API_KEY for compatibility" do
    body =
      sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:kimi_req_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    with_env(
      %{
        "KIMI_API_KEY" => nil,
        "MOONSHOT_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => "anthropic-fallback-key"
      },
      fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(kimi_model(), context, %StreamOptions{})
        assert {:ok, _result} = EventStream.result(stream, 1_000)
      end
    )

    assert_receive {:kimi_req_headers, headers}, 1_000
    assert {"x-api-key", "anthropic-fallback-key"} in headers
  end

  test "retries retryable HTTP responses and succeeds" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(attempts), do: Agent.stop(attempts)
    end)

    body =
      sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
        sse_event("content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}) <>
        sse_event("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "ok"}
        }) <>
        sse_event("content_block_stop", %{"index" => 0}) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

      if attempt == 1 do
        Plug.Conn.send_resp(conn, 503, "temporary outage")
      else
        Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 2_000)
    assert result.stop_reason == :stop
    assert [%TextContent{text: "ok"} | _] = result.content
    assert Agent.get(attempts, & &1) == 2
  end

  test "does not retry non-retryable HTTP responses" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(attempts), do: Agent.stop(attempts)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(attempts, &(&1 + 1))
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

    assert {:error, _} = EventStream.result(stream, 1_000)
    assert Agent.get(attempts, & &1) == 1
  end

  defp with_env(env_map, fun) when is_map(env_map) and is_function(fun, 0) do
    previous =
      Enum.into(env_map, %{}, fn {name, _value} ->
        {name, System.get_env(name)}
      end)

    Enum.each(env_map, fn
      {name, value} when is_binary(value) -> System.put_env(name, value)
      {name, _} -> System.delete_env(name)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, value} when is_binary(value) -> System.put_env(name, value)
        {name, _} -> System.delete_env(name)
      end)
    end
  end
end
