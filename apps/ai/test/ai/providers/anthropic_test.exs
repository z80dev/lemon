defmodule Ai.Providers.Anthropic.ComprehensiveTest do
  @moduledoc """
  Comprehensive unit tests for the Anthropic provider.

  Tests request building, response parsing, authentication,
  message conversion, and error handling via mocked HTTP.
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Anthropic

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    UserMessage
  }

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

  # ============================================================================
  # Helpers
  # ============================================================================

  defp sse_event(event, data) do
    "event: #{event}\ndata: #{Jason.encode!(data)}\n\n"
  end

  defp minimal_success_body do
    sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
      sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
      sse_event("message_stop", %{})
  end

  defp model(overrides \\ %{}) do
    defaults = %{
      id: "claude-sonnet-4-20250514",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{}
    }

    struct(Model, Map.merge(defaults, overrides))
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

  # ============================================================================
  # Provider Callback Tests
  # ============================================================================

  describe "provider callbacks" do
    test "api_id returns :anthropic_messages" do
      assert Anthropic.api_id() == :anthropic_messages
    end

    test "provider_id returns :anthropic" do
      assert Anthropic.provider_id() == :anthropic
    end

    test "get_env_api_key reads ANTHROPIC_API_KEY" do
      with_env(%{"ANTHROPIC_API_KEY" => "test-env-key-123"}, fn ->
        assert Anthropic.get_env_api_key() == "test-env-key-123"
      end)
    end

    test "get_env_api_key returns nil when not set" do
      with_env(%{"ANTHROPIC_API_KEY" => nil}, fn ->
        assert Anthropic.get_env_api_key() == nil
      end)
    end

    test "request_history_limit returns nil for standard anthropic models" do
      assert Anthropic.request_history_limit(model()) == nil
    end

    test "request_history_limit returns limit for kimi models" do
      kimi = model(%{provider: :kimi})
      assert is_integer(Anthropic.request_history_limit(kimi))
      assert Anthropic.request_history_limit(kimi) > 0
    end
  end

  # ============================================================================
  # Request Building: Headers
  # ============================================================================

  describe "request headers" do
    test "includes required Anthropic headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test-key"})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["content-type"] == "application/json"
      assert headers_map["accept"] == "text/event-stream"
      assert headers_map["x-api-key"] == "sk-test-key"
      assert headers_map["anthropic-version"] == "2023-06-01"
      assert String.contains?(headers_map["anthropic-beta"], "fine-grained-tool-streaming")

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "merges model and option extra headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      m = model(%{headers: %{"x-model-header" => "model-val"}})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "sk-test",
        headers: %{"x-opts-header" => "opts-val"}
      }

      {:ok, stream} = Anthropic.stream(m, context, opts)

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["x-model-header"] == "model-val"
      assert headers_map["x-opts-header"] == "opts-val"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Request Building: URL
  # ============================================================================

  describe "request URL" do
    test "uses default Anthropic base URL when model base_url is empty" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_url, "#{conn.scheme}://#{conn.host}#{conn.request_path}"})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      m = model(%{base_url: ""})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(m, context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:request_url, url}, 1000
      assert url == "https://api.anthropic.com/v1/messages"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "uses custom base URL and trims trailing slash" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      m = model(%{base_url: "https://example.test/"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(m, context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:request_path, path}, 1000
      assert path == "/v1/messages"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Request Building: Body
  # ============================================================================

  describe "request body construction" do
    test "includes model id, messages, max_tokens, and stream flag" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context = Context.new(messages: [%UserMessage{content: "Hello"}])

      {:ok, stream} =
        Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test", max_tokens: 500})

      assert_receive {:body, body}, 1000
      assert body["model"] == "claude-sonnet-4-20250514"
      assert body["stream"] == true
      assert body["max_tokens"] == 500
      assert is_list(body["messages"])

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "adds system prompt with cache control when present" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context =
        Context.new(
          system_prompt: "You are a helpful assistant.",
          messages: [%UserMessage{content: "Hi"}]
        )

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000

      assert [%{"type" => "text", "text" => "You are a helpful assistant."} = sys_block] =
               body["system"]

      assert sys_block["cache_control"] == %{"type" => "ephemeral"}

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "omits system prompt when empty or nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context = Context.new(system_prompt: nil, messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      refute Map.has_key?(body, "system")

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "includes temperature when specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test", temperature: 0.7})

      assert_receive {:body, body}, 1000
      assert body["temperature"] == 0.7

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "includes thinking config when model supports reasoning and it is requested" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      m = model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        Anthropic.stream(m, context, %StreamOptions{api_key: "sk-test", reasoning: :high})

      assert_receive {:body, body}, 1000
      assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 32_000}

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "omits thinking config when reasoning is not requested" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      m = model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Anthropic.stream(m, context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      refute Map.has_key?(body, "thinking")

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Message Conversion
  # ============================================================================

  describe "message conversion" do
    test "converts user text message" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context = Context.new(messages: [%UserMessage{content: "Hello world"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      [msg] = body["messages"]
      assert msg["role"] == "user"
      assert msg["content"] == "Hello world"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "converts assistant message with text and tool_use blocks" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      assistant_msg = %AssistantMessage{
        content: [
          %TextContent{text: "Let me check that."},
          %ToolCall{id: "tc_1", name: "read_file", arguments: %{"path" => "/foo"}}
        ]
      }

      tool_result = %ToolResultMessage{
        tool_call_id: "tc_1",
        content: [%TextContent{text: "file contents here"}],
        is_error: false
      }

      context =
        Context.new(messages: [
          %UserMessage{content: "Read /foo"},
          assistant_msg,
          tool_result,
          %UserMessage{content: "Thanks"}
        ])

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      messages = body["messages"]
      assert length(messages) == 4

      # First user message
      assert Enum.at(messages, 0)["role"] == "user"

      # Assistant message with blocks
      asst = Enum.at(messages, 1)
      assert asst["role"] == "assistant"
      assert length(asst["content"]) == 2
      [text_block, tool_block] = asst["content"]
      assert text_block["type"] == "text"
      assert tool_block["type"] == "tool_use"
      assert tool_block["id"] == "tc_1"
      assert tool_block["name"] == "read_file"
      assert tool_block["input"] == %{"path" => "/foo"}

      # Tool result (sent as user role)
      tool_msg = Enum.at(messages, 2)
      assert tool_msg["role"] == "user"
      [tool_result_block] = tool_msg["content"]
      assert tool_result_block["type"] == "tool_result"
      assert tool_result_block["tool_use_id"] == "tc_1"
      assert tool_result_block["is_error"] == false

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "converts tools to Anthropic format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      tool = %Tool{
        name: "search",
        description: "Search the web",
        parameters: %{
          "properties" => %{"query" => %{"type" => "string"}},
          "required" => ["query"]
        }
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      [converted_tool] = body["tools"]
      assert converted_tool["name"] == "search"
      assert converted_tool["description"] == "Search the web"
      assert converted_tool["input_schema"]["type"] == "object"
      assert converted_tool["input_schema"]["properties"] == %{"query" => %{"type" => "string"}}
      assert converted_tool["input_schema"]["required"] == ["query"]

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "filters empty user messages" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context =
        Context.new(messages: [
          %UserMessage{content: "   "},
          %UserMessage{content: "Hello"}
        ])

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      # Whitespace-only messages are filtered, only "Hello" remains
      assert length(body["messages"]) == 1
      assert hd(body["messages"])["content"] == "Hello"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "adds cache_control to last user message" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      context =
        Context.new(messages: [
          %UserMessage{content: [%TextContent{text: "First"}]},
          %UserMessage{content: [%TextContent{text: "Second"}]}
        ])

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert_receive {:body, body}, 1000
      last_msg = List.last(body["messages"])
      assert last_msg["role"] == "user"
      [last_block] = last_msg["content"]
      assert last_block["cache_control"] == %{"type" => "ephemeral"}

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Response Parsing: Success
  # ============================================================================

  describe "response parsing - success" do
    test "parses text content from SSE stream" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "text"}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello, "}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "world!"}
          }) <>
          sse_event("content_block_stop", %{"index" => 0}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :stop
      assert [%TextContent{text: "Hello, world!"}] = result.content
    end

    test "parses thinking content blocks" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{"type" => "thinking"}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "Let me reason..."}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig123"}
          }) <>
          sse_event("content_block_stop", %{"index" => 0}) <>
          sse_event("content_block_start", %{
            "index" => 1,
            "content_block" => %{"type" => "text"}
          }) <>
          sse_event("content_block_delta", %{
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "Answer"}
          }) <>
          sse_event("content_block_stop", %{"index" => 1}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      m = model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(m, context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 2000)
      assert [thinking, text] = result.content
      assert %ThinkingContent{thinking: "Let me reason...", thinking_signature: "sig123"} = thinking
      assert %TextContent{text: "Answer"} = text
    end

    test "parses tool_use content blocks with JSON arguments" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("content_block_start", %{
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_abc",
              "name" => "read_file"
            }
          }) <>
          sse_event("content_block_delta", %{
            "index" => 0,
            "delta" => %{
              "type" => "input_json_delta",
              "partial_json" => ~s({"path": "/tmp/test.txt"})
            }
          }) <>
          sse_event("content_block_stop", %{"index" => 0}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Read a file"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :tool_use
      assert [%ToolCall{id: "toolu_abc", name: "read_file", arguments: args}] = result.content
      assert args == %{"path" => "/tmp/test.txt"}
    end

    test "tracks token usage from message_start" do
      body =
        sse_event("message_start", %{
          "message" => %{
            "usage" => %{
              "input_tokens" => 200,
              "output_tokens" => 0,
              "cache_read_input_tokens" => 50,
              "cache_creation_input_tokens" => 10
            }
          }
        }) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 75}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.usage.input == 200
      assert result.usage.output == 75
      assert result.usage.cache_read == 50
      assert result.usage.cache_write == 10
      assert result.usage.total_tokens == 200 + 75 + 50 + 10
      assert result.usage.cost.total > 0
    end
  end

  # ============================================================================
  # Response Parsing: Stop Reasons
  # ============================================================================

  describe "stop reason mapping" do
    test "end_turn maps to :stop" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :stop
    end

    test "max_tokens maps to :length" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "max_tokens"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :length
    end

    test "tool_use maps to :tool_use" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "tool_use"},
            "usage" => %{}
          }) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :tool_use
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "returns error when API key is missing" do
      with_env(%{"ANTHROPIC_API_KEY" => nil}, fn ->
        Req.Test.stub(__MODULE__, fn conn ->
          Plug.Conn.send_resp(conn, 200, minimal_success_body())
        end)

        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: nil})

        assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
                 EventStream.result(stream, 1000)

        assert msg =~ "No API key"
      end)
    end

    test "returns error on non-200 HTTP response" do
      # Note: with Req's `into:` streaming callback, resp.body is empty for
      # error responses since data is consumed by the callback. The error
      # message will reflect the HTTP status code.
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 2000)

      assert msg =~ "400"
    end

    test "returns error on 500 HTTP response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 2000)

      assert msg =~ "500"
    end

    test "handles SSE error event within stream" do
      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("error", %{"error" => %{"message" => "Overloaded"}}) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: "Overloaded"}} =
               EventStream.result(stream, 2000)
    end

    test "reports error when all messages are filtered to empty" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      # Only whitespace messages - will be filtered to empty
      context = Context.new(messages: [%UserMessage{content: "   "}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "sk-test"})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "No text remained"
    end
  end

  # ============================================================================
  # Authentication
  # ============================================================================

  describe "authentication" do
    test "prefers opts.api_key over environment variable" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      with_env(%{"ANTHROPIC_API_KEY" => "env-key"}, fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])

        {:ok, stream} =
          Anthropic.stream(model(), context, %StreamOptions{api_key: "opts-key"})

        assert_receive {:headers, headers}, 1000
        assert {"x-api-key", "opts-key"} in headers

        assert {:ok, _} = EventStream.result(stream, 1000)
      end)
    end

    test "falls back to ANTHROPIC_API_KEY env var" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, minimal_success_body())
      end)

      with_env(%{"ANTHROPIC_API_KEY" => "env-key-fallback"}, fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{})

        assert_receive {:headers, headers}, 1000
        assert {"x-api-key", "env-key-fallback"} in headers

        assert {:ok, _} = EventStream.result(stream, 1000)
      end)
    end
  end

  # ============================================================================
  # Provider Registration
  # ============================================================================

  describe "register/0" do
    test "registers with ProviderRegistry" do
      Anthropic.register()
      assert {:ok, Ai.Providers.Anthropic} = Ai.ProviderRegistry.get(:anthropic_messages)
    end
  end
end
