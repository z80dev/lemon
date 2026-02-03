defmodule Ai.Providers.BedrockStreamingTest do
  @moduledoc """
  Comprehensive tests for AWS Bedrock streaming functionality.

  Tests cover:
  - Full streaming flow from start to finish
  - Chunk parsing and reassembly
  - Tool use in streaming mode
  - Error handling during streams
  - Stream cancellation/interruption
  - Concurrent streams
  - Backpressure handling
  - Claude model streaming via Bedrock
  - Llama model streaming via Bedrock
  - Token usage accumulation during streaming
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Bedrock
  alias Ai.Types.{AssistantMessage, Context, Model, StreamOptions, TextContent, Tool, UserMessage}

  # ============================================================================
  # Test Setup
  # ============================================================================

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
  # Helper Functions for Building Bedrock Binary Frames
  # ============================================================================

  @doc """
  Builds a Bedrock event stream binary frame.

  Frame structure:
  - prelude: total_length (4) + headers_length (4) + prelude_crc (4) = 12 bytes
  - headers: variable length
  - payload: variable length
  - message_crc: 4 bytes
  """
  defp build_frame(event_type, payload, message_type \\ "event") do
    json_payload = Jason.encode!(payload)
    headers = build_headers(event_type, message_type)
    headers_length = byte_size(headers)
    payload_length = byte_size(json_payload)

    # Total length = prelude (8) + prelude_crc (4) + headers + payload + message_crc (4)
    total_length = 8 + 4 + headers_length + payload_length + 4

    prelude = <<total_length::32-unsigned-big, headers_length::32-unsigned-big>>
    prelude_crc = :erlang.crc32(prelude)

    frame_without_crc = <<
      prelude::binary,
      prelude_crc::32-unsigned-big,
      headers::binary,
      json_payload::binary
    >>

    message_crc = :erlang.crc32(frame_without_crc)

    <<frame_without_crc::binary, message_crc::32-unsigned-big>>
  end

  defp build_headers(event_type, message_type) do
    # Header format: name_len (1) + name + type (1 = 7 for string) + value_len (2) + value
    event_header = build_string_header(":event-type", event_type)
    message_header = build_string_header(":message-type", message_type)
    content_header = build_string_header(":content-type", "application/json")

    event_header <> message_header <> content_header
  end

  defp build_string_header(name, value) do
    name_len = byte_size(name)
    value_len = byte_size(value)
    <<name_len::8, name::binary, 7::8, value_len::16-big, value::binary>>
  end

  defp build_exception_frame(message) do
    build_frame("exception", %{"message" => message}, "exception")
  end

  defp default_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "anthropic.claude-3-5-haiku-20241022-v1:0"),
      name: Keyword.get(opts, :name, "Claude 3.5 Haiku"),
      api: :bedrock_converse_stream,
      provider: :amazon,
      base_url: "",
      reasoning: Keyword.get(opts, :reasoning, false),
      input: [:text]
    }
  end

  defp default_opts do
    %StreamOptions{
      headers: %{
        "aws_access_key_id" => "AKIA_TEST_KEY",
        "aws_secret_access_key" => "SECRET_TEST_KEY",
        "aws_region" => "us-east-1"
      }
    }
  end

  # ============================================================================
  # Full Streaming Flow Tests
  # ============================================================================

  describe "full streaming flow" do
    test "streams simple text response from start to finish" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello, "}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "world!"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{
          "usage" => %{
            "inputTokens" => 10,
            "outputTokens" => 5
          }
        })

      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/vnd.amazon.eventstream")
        |> Plug.Conn.send_resp(200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :stop
      assert length(result.content) == 1
      assert %TextContent{text: "Hello, world!"} = hd(result.content)
      assert result.usage.input == 10
      assert result.usage.output == 5
    end

    test "handles multiple text content blocks" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "First block."}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 1,
          "delta" => %{"text" => "Second block."}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 1}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{"inputTokens" => 5, "outputTokens" => 10}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert length(result.content) == 2
      assert Enum.at(result.content, 0).text == "First block."
      assert Enum.at(result.content, 1).text == "Second block."
    end

    test "streams events in correct order" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "A"}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "B"}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "C"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      events = stream |> EventStream.events() |> Enum.to_list()

      text_deltas = Enum.filter(events, fn
        {:text_delta, _, _, _} -> true
        _ -> false
      end)

      assert length(text_deltas) == 3
      assert {:text_delta, 0, "A", _} = Enum.at(text_deltas, 0)
      assert {:text_delta, 0, "B", _} = Enum.at(text_deltas, 1)
      assert {:text_delta, 0, "C", _} = Enum.at(text_deltas, 2)
    end

    test "emits start event before content" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      events = stream |> EventStream.events() |> Enum.to_list()

      # First event should be :start
      assert {:start, %AssistantMessage{}} = hd(events)
    end
  end

  # ============================================================================
  # Chunk Parsing and Reassembly Tests
  # ============================================================================

  describe "chunk parsing and reassembly" do
    test "handles single large chunk" do
      long_text = String.duplicate("a", 1000)

      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => long_text}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert hd(result.content).text == long_text
    end

    test "reassembles text from many small deltas" do
      # Generate 50 small text deltas
      text_frames = for i <- 1..50 do
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "#{i} "}
        })
      end

      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        Enum.join(text_frames, "") <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      expected_text = Enum.map_join(1..50, "", fn i -> "#{i} " end)
      assert hd(result.content).text == expected_text
    end

    test "handles empty text deltas gracefully" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => ""}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello"}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => ""}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert hd(result.content).text == "Hello"
    end

    test "handles unicode characters in chunks" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello 世界! "}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "🎉 こんにちは"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert hd(result.content).text == "Hello 世界! 🎉 こんにちは"
    end
  end

  # ============================================================================
  # Tool Use in Streaming Mode Tests
  # ============================================================================

  describe "tool use in streaming mode" do
    test "streams tool call with arguments" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{
              "toolUseId" => "call_123",
              "name" => "read_file"
            }
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "toolUse" => %{"input" => "{\"path\":"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "toolUse" => %{"input" => "\"/test.txt\"}"}
          }
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{"inputTokens" => 20, "outputTokens" => 15}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      tool = %Tool{
        name: "read_file",
        description: "Read a file",
        parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Read test.txt"}], tools: [tool])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :tool_use
      assert length(result.content) == 1

      tool_call = hd(result.content)
      assert tool_call.type == :tool_call
      assert tool_call.id == "call_123"
      assert tool_call.name == "read_file"
      assert tool_call.arguments == %{"path" => "/test.txt"}
    end

    test "streams multiple tool calls" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_1", "name" => "tool_a"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "{}"}}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 1,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_2", "name" => "tool_b"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 1,
          "delta" => %{"toolUse" => %{"input" => "{\"key\":\"value\"}"}}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 1}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      tools = [
        %Tool{name: "tool_a", description: "Tool A", parameters: %{}},
        %Tool{name: "tool_b", description: "Tool B", parameters: %{}}
      ]

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Use tools"}], tools: tools)

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert length(result.content) == 2
      assert Enum.at(result.content, 0).name == "tool_a"
      assert Enum.at(result.content, 1).name == "tool_b"
      assert Enum.at(result.content, 1).arguments == %{"key" => "value"}
    end

    test "emits tool_call_start, delta, and end events" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_xyz", "name" => "my_tool"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "{\"a\":"}}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "1}"}}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      tools = [%Tool{name: "my_tool", description: "A tool", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Use tool"}], tools: tools)

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      events = stream |> EventStream.events() |> Enum.to_list()

      assert Enum.any?(events, fn
        {:tool_call_start, 0, _} -> true
        _ -> false
      end)

      assert Enum.any?(events, fn
        {:tool_call_delta, 0, _, _} -> true
        _ -> false
      end)

      assert Enum.any?(events, fn
        {:tool_call_end, 0, _, _} -> true
        _ -> false
      end)
    end

    test "handles incomplete JSON during streaming" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_1", "name" => "test"}
          }
        }) <>
        # Partial JSON that can be closed
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "{\"nested\":{\"key\":\"val"}}
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"toolUse" => %{"input" => "ue\"}}"}}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Test"}], tools: tools)

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      tool_call = hd(result.content)
      assert tool_call.arguments == %{"nested" => %{"key" => "value"}}
    end

    test "handles text before tool call" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Let me help you."}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 1,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_1", "name" => "helper"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 1,
          "delta" => %{"toolUse" => %{"input" => "{}"}}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 1}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      tools = [%Tool{name: "helper", description: "Helper", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Help"}], tools: tools)

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert length(result.content) == 2
      assert %TextContent{text: "Let me help you."} = Enum.at(result.content, 0)
      assert Enum.at(result.content, 1).type == :tool_call
    end
  end

  # ============================================================================
  # Error Handling During Streams Tests
  # ============================================================================

  describe "error handling during streams" do
    test "handles exception frame" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_exception_frame("ThrottlingException: Rate exceeded")

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert result.error_message == "ThrottlingException: Rate exceeded"
    end

    test "handles HTTP 400 error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, Jason.encode!(%{"message" => "ValidationException"}))
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert result.error_message == "ValidationException"
    end

    test "handles HTTP 403 access denied" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 403, Jason.encode!(%{"Message" => "Access Denied"}))
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert result.error_message == "Access Denied"
    end

    test "handles HTTP 500 internal error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert String.contains?(result.error_message, "500")
    end

    test "handles missing AWS access key" do
      prev_access = System.get_env("AWS_ACCESS_KEY_ID")
      prev_secret = System.get_env("AWS_SECRET_ACCESS_KEY")

      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      on_exit(fn ->
        if prev_access, do: System.put_env("AWS_ACCESS_KEY_ID", prev_access)
        if prev_secret, do: System.put_env("AWS_SECRET_ACCESS_KEY", prev_secret)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, %StreamOptions{})
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert String.contains?(result.error_message, "AWS_ACCESS_KEY_ID")
    end

    test "handles missing AWS secret key" do
      prev_access = System.get_env("AWS_ACCESS_KEY_ID")
      prev_secret = System.get_env("AWS_SECRET_ACCESS_KEY")

      System.put_env("AWS_ACCESS_KEY_ID", "AKIA_TEST")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      on_exit(fn ->
        if prev_access, do: System.put_env("AWS_ACCESS_KEY_ID", prev_access), else: System.delete_env("AWS_ACCESS_KEY_ID")
        if prev_secret, do: System.put_env("AWS_SECRET_ACCESS_KEY", prev_secret)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, %StreamOptions{})
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert String.contains?(result.error_message, "AWS_SECRET_ACCESS_KEY")
    end

    test "handles malformed JSON in error response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "not valid json")
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:error, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
      assert String.contains?(result.error_message, "400")
    end
  end

  # ============================================================================
  # Stream Cancellation/Interruption Tests
  # ============================================================================

  describe "stream cancellation and interruption" do
    test "stream can be canceled" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        # Send start frame then wait
        send(test_pid, :request_started)
        Process.sleep(5000)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      # Wait for request to start then cancel
      receive do
        :request_started -> :ok
      after
        1000 -> flunk("Request did not start")
      end

      EventStream.cancel(stream, :user_requested)

      {:error, {:canceled, :user_requested}} = EventStream.result(stream, 1000)
    end

    test "handles stop_sequence stop reason" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Stopped at sequence"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "stop_sequence"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :stop
    end

    test "handles max_tokens stop reason" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Truncated..."}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "max_tokens"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :length
    end

    test "handles context window exceeded" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("messageStop", %{"stopReason" => "model_context_window_exceeded"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :length
    end
  end

  # ============================================================================
  # Concurrent Streams Tests
  # ============================================================================

  describe "concurrent streams" do
    test "handles multiple concurrent streams" do
      Req.Test.stub(__MODULE__, fn conn ->
        frames =
          build_frame("messageStart", %{"role" => "assistant"}) <>
          build_frame("contentBlockDelta", %{
            "contentBlockIndex" => 0,
            "delta" => %{"text" => "Response #{:erlang.unique_integer()}"}
          }) <>
          build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
          build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
          build_frame("metadata", %{"usage" => %{}})

        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()

      # Start 5 concurrent streams
      tasks = for i <- 1..5 do
        Task.async(fn ->
          context = Context.new(messages: [%UserMessage{content: "Message #{i}"}])
          {:ok, stream} = Bedrock.stream(model, context, default_opts())
          EventStream.result(stream, 5000)
        end)
      end

      results = Task.await_many(tasks, 10_000)

      assert Enum.all?(results, fn
        {:ok, %AssistantMessage{}} -> true
        _ -> false
      end)
    end

    test "streams are independent" do
      call_count = :counters.new(1, [:atomics])

      Req.Test.stub(__MODULE__, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        frames =
          build_frame("messageStart", %{"role" => "assistant"}) <>
          build_frame("contentBlockDelta", %{
            "contentBlockIndex" => 0,
            "delta" => %{"text" => "Stream #{count}"}
          }) <>
          build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
          build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
          build_frame("metadata", %{"usage" => %{}})

        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()

      context1 = Context.new(messages: [%UserMessage{content: "First"}])
      context2 = Context.new(messages: [%UserMessage{content: "Second"}])

      {:ok, stream1} = Bedrock.stream(model, context1, default_opts())
      {:ok, stream2} = Bedrock.stream(model, context2, default_opts())

      {:ok, result1} = EventStream.result(stream1, 5000)
      {:ok, result2} = EventStream.result(stream2, 5000)

      # Each stream should have unique content
      text1 = hd(result1.content).text
      text2 = hd(result2.content).text

      assert text1 != text2
    end
  end

  # ============================================================================
  # Backpressure Handling Tests
  # ============================================================================

  describe "backpressure handling" do
    test "stream respects max_queue setting" do
      # Generate many frames
      text_frames = for i <- 1..100 do
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "#{i}"}
        })
      end

      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        Enum.join(text_frames, "") <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      # Should complete without crashing
      assert result.stop_reason == :stop
    end

    test "collect_text works with high volume of events" do
      text_frames = for i <- 1..200 do
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "."}
        })
      end

      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        Enum.join(text_frames, "") <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      text = EventStream.collect_text(stream)

      assert String.length(text) == 200
    end
  end

  # ============================================================================
  # Claude Model Streaming via Bedrock Tests
  # ============================================================================

  describe "Claude model streaming via Bedrock" do
    test "streams from Claude 3.5 Haiku" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello from Haiku!"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{"inputTokens" => 10, "outputTokens" => 5}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(id: "anthropic.claude-3-5-haiku-20241022-v1:0", name: "Claude 3.5 Haiku")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.model == "anthropic.claude-3-5-haiku-20241022-v1:0"
      assert result.api == :bedrock_converse_stream
    end

    test "streams from Claude 3.7 Sonnet with thinking" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "reasoningContent" => %{
              "text" => "Let me think about this...",
              "signature" => "sig123"
            }
          }
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 1,
          "delta" => %{"text" => "Here is my answer."}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 1}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(
        id: "anthropic.claude-3-7-sonnet-20250219-v1:0",
        name: "Claude 3.7 Sonnet",
        reasoning: true
      )
      context = Context.new(messages: [%UserMessage{content: "Think about this"}])
      opts = %{default_opts() | reasoning: :medium}

      {:ok, stream} = Bedrock.stream(model, context, opts)
      {:ok, result} = EventStream.result(stream, 5000)

      assert length(result.content) == 2

      thinking = Enum.at(result.content, 0)
      assert thinking.type == :thinking
      assert thinking.thinking == "Let me think about this..."
      assert thinking.thinking_signature == "sig123"
    end

    test "streams from Claude Opus 4" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Response from Opus 4"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(
        id: "anthropic.claude-opus-4-20250514-v1:0",
        name: "Claude Opus 4"
      )
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert hd(result.content).text == "Response from Opus 4"
    end

    test "handles thinking delta events" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "reasoningContent" => %{"text" => "Step 1: ", "signature" => ""}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "reasoningContent" => %{"text" => "Consider options", "signature" => ""}
          }
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Think"}])
      opts = %{default_opts() | reasoning: :low}

      {:ok, stream} = Bedrock.stream(model, context, opts)

      events = stream |> EventStream.events() |> Enum.to_list()

      thinking_deltas = Enum.filter(events, fn
        {:thinking_delta, _, _, _} -> true
        _ -> false
      end)

      assert length(thinking_deltas) == 2
    end
  end

  # ============================================================================
  # Llama Model Streaming via Bedrock Tests
  # ============================================================================

  describe "Llama model streaming via Bedrock" do
    test "streams from Llama 3" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Hello from Llama!"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{"inputTokens" => 8, "outputTokens" => 4}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(
        id: "meta.llama3-70b-instruct-v1:0",
        name: "Llama 3 70B"
      )
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.model == "meta.llama3-70b-instruct-v1:0"
      assert hd(result.content).text == "Hello from Llama!"
    end

    test "Llama model does not get cache points" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})

        frames =
          build_frame("messageStart", %{"role" => "assistant"}) <>
          build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
          build_frame("metadata", %{"usage" => %{}})

        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model(
        id: "meta.llama3-70b-instruct-v1:0",
        name: "Llama 3 70B"
      )
      context = Context.new(
        system_prompt: "You are helpful",
        messages: [%UserMessage{content: "Hi"}]
      )

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      assert_receive {:request_body, body}, 1000

      # Llama models should not have cachePoint in system or messages
      system = body["system"]
      refute Enum.any?(system || [], fn block -> Map.has_key?(block, "cachePoint") end)

      EventStream.result(stream, 5000)
    end
  end

  # ============================================================================
  # Token Usage Accumulation Tests
  # ============================================================================

  describe "token usage accumulation during streaming" do
    test "accumulates input and output tokens" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Response"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{
          "usage" => %{
            "inputTokens" => 100,
            "outputTokens" => 50,
            "totalTokens" => 150
          }
        })

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.usage.input == 100
      assert result.usage.output == 50
      assert result.usage.total_tokens == 150
    end

    test "accumulates cache read and write tokens" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Cached response"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{
          "usage" => %{
            "inputTokens" => 50,
            "outputTokens" => 25,
            "cacheReadInputTokens" => 1000,
            "cacheWriteInputTokens" => 500
          }
        })

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.usage.cache_read == 1000
      assert result.usage.cache_write == 500
    end

    test "handles missing usage fields gracefully" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Response"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{
          "usage" => %{
            "inputTokens" => 10
            # outputTokens missing
          }
        })

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.usage.input == 10
      assert result.usage.output == 0
      assert result.usage.cache_read == 0
      assert result.usage.cache_write == 0
    end

    test "calculates total tokens when not provided" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Response"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{
          "usage" => %{
            "inputTokens" => 40,
            "outputTokens" => 20
            # totalTokens missing
          }
        })

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.usage.total_tokens == 60
    end
  end

  # ============================================================================
  # Request Body Construction Tests
  # ============================================================================

  describe "request body construction for streaming" do
    test "includes modelId in request" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      assert_receive {:request_body, body}, 1000
      assert body["modelId"] == "anthropic.claude-3-5-haiku-20241022-v1:0"

      EventStream.result(stream, 1000)
    end

    test "includes inferenceConfig with temperature and max_tokens" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])
      opts = %{default_opts() | temperature: 0.7, max_tokens: 500}

      {:ok, stream} = Bedrock.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["inferenceConfig"]["temperature"] == 0.7
      assert body["inferenceConfig"]["maxTokens"] == 500

      EventStream.result(stream, 1000)
    end

    test "includes system prompt with cache point for Claude" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      model = default_model(id: "anthropic.claude-3-5-haiku-20241022-v1:0")
      context = Context.new(
        system_prompt: "You are a helpful assistant",
        messages: [%UserMessage{content: "Test"}]
      )

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      assert_receive {:request_body, body}, 1000

      system = body["system"]
      assert length(system) == 2
      assert Enum.at(system, 0)["text"] == "You are a helpful assistant"
      assert Enum.at(system, 1)["cachePoint"]["type"] == "default"

      EventStream.result(stream, 1000)
    end

    test "includes tool configuration" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      tool = %Tool{
        name: "search",
        description: "Search the web",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"}
          },
          "required" => ["query"]
        }
      }

      model = default_model()
      context = Context.new(
        messages: [%UserMessage{content: "Search for cats"}],
        tools: [tool]
      )

      {:ok, stream} = Bedrock.stream(model, context, default_opts())

      assert_receive {:request_body, body}, 1000

      tool_config = body["toolConfig"]
      assert length(tool_config["tools"]) == 1

      tool_spec = hd(tool_config["tools"])["toolSpec"]
      assert tool_spec["name"] == "search"
      assert tool_spec["description"] == "Search the web"

      EventStream.result(stream, 1000)
    end

    test "includes thinking configuration for reasoning models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      model = default_model(
        id: "anthropic.claude-3-7-sonnet-20250219-v1:0",
        reasoning: true
      )
      context = Context.new(messages: [%UserMessage{content: "Think hard"}])
      opts = %{default_opts() | reasoning: :high}

      {:ok, stream} = Bedrock.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      thinking_config = body["additionalModelRequestFields"]["thinking"]
      assert thinking_config["type"] == "enabled"
      assert thinking_config["budget_tokens"] == 16384

      EventStream.result(stream, 1000)
    end

    test "omits tool config when tool_choice is none" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "")
      end)

      tool = %Tool{name: "unused", description: "Unused tool", parameters: %{}}

      model = default_model()
      context = Context.new(
        messages: [%UserMessage{content: "Don't use tools"}],
        tools: [tool]
      )
      opts = %{default_opts() | headers: Map.put(default_opts().headers, "tool_choice", "none")}

      {:ok, stream} = Bedrock.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      refute Map.has_key?(body, "toolConfig")

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Edge Cases and Robustness Tests
  # ============================================================================

  describe "edge cases and robustness" do
    test "handles empty response" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("messageStop", %{"stopReason" => "end_turn"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.content == []
      assert result.stop_reason == :stop
    end

    test "handles unknown stop reason as error" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{"text" => "Test"}
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "unknown_reason"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      context = Context.new(messages: [%UserMessage{content: "Test"}])

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      assert result.stop_reason == :error
    end

    test "handles special characters in tool arguments" do
      frames =
        build_frame("messageStart", %{"role" => "assistant"}) <>
        build_frame("contentBlockStart", %{
          "contentBlockIndex" => 0,
          "start" => %{
            "toolUse" => %{"toolUseId" => "call_1", "name" => "test"}
          }
        }) <>
        build_frame("contentBlockDelta", %{
          "contentBlockIndex" => 0,
          "delta" => %{
            "toolUse" => %{
              "input" => "{\"text\":\"Hello\\nWorld\\t\\\"quoted\\\"\"}"
            }
          }
        }) <>
        build_frame("contentBlockStop", %{"contentBlockIndex" => 0}) <>
        build_frame("messageStop", %{"stopReason" => "tool_use"}) <>
        build_frame("metadata", %{"usage" => %{}})

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, frames)
      end)

      model = default_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Test"}], tools: tools)

      {:ok, stream} = Bedrock.stream(model, context, default_opts())
      {:ok, result} = EventStream.result(stream, 5000)

      tool_call = hd(result.content)
      assert tool_call.arguments["text"] == "Hello\nWorld\t\"quoted\""
    end

    test "provider_id returns :amazon" do
      assert Bedrock.provider_id() == :amazon
    end

    test "api_id returns :bedrock_converse_stream" do
      assert Bedrock.api_id() == :bedrock_converse_stream
    end

    test "get_env_api_key returns nil" do
      assert Bedrock.get_env_api_key() == nil
    end
  end
end
