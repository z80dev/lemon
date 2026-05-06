defmodule Ai.Providers.OpenAICompletionsTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.OpenAICompletions

  alias Ai.Types.{
    AssistantMessage,
    Context,
    ImageContent,
    Model,
    StreamOptions,
    TextContent,
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

  defp sse_body(events) do
    events
    |> Enum.map(fn
      :done -> "data: [DONE]"
      event -> "data: " <> Jason.encode!(event)
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  test "uses OPENCODE_API_KEY for opencode provider when api_key option is missing" do
    test_pid = self()
    prev_opencode = System.get_env("OPENCODE_API_KEY")
    prev_openai = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      if is_binary(prev_opencode) do
        System.put_env("OPENCODE_API_KEY", prev_opencode)
      else
        System.delete_env("OPENCODE_API_KEY")
      end

      if is_binary(prev_openai) do
        System.put_env("OPENAI_API_KEY", prev_openai)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    System.put_env("OPENCODE_API_KEY", "opencode-env-key")
    System.put_env("OPENAI_API_KEY", "openai-env-key")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "kimi-k2",
      name: "Kimi K2",
      api: :openai_completions,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{})

    assert_receive {:request_headers, headers}, 1000
    assert Map.new(headers)["authorization"] == "Bearer opencode-env-key"
    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "uses ZAI_API_KEY for zai provider when api_key option is missing" do
    test_pid = self()
    prev_zai = System.get_env("ZAI_API_KEY")
    prev_openai = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      if is_binary(prev_zai) do
        System.put_env("ZAI_API_KEY", prev_zai)
      else
        System.delete_env("ZAI_API_KEY")
      end

      if is_binary(prev_openai) do
        System.put_env("OPENAI_API_KEY", prev_openai)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    System.put_env("ZAI_API_KEY", "zai-env-key")
    System.put_env("OPENAI_API_KEY", "openai-env-key")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "glm-5-turbo",
      name: "GLM 5 Turbo",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/paas/v4"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{})

    assert_receive {:request_headers, headers}, 1000
    assert Map.new(headers)["authorization"] == "Bearer zai-env-key"
    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "uses resolved provider_options api_key and base_url for zai provider" do
    test_pid = self()
    prev_zai = System.get_env("ZAI_API_KEY")
    prev_openai = System.get_env("OPENAI_API_KEY")

    System.delete_env("ZAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      if is_binary(prev_zai) do
        System.put_env("ZAI_API_KEY", prev_zai)
      else
        System.delete_env("ZAI_API_KEY")
      end

      if is_binary(prev_openai) do
        System.put_env("OPENAI_API_KEY", prev_openai)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request, conn.host, conn.request_path, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "glm-5-turbo",
      name: "GLM 5 Turbo",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/paas/v4"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    opts = %StreamOptions{
      provider_options: %{
        zai: %{
          api_key: "zai-resolved-key",
          base_url: "https://override.zai.test/v4"
        }
      }
    }

    {:ok, stream} = OpenAICompletions.stream(model, context, opts)

    assert_receive {:request, "override.zai.test", "/v4/chat/completions", headers}, 1000
    assert Map.new(headers)["authorization"] == "Bearer zai-resolved-key"
    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "retries retryable transport errors before succeeding" do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      attempt =
        Agent.get_and_update(attempts, fn count ->
          next = count + 1
          {next, next}
        end)

      send(test_pid, {:transport_attempt, attempt})

      case attempt do
        1 -> Req.Test.transport_error(conn, :closed)
        _ -> Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end
    end)

    model = %Model{
      id: "glm-5.1",
      name: "GLM-5.1",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:transport_attempt, 1}, 1000
    assert_receive {:transport_attempt, 2}, 1500
    assert {:ok, _result} = EventStream.result(stream, 2000)
  end

  test "retries retryable HTTP failures before succeeding" do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      attempt =
        Agent.get_and_update(attempts, fn count ->
          next = count + 1
          {next, next}
        end)

      send(test_pid, {:http_attempt, attempt})

      case attempt do
        1 -> Plug.Conn.send_resp(conn, 503, ~s({"error":"temporary overload"}))
        _ -> Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end
    end)

    model = %Model{
      id: "glm-5.1",
      name: "GLM-5.1",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:http_attempt, 1}, 1000
    assert_receive {:http_attempt, 2}, 1500
    assert {:ok, _result} = EventStream.result(stream, 2000)
  end

  test "honors retry-after headers for retryable HTTP failures" do
    test_pid = self()
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn conn ->
      attempt =
        Agent.get_and_update(attempts, fn count ->
          next = count + 1
          {next, next}
        end)

      send(test_pid, {:retry_after_attempt, attempt, System.monotonic_time(:millisecond)})

      case attempt do
        1 ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0.001")
          |> Plug.Conn.send_resp(429, ~s({"error":"rate limited"}))

        _ ->
          Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end
    end)

    model = %Model{
      id: "glm-5.1",
      name: "GLM-5.1",
      api: :openai_completions,
      provider: :zai,
      base_url: "https://api.z.ai/api/coding/paas/v4"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:retry_after_attempt, 1, first_at}, 1000
    assert_receive {:retry_after_attempt, 2, second_at}, 1600
    assert second_at - first_at >= 950
    assert {:ok, _result} = EventStream.result(stream, 2000)
  end

  test "normalizes context length HTTP errors" do
    Req.Test.stub(__MODULE__, fn conn ->
      body = %{
        "error" => %{
          "message" =>
            "This model's maximum context length is 8192 tokens. However, you requested 10000 tokens.",
          "type" => "invalid_request_error",
          "param" => "messages",
          "code" => "context_length_exceeded"
        }
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(body))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:error, %AssistantMessage{} = result} = EventStream.result(stream, 1000)
    assert result.stop_reason == :error
    assert result.error_message =~ "Context length exceeded (HTTP 400)"
    assert result.error_message =~ "maximum context length"
  end

  test "merges headers with opts overriding model headers" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test",
      headers: %{"X-Model-Header" => "model-value"}
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    opts =
      %StreamOptions{
        api_key: "test-key",
        headers: %{"X-Model-Header" => "opts-value", "X-Opt-Header" => "opt-value"}
      }

    {:ok, stream} = OpenAICompletions.stream(model, context, opts)

    assert_receive {:request_headers, headers}, 1000

    headers_map = Map.new(headers)

    assert headers_map["authorization"] == "Bearer test-key"
    assert headers_map["content-type"] == "application/json"
    assert headers_map["x-model-header"] == "opts-value"
    assert headers_map["x-opt-header"] == "opt-value"

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  describe "copilot headers" do
    test "adds copilot headers for :github_copilot provider" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "gpt-4o-mini",
        name: "GPT-4o mini",
        api: :openai_completions,
        provider: :github_copilot,
        base_url: "https://example.test"
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["editor-version"] == "vscode/1.107.0"
      assert headers_map["editor-plugin-version"] == "copilot-chat/0.35.0"
      assert headers_map["user-agent"] == "GitHubCopilotChat/0.35.0"
      assert headers_map["copilot-integration-id"] == "vscode-chat"
      assert headers_map["x-initiator"] == "user"
      assert headers_map["openai-intent"] == "conversation-edits"
      refute headers_map["copilot-vision-request"]

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "sets x-initiator to agent when last message is not from user" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "gpt-4o-mini",
        name: "GPT-4o mini",
        api: :openai_completions,
        provider: :github_copilot,
        base_url: "https://example.test"
      }

      # Last message is assistant -> should be "agent"
      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hi"},
            %AssistantMessage{content: [%TextContent{text: "Hello!"}]}
          ]
        )

      {:ok, stream} =
        OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["x-initiator"] == "agent"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end

    test "adds copilot-vision-request header when messages contain images" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "gpt-4o-mini",
        name: "GPT-4o mini",
        api: :openai_completions,
        provider: :github_copilot,
        base_url: "https://example.test"
      }

      image = %ImageContent{data: "AA==", mime_type: "image/png"}
      context = Context.new(messages: [%UserMessage{content: [image]}])

      {:ok, stream} =
        OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["copilot-vision-request"] == "true"

      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end

  test "request body snapshot includes tools and generation params" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, sse_body([%{"error" => "bad"}]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    tool = %Ai.Types.Tool{
      name: "lookup",
      description: "Lookup data",
      parameters: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      }
    }

    context =
      Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: [tool])

    opts = %StreamOptions{api_key: "test-key", max_tokens: 111, temperature: 0.2}

    {:ok, stream} = OpenAICompletions.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "gpt-4o-mini",
      "messages" => [
        %{"role" => "system", "content" => "System"},
        %{"role" => "user", "content" => "Hi"}
      ],
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "store" => false,
      "max_completion_tokens" => 111,
      "temperature" => 0.2,
      "tools" => [
        %{
          "type" => "function",
          "function" => %{
            "name" => "lookup",
            "description" => "Lookup data",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"q" => %{"type" => "string"}},
              "required" => ["q"]
            },
            "strict" => false
          }
        }
      ]
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end

  test "includes tools: [] when tool history exists but no tools provided" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    tool_call = %ToolCall{id: "call_1", name: "tool_a", arguments: %{}}

    assistant = %Ai.Types.AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_completions,
      provider: :openai,
      model: "gpt-4o-mini",
      usage: %Ai.Types.Usage{cost: %Ai.Types.Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [assistant])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000
    assert Map.has_key?(req_body, "tools")
    assert req_body["tools"] == []

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "sanitizes invalid utf8 in assistant tool call arguments before encoding request" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    invalid_utf8 = <<"ok", 0xED, 0xA0, 0x80>>
    tool_call = %ToolCall{id: "call_1", name: "echo", arguments: %{"text" => invalid_utf8}}

    assistant = %AssistantMessage{
      role: :assistant,
      content: [tool_call],
      api: :openai_completions,
      provider: :openai,
      model: "gpt-4o-mini",
      usage: %Ai.Types.Usage{cost: %Ai.Types.Cost{}},
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [assistant])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    [%{"tool_calls" => [%{"function" => %{"arguments" => encoded_args}}]}] =
      req_body["messages"]

    assert Jason.decode!(encoded_args) == %{"text" => "ok"}
    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "sanitizes invalid utf8 in system and user content before encoding request" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    invalid_system = <<"system", 0xED, 0xA0, 0x80>>
    invalid_user = <<"user", 0xED, 0xB0, 0x80>>

    context =
      Context.new(system_prompt: invalid_system, messages: [%UserMessage{content: invalid_user}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    assert [
             %{"role" => "system", "content" => "system"},
             %{"role" => "user", "content" => "user"}
           ] = req_body["messages"]

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "uses developer role for reasoning models when supported" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "o1-mini",
      name: "o1-mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    [first | _] = req_body["messages"]
    assert first["role"] == "developer"

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "sends consecutive tool results as separate tool messages" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)
      send(test_pid, {:request_body, body})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    tool_result_1 = %ToolResultMessage{
      tool_call_id: "call_1",
      tool_name: "tool_a",
      content: [%TextContent{text: "ok-1"}],
      timestamp: System.system_time(:millisecond)
    }

    tool_result_2 = %ToolResultMessage{
      tool_call_id: "call_2",
      tool_name: "tool_b",
      content: [%TextContent{text: "ok-2"}],
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [tool_result_1, tool_result_2])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    tool_messages =
      req_body
      |> Map.get("messages", [])
      |> Enum.filter(&(&1["role"] == "tool"))

    assert length(tool_messages) == 2
    assert Enum.map(tool_messages, & &1["tool_call_id"]) == ["call_1", "call_2"]

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "normalizes tool_call_id when pipe-separated" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    tool_result = %ToolResultMessage{
      tool_call_id: "call$1|fc_2",
      tool_name: "tool_a",
      content: [%TextContent{text: "ok"}],
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [tool_result])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    [tool_msg] =
      req_body
      |> Map.get("messages", [])
      |> Enum.filter(&(&1["role"] == "tool"))

    assert tool_msg["tool_call_id"] == "call_1"

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "normalizes mistral tool ids to 9 chars" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "mistral-large",
      name: "Mistral Large",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai"
    }

    tool_result = %ToolResultMessage{
      tool_call_id: "abc",
      tool_name: "tool_a",
      content: [%TextContent{text: "ok"}],
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [tool_result])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    [tool_msg] =
      req_body
      |> Map.get("messages", [])
      |> Enum.filter(&(&1["role"] == "tool"))

    assert tool_msg["tool_call_id"] == "abcABCDEF"

    assert {:ok, _result} = EventStream.result(stream, 1000)
  end

  test "clamps cached tokens to avoid negative input usage" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "usage" => %{
              "prompt_tokens" => 1,
              "completion_tokens" => 0,
              "prompt_tokens_details" => %{"cached_tokens" => 5}
            }
          },
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)
    assert result.usage.input == 0
    assert result.usage.cache_read == 5
  end

  test "streams multiple tool calls with indices" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_a",
                      "type" => "function",
                      "function" => %{"name" => "tool_a", "arguments" => "{\"foo\":"}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 1,
                      "id" => "call_b",
                      "type" => "function",
                      "function" => %{"name" => "tool_b", "arguments" => "{\"bar\":\""}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "function" => %{"arguments" => "1}"}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 1,
                      "function" => %{"arguments" => "baz\"}"}
                    }
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "tool_calls"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    tool_calls = Enum.filter(result.content, &match?(%ToolCall{}, &1))
    assert length(tool_calls) == 2

    [first, second] = tool_calls
    assert first.id == "call_a"
    assert first.name == "tool_a"
    assert first.arguments == %{"foo" => 1}

    assert second.id == "call_b"
    assert second.name == "tool_b"
    assert second.arguments == %{"bar" => "baz"}
  end

  test "normalizes streamed tool calls missing provider identity fields" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "type" => "function",
                      "function" => %{"arguments" => "{\"path\":\"mix.exs\"}"}
                    }
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "tool_calls"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    assert [%ToolCall{} = tool_call] = result.content
    assert tool_call.id == "call_stream_0"
    assert tool_call.name == "unknown_tool"
    assert tool_call.arguments == %{"path" => "mix.exs"}
    assert result.stop_reason == :tool_use
  end

  test "normalizes duplicate streamed tool call ids to unique ids" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_dup",
                      "type" => "function",
                      "function" => %{"name" => "tool_a", "arguments" => "{\"foo\":1}"}
                    },
                    %{
                      "index" => 1,
                      "id" => "call_dup",
                      "type" => "function",
                      "function" => %{"name" => "tool_b", "arguments" => "{\"bar\":"}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 1,
                      "id" => "call_dup",
                      "function" => %{"arguments" => "2}"}
                    }
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "tool_calls"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    assert [%ToolCall{} = first, %ToolCall{} = second] = result.content
    assert first.id == "call_dup"
    assert first.name == "tool_a"
    assert first.arguments == %{"foo" => 1}

    assert second.id == "call_dup_1_1"
    assert second.name == "tool_b"
    assert second.arguments == %{"bar" => 2}
    assert result.stop_reason == :tool_use
  end

  test "preserves recoverable truncated streamed tool call arguments" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_batch",
                      "type" => "function",
                      "function" => %{
                        "name" => "batch_read",
                        "arguments" => "{\"files\":[\"mix.exs\""
                      }
                    }
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "length"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)
    assert [%ToolCall{name: "batch_read", arguments: %{"files" => ["mix.exs"]}}] = result.content
    assert result.stop_reason == :length
  end

  test "streams chunked tool names without duplicating repeated suffixes" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_read",
                      "type" => "function",
                      "function" => %{"name" => "read_", "arguments" => "{\"path\":"}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "function" => %{"name" => "file", "arguments" => "\"mix.exs\"}"}
                    }
                  ]
                }
              }
            ]
          },
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "function" => %{"name" => "file"}
                    }
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "tool_calls"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)
    assert [%ToolCall{name: "read_file", arguments: %{"path" => "mix.exs"}}] = result.content
  end

  test "reasoning_details attaches thought signature to tool calls" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_a",
                      "type" => "function",
                      "function" => %{"name" => "tool_a", "arguments" => "{}"}
                    }
                  ],
                  "reasoning_details" => [
                    %{"type" => "reasoning.encrypted", "id" => "call_a", "data" => "abc"}
                  ]
                }
              }
            ]
          },
          %{"choices" => [%{"finish_reason" => "tool_calls"}]},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    [%ToolCall{thought_signature: signature}] =
      result.content |> Enum.filter(&match?(%ToolCall{}, &1))

    assert is_binary(signature)
  end

  test "string tool_call indices are parsed correctly" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => "1",
                      "id" => "call_b",
                      "type" => "function",
                      "function" => %{"name" => "tool_b", "arguments" => "{}"}
                    }
                  ]
                }
              }
            ]
          },
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    [%ToolCall{id: "call_b"}] = Enum.filter(result.content, &match?(%ToolCall{}, &1))
  end

  test "thinking blocks are converted to text when required" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "mistral-large",
      name: "Mistral Large",
      api: :openai_completions,
      provider: :mistral,
      base_url: "https://api.mistral.ai",
      compat: %{requires_thinking_as_text: true}
    }

    assistant =
      %Ai.Types.AssistantMessage{
        role: :assistant,
        content: [
          %Ai.Types.ThinkingContent{thinking: "thoughts"},
          %TextContent{text: "answer"}
        ],
        api: :openai_completions,
        provider: :mistral,
        model: "mistral-large",
        usage: %Ai.Types.Usage{cost: %Ai.Types.Cost{}},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

    context = Context.new(messages: [assistant])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    assistant_msg =
      req_body["messages"]
      |> Enum.find(&(&1["role"] == "assistant"))

    assert is_list(assistant_msg["content"])
    assert Enum.any?(assistant_msg["content"], &(&1["text"] == "thoughts"))

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "does not insert duplicate assistant after tool result images" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://example.test",
      input: [:text, :image],
      compat: %{requires_assistant_after_tool_result: true}
    }

    tool_result = %ToolResultMessage{
      tool_call_id: "call_1",
      tool_name: "tool_a",
      content: [%ImageContent{data: "AA==", mime_type: "image/png"}],
      timestamp: System.system_time(:millisecond)
    }

    context = Context.new(messages: [tool_result, %UserMessage{content: "Next"}])

    {:ok, stream} = OpenAICompletions.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000

    assistant_messages =
      req_body
      |> Map.get("messages", [])
      |> Enum.filter(fn msg ->
        msg["role"] == "assistant" and msg["content"] == "I have processed the tool results."
      end)

    assert length(assistant_messages) == 1

    assert {:ok, _} = EventStream.result(stream, 1000)
  end
end
