defmodule Ai.Providers.GoogleGeminiCliComprehensiveTest do
  @moduledoc """
  Comprehensive tests for the Google Gemini CLI / Cloud Code Assist provider.

  Tests cover:
  - Provider identification and registration
  - Credential parsing and validation
  - Request body construction
  - Header construction (standard and antigravity)
  - SSE response parsing
  - Text streaming
  - Thinking/reasoning content
  - Tool/function calls
  - Usage and cost tracking
  - Error handling and retries
  - Stop reason mapping
  - Generation config options
  - Antigravity (Claude model) support
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.GoogleGeminiCli

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
  # Helper Functions
  # ============================================================================

  defp sse_body(chunks) do
    chunks
    |> Enum.map(&("data: " <> Jason.encode!(&1)))
    |> Enum.join("\n")
  end

  defp default_model do
    %Model{
      id: "gemini-2.5-pro",
      name: "Gemini 2.5 Pro",
      api: :google_gemini_cli,
      provider: :google_gemini_cli,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192,
      headers: %{}
    }
  end

  defp antigravity_model do
    %Model{
      id: "claude-3-7-sonnet-thinking",
      name: "Claude 3.7 Sonnet (Antigravity)",
      api: :google_gemini_cli,
      provider: :google_antigravity,
      base_url: "",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{}
    }
  end

  defp default_api_key do
    Jason.encode!(%{"token" => "test-oauth-token", "projectId" => "test-project-123"})
  end

  defp default_context do
    Context.new(messages: [%UserMessage{content: "Hello"}])
  end

  defp default_opts do
    %StreamOptions{api_key: default_api_key()}
  end

  # ============================================================================
  # Provider Identification Tests
  # ============================================================================

  describe "provider identification" do
    test "provider_id returns :google_gemini_cli" do
      assert GoogleGeminiCli.provider_id() == :google_gemini_cli
    end

    test "api_id returns :google_gemini_cli" do
      assert GoogleGeminiCli.api_id() == :google_gemini_cli
    end

    test "get_env_api_key returns nil (OAuth required)" do
      assert GoogleGeminiCli.get_env_api_key() == nil
    end
  end

  # ============================================================================
  # Credential Parsing Tests
  # ============================================================================

  describe "credential parsing" do
    test "valid credentials are parsed correctly" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      api_key = Jason.encode!(%{"token" => "my-token", "projectId" => "my-project"})
      opts = %StreamOptions{api_key: api_key}

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["project"] == "my-project"
      assert {:error, _} = EventStream.result(stream, 500)
    end

    test "nil credentials result in error" do
      body = sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      opts = %StreamOptions{api_key: nil}
      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert {:error, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :error
      assert result.error_message =~ "requires OAuth authentication"
    end

    test "invalid JSON credentials result in error" do
      body = sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      opts = %StreamOptions{api_key: "not-valid-json"}
      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert {:error, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :error
      assert result.error_message =~ "Invalid Google Cloud Code Assist credentials"
    end

    test "credentials missing token field result in error" do
      body = sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      api_key = Jason.encode!(%{"projectId" => "proj"})
      opts = %StreamOptions{api_key: api_key}

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert {:error, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :error
    end

    test "credentials missing projectId field result in error" do
      body = sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      api_key = Jason.encode!(%{"token" => "token"})
      opts = %StreamOptions{api_key: api_key}

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert {:error, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :error
    end
  end

  # ============================================================================
  # Request Body Construction Tests
  # ============================================================================

  describe "request body construction" do
    test "includes project and model in request body" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      assert body["project"] == "test-project-123"
      assert body["model"] == "gemini-2.5-pro"
    end

    test "includes userAgent as pi-coding-agent for non-antigravity" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      assert body["userAgent"] == "pi-coding-agent"
    end

    test "includes userAgent as antigravity for antigravity models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = antigravity_model()
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      assert body["userAgent"] == "antigravity"
      assert body["requestType"] == "agent"
    end

    test "generates unique requestId with correct format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      assert is_binary(body["requestId"])
      assert Regex.match?(~r/^pi-\d+-[a-f0-9]{12}$/, body["requestId"])
    end

    test "antigravity requestId uses agent prefix" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = antigravity_model()
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      assert Regex.match?(~r/^agent-\d+-[a-f0-9]{12}$/, body["requestId"])
    end

    test "includes session_id when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      opts = %StreamOptions{api_key: default_api_key(), session_id: "session-abc"}
      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["sessionId"] == "session-abc"
    end

    test "includes system instruction when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context =
        Context.new(
          system_prompt: "You are a helpful assistant",
          messages: [%UserMessage{content: "Hi"}]
        )

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000

      assert body["request"]["systemInstruction"]["parts"] == [
               %{"text" => "You are a helpful assistant"}
             ]
    end

    test "omits system instruction when not provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body["request"], "systemInstruction")
    end

    test "antigravity includes system instruction even when not provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = antigravity_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, _stream} = GoogleGeminiCli.stream(model, context, default_opts())

      assert_receive {:request_body, body}, 1000
      assert Map.has_key?(body["request"], "systemInstruction")
      # Antigravity uses user role for system instruction
      assert body["request"]["systemInstruction"]["role"] == "user"
    end
  end

  # ============================================================================
  # Generation Config Tests
  # ============================================================================

  describe "generation config" do
    test "includes temperature when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      opts = %StreamOptions{api_key: default_api_key(), temperature: 0.7}
      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["generationConfig"]["temperature"] == 0.7
    end

    test "includes max_tokens as maxOutputTokens when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      opts = %StreamOptions{api_key: default_api_key(), max_tokens: 1024}
      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["generationConfig"]["maxOutputTokens"] == 1024
    end

    test "omits generationConfig when no options provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body["request"], "generationConfig")
    end

    test "includes thinking config when model supports reasoning and reasoning option set" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = %{default_model() | reasoning: true}

      opts = %StreamOptions{
        api_key: default_api_key(),
        reasoning: :low,
        thinking_budgets: %{level: "LOW"}
      }

      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["generationConfig"]["thinkingConfig"]["includeThoughts"] == true
      assert body["request"]["generationConfig"]["thinkingConfig"]["thinkingLevel"] == "LOW"
    end

    test "includes thinking budget when specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = %{default_model() | reasoning: true}

      opts = %StreamOptions{
        api_key: default_api_key(),
        reasoning: :high,
        thinking_budgets: %{budget_tokens: 16384}
      }

      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["generationConfig"]["thinkingConfig"]["includeThoughts"] == true
      assert body["request"]["generationConfig"]["thinkingConfig"]["thinkingBudget"] == 16384
    end
  end

  # ============================================================================
  # Tool Configuration Tests
  # ============================================================================

  describe "tool configuration" do
    test "includes tools when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      tools = [
        %Tool{
          name: "read_file",
          description: "Read a file",
          parameters: %{
            "type" => "object",
            "properties" => %{"path" => %{"type" => "string"}},
            "required" => ["path"]
          }
        }
      ]

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      assert length(body["request"]["tools"]) == 1
      [tool_group] = body["request"]["tools"]
      [func_decl] = tool_group["functionDeclarations"]
      assert func_decl["name"] == "read_file"
      assert func_decl["description"] == "Read a file"
    end

    test "includes toolConfig with tool_choice AUTO" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = %StreamOptions{api_key: default_api_key(), tool_choice: :auto}

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["toolConfig"]["functionCallingConfig"]["mode"] == "AUTO"
    end

    test "includes toolConfig with tool_choice ANY" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = %StreamOptions{api_key: default_api_key(), tool_choice: :any}

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["toolConfig"]["functionCallingConfig"]["mode"] == "ANY"
    end

    test "includes toolConfig with tool_choice NONE" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = %StreamOptions{api_key: default_api_key(), tool_choice: :none}

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["request"]["toolConfig"]["functionCallingConfig"]["mode"] == "NONE"
    end

    test "omits toolConfig when tool_choice is nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body["request"], "toolConfig")
    end
  end

  # ============================================================================
  # Header Construction Tests
  # ============================================================================

  describe "header construction" do
    test "includes Authorization header with Bearer token" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        auth_header = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:auth_header, auth_header})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:auth_header, [auth]}, 1000
      assert auth == "Bearer test-oauth-token"
    end

    test "includes standard Gemini CLI headers for non-antigravity" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        user_agent = Plug.Conn.get_req_header(conn, "user-agent")
        x_goog = Plug.Conn.get_req_header(conn, "x-goog-api-client")
        send(test_pid, {:headers, user_agent, x_goog})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:headers, [user_agent], [x_goog]}, 1000
      assert user_agent =~ "google-cloud-sdk"
      assert x_goog =~ "gl-node"
    end

    test "includes antigravity headers for antigravity models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        user_agent = Plug.Conn.get_req_header(conn, "user-agent")
        send(test_pid, {:user_agent, user_agent})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = antigravity_model()
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:user_agent, [user_agent]}, 1000
      assert user_agent =~ "antigravity"
    end

    test "includes anthropic-beta header for claude thinking models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        beta_header = Plug.Conn.get_req_header(conn, "anthropic-beta")
        send(test_pid, {:beta, beta_header})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = antigravity_model()
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:beta, [beta]}, 1000
      assert beta =~ "interleaved-thinking"
    end

    test "includes custom headers from model" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        custom = Plug.Conn.get_req_header(conn, "x-custom-header")
        send(test_pid, {:custom, custom})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      model = %{default_model() | headers: %{"x-custom-header" => "custom-value"}}
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:custom, [custom]}, 1000
      assert custom == "custom-value"
    end

    test "includes custom headers from opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        custom = Plug.Conn.get_req_header(conn, "x-opts-header")
        send(test_pid, {:custom, custom})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      opts = %StreamOptions{
        api_key: default_api_key(),
        headers: %{"x-opts-header" => "opts-value"}
      }

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert_receive {:custom, [custom]}, 1000
      assert custom == "opts-value"
    end
  end

  # ============================================================================
  # SSE Streaming Tests
  # ============================================================================

  describe "SSE streaming" do
    test "streams text responses end-to-end" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]
            }
          },
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => " world"}]}}]
            }
          },
          %{
            "response" => %{
              "candidates" => [%{"finishReason" => "STOP"}],
              "usageMetadata" => %{
                "promptTokenCount" => 10,
                "candidatesTokenCount" => 5,
                "totalTokenCount" => 15
              }
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert EventStream.collect_text(stream) == "Hello world"
      assert {:ok, result} = EventStream.result(stream)
      assert result.stop_reason == :stop
    end

    test "handles empty parts gracefully" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => []}}]}},
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert EventStream.collect_text(stream) == "Hello"
    end

    test "handles response without candidates" do
      body =
        sse_body([
          %{"response" => %{}},
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert EventStream.collect_text(stream) == "Hi"
    end

    test "handles unwrapped response format" do
      # Some responses don't have the "response" wrapper
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Direct"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert EventStream.collect_text(stream) == "Direct"
    end
  end

  # ============================================================================
  # Thinking Content Tests
  # ============================================================================

  describe "thinking content" do
    test "processes thinking parts with thought marker" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{"content" => %{"parts" => [%{"text" => "Let me think...", "thought" => true}]}}
              ]
            }
          },
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "The answer is 42"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      # Should have both thinking and text content
      assert length(result.content) == 2

      [thinking_block, text_block] = result.content
      assert %ThinkingContent{thinking: "Let me think..."} = thinking_block
      assert %TextContent{text: "The answer is 42"} = text_block
    end

    test "preserves thought signature during streaming" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{"text" => "Thinking", "thought" => true, "thoughtSignature" => "sig123"}
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      [thinking_block] = result.content
      assert %ThinkingContent{thinking_signature: "sig123"} = thinking_block
    end

    test "transitions from thinking to text correctly" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{"content" => %{"parts" => [%{"text" => "Think 1", "thought" => true}]}}
              ]
            }
          },
          %{
            "response" => %{
              "candidates" => [
                %{"content" => %{"parts" => [%{"text" => "Think 2", "thought" => true}]}}
              ]
            }
          },
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Response"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert length(result.content) == 2
      [thinking_block, text_block] = result.content
      assert %ThinkingContent{thinking: "Think 1Think 2"} = thinking_block
      assert %TextContent{text: "Response"} = text_block
    end

    test "transitions from text to thinking correctly" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Initial"}]}}]
            }
          },
          %{
            "response" => %{
              "candidates" => [
                %{"content" => %{"parts" => [%{"text" => "More thinking", "thought" => true}]}}
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert length(result.content) == 2
      [text_block, thinking_block] = result.content
      assert %TextContent{text: "Initial"} = text_block
      assert %ThinkingContent{thinking: "More thinking"} = thinking_block
    end
  end

  # ============================================================================
  # Tool Call Tests
  # ============================================================================

  describe "tool calls" do
    test "processes function call parts" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{
                        "functionCall" => %{
                          "name" => "read_file",
                          "args" => %{"path" => "/test/file.txt"}
                        }
                      }
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert result.stop_reason == :tool_use
      assert length(result.content) == 1

      [tool_call] = result.content
      assert %ToolCall{name: "read_file", arguments: %{"path" => "/test/file.txt"}} = tool_call
    end

    test "generates unique tool call IDs when not provided" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{"functionCall" => %{"name" => "tool1", "args" => %{}}},
                      %{"functionCall" => %{"name" => "tool2", "args" => %{}}}
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert length(result.content) == 2
      [tc1, tc2] = result.content
      assert tc1.id != tc2.id
      assert tc1.id =~ "tool1"
      assert tc2.id =~ "tool2"
    end

    test "uses provided tool call ID when available" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{
                        "functionCall" => %{
                          "id" => "custom-id-123",
                          "name" => "test",
                          "args" => %{}
                        }
                      }
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      [tool_call] = result.content
      assert tool_call.id == "custom-id-123"
    end

    test "ends text block before processing function call" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Let me check..."}]}}]
            }
          },
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [%{"functionCall" => %{"name" => "check", "args" => %{}}}]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert length(result.content) == 2
      [text_block, tool_call] = result.content
      assert %TextContent{text: "Let me check..."} = text_block
      assert %ToolCall{name: "check"} = tool_call
    end

    test "preserves thought signature on tool calls" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{
                        "functionCall" => %{"name" => "test", "args" => %{}},
                        "thoughtSignature" => "tool-sig-456"
                      }
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      [tool_call] = result.content
      assert tool_call.thought_signature == "tool-sig-456"
    end
  end

  # ============================================================================
  # Usage and Cost Tests
  # ============================================================================

  describe "usage and cost tracking" do
    test "extracts usage metadata from response" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{
            "response" => %{
              "candidates" => [%{"finishReason" => "STOP"}],
              "usageMetadata" => %{
                "promptTokenCount" => 100,
                "candidatesTokenCount" => 50,
                "thoughtsTokenCount" => 25,
                "cachedContentTokenCount" => 10,
                "totalTokenCount" => 175
              }
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      # input = promptTokenCount - cachedContentTokenCount = 100 - 10 = 90
      assert result.usage.input == 90
      # output = candidatesTokenCount + thoughtsTokenCount = 50 + 25 = 75
      assert result.usage.output == 75
      assert result.usage.cache_read == 10
      assert result.usage.total_tokens == 175
    end

    test "calculates costs based on model pricing" do
      model = %{
        default_model()
        | cost: %ModelCost{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 0.0}
      }

      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{
            "response" => %{
              "candidates" => [%{"finishReason" => "STOP"}],
              "usageMetadata" => %{
                "promptTokenCount" => 1000,
                "candidatesTokenCount" => 500,
                "cachedContentTokenCount" => 100,
                "totalTokenCount" => 1500
              }
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      # input: 900 * 1.0 / 1_000_000 = 0.0009
      assert_in_delta result.usage.cost.input, 0.0009, 0.00001
      # output: 500 * 2.0 / 1_000_000 = 0.001
      assert_in_delta result.usage.cost.output, 0.001, 0.00001
      # cache_read: 100 * 0.5 / 1_000_000 = 0.00005
      assert_in_delta result.usage.cost.cache_read, 0.00005, 0.000001
    end

    test "handles missing usage metadata gracefully" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      # Should have default zero usage
      assert result.usage.input == 0
      assert result.usage.output == 0
    end
  end

  # ============================================================================
  # Stop Reason Tests
  # ============================================================================

  describe "stop reason mapping" do
    test "STOP maps to :stop" do
      body =
        sse_body([
          %{
            "response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Done"}]}}]}
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :stop
    end

    test "MAX_TOKENS maps to :length" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Truncated"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "MAX_TOKENS"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :length
    end

    test "tool calls set stop_reason to :tool_use" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [%{"functionCall" => %{"name" => "test", "args" => %{}}}]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :tool_use
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles HTTP 400 errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        # Return error without streaming (no SSE)
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error": {"message": "Invalid request"}}))
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:error, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :error
      # The error message contains the status code
      assert result.error_message =~ "400"
    end

    test "handles HTTP 401 unauthorized errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error": {"message": "Invalid credentials"}}))
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:error, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :error
      assert result.error_message =~ "401"
    end

    test "handles HTTP 404 not found errors" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, ~s({"error": {"message": "Model not found"}}))
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:error, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :error
      assert result.error_message =~ "404"
    end

    test "handles non-JSON error responses" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(500, "Internal Server Error")
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:error, result} = EventStream.result(stream, 10000)
      assert result.stop_reason == :error
      assert result.error_message =~ "500"
    end

    test "handles malformed SSE data gracefully" do
      # Mix of invalid and valid JSON - only valid parts should be processed
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Valid"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      # Should complete without crashing
      assert EventStream.collect_text(stream) == "Valid"
    end

    test "handles empty response content gracefully" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => []}}]}},
          %{
            "response" => %{
              "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert EventStream.collect_text(stream) == "Hello"
    end
  end

  # ============================================================================
  # Message Conversion Tests
  # ============================================================================

  describe "message conversion" do
    test "converts user messages to Gemini format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hello there"}
          ]
        )

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      [content] = body["request"]["contents"]
      assert content["role"] == "user"
      assert content["parts"] == [%{"text" => "Hello there"}]
    end

    test "converts assistant messages to model role" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hi"},
            %AssistantMessage{
              content: [%TextContent{text: "Hello!"}],
              provider: :google_gemini_cli,
              model: "gemini-2.5-pro"
            }
          ]
        )

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      [_user, assistant] = body["request"]["contents"]
      assert assistant["role"] == "model"
      assert assistant["parts"] == [%{"text" => "Hello!"}]
    end

    test "converts tool result messages to function response format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hi"},
            %AssistantMessage{
              content: [%ToolCall{id: "tc1", name: "read_file", arguments: %{"path" => "/test"}}],
              provider: :google_gemini_cli,
              model: "gemini-2.5-pro"
            },
            %ToolResultMessage{
              tool_call_id: "tc1",
              tool_name: "read_file",
              content: [%TextContent{text: "file contents"}],
              is_error: false
            }
          ]
        )

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      [_user, _assistant, tool_result] = body["request"]["contents"]
      assert tool_result["role"] == "user"
      [part] = tool_result["parts"]
      assert part["functionResponse"]["name"] == "read_file"
      assert part["functionResponse"]["response"]["output"] == "file contents"
    end

    test "converts error tool results correctly" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hi"},
            %AssistantMessage{
              content: [%ToolCall{id: "tc1", name: "read_file", arguments: %{}}],
              provider: :google_gemini_cli,
              model: "gemini-2.5-pro"
            },
            %ToolResultMessage{
              tool_call_id: "tc1",
              tool_name: "read_file",
              content: [%TextContent{text: "File not found"}],
              is_error: true
            }
          ]
        )

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), context, default_opts())

      assert_receive {:request_body, body}, 1000
      [_user, _assistant, tool_result] = body["request"]["contents"]
      [part] = tool_result["parts"]
      assert part["functionResponse"]["response"]["error"] == "File not found"
    end
  end

  # ============================================================================
  # URL Construction Tests
  # ============================================================================

  describe "URL construction" do
    test "uses model base_url when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:url, conn.request_path})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:url, path}, 1000
      assert path == "/v1internal:streamGenerateContent"
    end

    test "includes alt=sse query parameter" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:query, conn.query_string})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:query, query}, 1000
      assert query == "alt=sse"
    end
  end

  # ============================================================================
  # Output Initialization Tests
  # ============================================================================

  describe "output initialization" do
    test "initializes output with correct model and provider" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert result.model == "gemini-2.5-pro"
      assert result.provider == :google_gemini_cli
      assert result.api == :google_gemini_cli
      assert result.role == :assistant
    end

    test "includes timestamp in output" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      before_time = System.system_time(:millisecond)
      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())
      assert {:ok, result} = EventStream.result(stream, 1000)
      after_time = System.system_time(:millisecond)

      assert result.timestamp >= before_time
      assert result.timestamp <= after_time
    end
  end

  # ============================================================================
  # Registration Tests
  # ============================================================================

  describe "provider registration" do
    test "child_spec returns correct specification" do
      spec = GoogleGeminiCli.child_spec([])

      assert spec.id == GoogleGeminiCli
      assert spec.type == :worker
      assert spec.restart == :transient
    end

    test "register function registers with provider registry" do
      result = GoogleGeminiCli.register([])
      assert result == :ignore
    end
  end

  # ============================================================================
  # Content Type Tests
  # ============================================================================

  describe "content type handling" do
    test "only processes text and function call parts" do
      body =
        sse_body([
          %{
            "response" => %{
              "candidates" => [
                %{
                  "content" => %{
                    "parts" => [
                      %{"text" => "Hello"},
                      %{"unknown_type" => "ignored"},
                      %{"text" => " world"}
                    ]
                  }
                }
              ]
            }
          },
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      # Should only include recognized content types
      assert EventStream.collect_text(stream) == "Hello world"
    end
  end

  # ============================================================================
  # Stream Timeout Tests
  # ============================================================================

  describe "stream timeout" do
    test "uses custom stream_timeout from options" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      opts = %StreamOptions{api_key: default_api_key(), stream_timeout: 60_000}
      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), opts)

      assert {:ok, _result} = EventStream.result(stream, 1000)
    end

    test "uses default stream_timeout when not specified" do
      body =
        sse_body([
          %{"response" => %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]}},
          %{"response" => %{"candidates" => [%{"finishReason" => "STOP"}]}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      {:ok, stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert {:ok, _result} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Claude Thinking Model Detection Tests
  # ============================================================================

  describe "Claude thinking model detection" do
    test "detects claude thinking models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        beta = Plug.Conn.get_req_header(conn, "anthropic-beta")
        send(test_pid, {:beta, beta})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      # Model with claude and thinking in the name
      model = %{antigravity_model() | id: "claude-sonnet-4-thinking"}
      {:ok, _stream} = GoogleGeminiCli.stream(model, default_context(), default_opts())

      assert_receive {:beta, [beta]}, 1000
      assert beta =~ "interleaved-thinking"
    end

    test "non-claude models do not get anthropic-beta header" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        beta = Plug.Conn.get_req_header(conn, "anthropic-beta")
        send(test_pid, {:beta, beta})
        Plug.Conn.send_resp(conn, 400, "test")
      end)

      {:ok, _stream} = GoogleGeminiCli.stream(default_model(), default_context(), default_opts())

      assert_receive {:beta, []}, 1000
    end
  end
end
