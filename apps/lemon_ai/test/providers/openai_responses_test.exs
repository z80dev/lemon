defmodule LemonAi.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.OpenAIResponses
  alias LemonAi.Types.{Context, ImageContent, Model, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)

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
      :done ->
        "data: " <>
          Jason.encode!(%{
            "type" => "response.completed",
            "response" => %{"status" => "completed"}
          })

      event ->
        "data: " <> Jason.encode!(event)
    end)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n\n")
  end

  test "omits reasoning config when not requested" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "o1-mini",
      name: "o1-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000
    refute Map.has_key?(req_body, "reasoning")
    refute Map.has_key?(req_body, "include")

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "includes reasoning config when requested" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "o1-mini",
      name: "o1-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} =
      OpenAIResponses.stream(
        model,
        context,
        %StreamOptions{api_key: "test-key", reasoning: :low}
      )

    assert_receive {:request_body, req_body}, 1000
    assert %{"effort" => "low"} = req_body["reasoning"]
    assert "reasoning.encrypted_content" in (req_body["include"] || [])

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "adds copilot headers for :github_copilot" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text, :image]
    }

    image = %ImageContent{data: "AA==", mime_type: "image/png"}
    context = Context.new(messages: [%UserMessage{content: [image]}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_headers, headers}, 1000
    headers_map = Map.new(headers)

    assert headers_map["editor-version"] == "vscode/1.107.0"
    assert headers_map["editor-plugin-version"] == "copilot-chat/0.35.0"
    assert headers_map["user-agent"] == "GitHubCopilotChat/0.35.0"
    assert headers_map["copilot-integration-id"] == "vscode-chat"
    assert headers_map["x-initiator"] == "user"
    assert headers_map["openai-intent"] == "conversation-edits"
    assert headers_map["copilot-vision-request"] == "true"

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "request body snapshot includes tools, reasoning, and service tier" do
    test_pid = self()

    prev_retention = System.get_env("PI_CACHE_RETENTION")
    System.delete_env("PI_CACHE_RETENTION")

    on_exit(fn ->
      if prev_retention,
        do: System.put_env("PI_CACHE_RETENTION", prev_retention),
        else: System.delete_env("PI_CACHE_RETENTION")
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com",
      reasoning: true
    }

    tool = %LemonAi.Types.Tool{
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

    opts =
      %StreamOptions{
        api_key: "test-key",
        session_id: "sess-1",
        max_tokens: 123,
        temperature: 0.1,
        reasoning: :low,
        thinking_budgets: %{summary: "concise", service_tier: "flex"}
      }

    {:ok, stream} = OpenAIResponses.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "gpt-5",
      "input" => [
        %{"role" => "developer", "content" => "System"},
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
      ],
      "stream" => true,
      "prompt_cache_key" => "sess-1",
      "max_output_tokens" => 123,
      "temperature" => 0.1,
      "service_tier" => "flex",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup",
          "description" => "Lookup data",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          },
          "strict" => false
        }
      ],
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "reasoning" => %{"effort" => "low", "summary" => "concise"},
      "include" => ["reasoning.encrypted_content"]
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end

  test "normalizes HTTP error responses" do
    Req.Test.stub(__MODULE__, fn conn ->
      body = %{
        "error" => %{
          "message" =>
            "This model's maximum context length is 8192 tokens. However, you requested 10000 tokens.",
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
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: false
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:error, %LemonAi.Types.AssistantMessage{} = result} = EventStream.result(stream, 1000)
    assert result.stop_reason == :error
    assert result.error_message =~ "Context length exceeded (HTTP 400)"
    assert result.error_message =~ "maximum context length"
  end

  test "rejects truncated streamed final arguments instead of inventing an executable call" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "type" => "response.output_item.added",
            "item" => %{
              "type" => "function_call",
              "id" => "fc_batch",
              "call_id" => "call_batch",
              "name" => "batch_read",
              "arguments" => "{\"files\":[\"mix.exs\""
            }
          },
          %{
            "type" => "response.output_item.done",
            "item" => %{
              "type" => "function_call",
              "id" => "fc_batch",
              "call_id" => "call_batch",
              "name" => "batch_read",
              "arguments" => "{\"files\":[\"mix.exs\""
            }
          },
          %{"type" => "response.completed", "response" => %{"status" => "incomplete"}},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: false
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:error, result} = EventStream.result(stream, 1000)
    assert result.stop_reason == :error
    assert result.content == []
    assert result.error_details.category == :client
    refute LemonAi.Error.retryable?(result)
  end

  test "rejects truncated final-only arguments instead of inventing an executable call" do
    Req.Test.stub(__MODULE__, fn conn ->
      body =
        sse_body([
          %{
            "type" => "response.output_item.added",
            "item" => %{
              "type" => "function_call",
              "id" => "fc_batch",
              "call_id" => "call_batch",
              "name" => "batch_read"
            }
          },
          %{
            "type" => "response.output_item.done",
            "item" => %{
              "type" => "function_call",
              "id" => "fc_batch",
              "call_id" => "call_batch",
              "name" => "batch_read",
              "arguments" => "{\"files\":[\"mix.exs\""
            }
          },
          %{"type" => "response.completed", "response" => %{"status" => "incomplete"}},
          :done
        ])

      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: false
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert {:error, result} = EventStream.result(stream, 1000)
    assert result.stop_reason == :error
    assert result.content == []
    assert result.error_details.category == :client
    refute LemonAi.Error.retryable?(result)
  end

  test "errors when api key is missing" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_called, true})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: false
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    prev_key = System.get_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      if prev_key,
        do: System.put_env("OPENAI_API_KEY", prev_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: nil})

    assert {:error, %LemonAi.Types.AssistantMessage{stop_reason: :error}} =
             EventStream.result(stream, 1000)

    refute_received {:request_called, _}
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
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{})

    assert_receive {:request_headers, headers}, 1000
    assert Map.new(headers)["authorization"] == "Bearer opencode-env-key"
    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  describe "credential scoping" do
    setup do
      prev_openai = System.get_env("OPENAI_API_KEY")
      System.put_env("OPENAI_API_KEY", "openai-env-key")

      on_exit(fn ->
        if prev_openai,
          do: System.put_env("OPENAI_API_KEY", prev_openai),
          else: System.delete_env("OPENAI_API_KEY")
      end)

      :ok
    end

    test "does not send OPENAI_API_KEY to a non-OpenAI provider" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_called, true})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "some-model",
        name: "Some Model",
        api: :openai_responses,
        provider: :together,
        base_url: "https://api.together.test/v1"
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{})

      assert {:error, %LemonAi.Types.AssistantMessage{error_message: message}} =
               EventStream.result(stream, 1000)

      assert message =~ "No API key provided for provider together"
      refute_received {:request_called, _}
    end

    test "sends no Authorization header for keyless models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %Model{
        id: "local-model",
        name: "Local",
        api: :openai_responses,
        provider: :llama_cpp,
        base_url: "http://127.0.0.1:8080/v1",
        compat: %{allow_missing_api_key: true}
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{})

      assert_receive {:request_headers, headers}, 1000
      refute Map.has_key?(Map.new(headers), "authorization")
      assert {:ok, _} = EventStream.result(stream, 1000)
    end
  end
end
