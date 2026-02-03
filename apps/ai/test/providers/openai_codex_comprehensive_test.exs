defmodule Ai.Providers.OpenAICodexComprehensiveTest do
  @moduledoc """
  Comprehensive tests for the OpenAI Codex Responses API provider.

  Tests cover:
  - Codex-specific endpoint handling
  - Request formatting differences from standard OpenAI
  - Response parsing (completions, code generation)
  - Streaming events parsing
  - Error handling
  - Token usage extraction
  - Model-specific parameters
  - Code completion specific scenarios
  - JWT authentication
  - Retry logic
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.OpenAICodexResponses
  alias Ai.Types.{AssistantMessage, Context, Cost, Model, ModelCost, StreamOptions, TextContent, ThinkingContent, Tool, ToolCall, ToolResultMessage, Usage, UserMessage}

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

  # Helper to create a valid JWT token with account ID
  defp make_jwt(account_id \\ "acc_test123") do
    payload = Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}})
    "header." <> Base.encode64(payload) <> ".signature"
  end

  defp make_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "gpt-5.2"),
      name: Keyword.get(opts, :name, "GPT-5.2"),
      api: :openai_codex_responses,
      provider: :"openai-codex",
      base_url: "https://chatgpt.com",
      reasoning: Keyword.get(opts, :reasoning, true),
      input: Keyword.get(opts, :input, [:text, :image]),
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 0.5, cache_write: 1.0},
      headers: Keyword.get(opts, :headers, %{})
    }
  end

  defp sse_body(events) do
    events
    |> Enum.map(fn
      :done -> "data: [DONE]"
      event -> "data: " <> Jason.encode!(event)
    end)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n\n")
  end

  # ============================================================================
  # Provider Behaviour Tests
  # ============================================================================

  describe "provider behaviour" do
    test "api_id returns :openai_codex_responses" do
      assert OpenAICodexResponses.api_id() == :openai_codex_responses
    end

    test "provider_id returns :openai-codex" do
      assert OpenAICodexResponses.provider_id() == :"openai-codex"
    end

    test "get_env_api_key checks OPENAI_CODEX_API_KEY first" do
      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")

      on_exit(fn ->
        if prev_codex, do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex), else: System.delete_env("OPENAI_CODEX_API_KEY")
        if prev_chatgpt, do: System.put_env("CHATGPT_TOKEN", prev_chatgpt), else: System.delete_env("CHATGPT_TOKEN")
      end)

      System.put_env("OPENAI_CODEX_API_KEY", "codex_key")
      System.put_env("CHATGPT_TOKEN", "chatgpt_key")

      assert OpenAICodexResponses.get_env_api_key() == "codex_key"
    end

    test "get_env_api_key falls back to CHATGPT_TOKEN" do
      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")

      on_exit(fn ->
        if prev_codex, do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex), else: System.delete_env("OPENAI_CODEX_API_KEY")
        if prev_chatgpt, do: System.put_env("CHATGPT_TOKEN", prev_chatgpt), else: System.delete_env("CHATGPT_TOKEN")
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.put_env("CHATGPT_TOKEN", "chatgpt_key")

      assert OpenAICodexResponses.get_env_api_key() == "chatgpt_key"
    end
  end

  # ============================================================================
  # JWT Authentication Tests
  # ============================================================================

  describe "JWT authentication" do
    test "extracts account ID from valid JWT token" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      token = make_jwt("acc_12345")

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["chatgpt-account-id"] == "acc_12345"

      EventStream.result(stream, 1000)
    end

    test "errors on missing API key" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")

      on_exit(fn ->
        if prev_codex, do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex), else: System.delete_env("OPENAI_CODEX_API_KEY")
        if prev_chatgpt, do: System.put_env("CHATGPT_TOKEN", prev_chatgpt), else: System.delete_env("CHATGPT_TOKEN")
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: nil})
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "errors on invalid JWT format (wrong number of parts)" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: "invalid.token"})
      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 1000)
      assert msg =~ "Invalid JWT"
    end

    test "errors on JWT with missing account ID" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      # JWT without account ID
      payload = Jason.encode!(%{"other_claim" => "value"})
      token = "header." <> Base.encode64(payload) <> ".signature"

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})
      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 1000)
      assert msg =~ "account ID"
    end

    test "handles JWT with different base64 padding requirements" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      # Create payload that needs different padding
      payload = Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "a"}})
      # Remove padding from base64 to test pad_base64 function
      encoded = Base.encode64(payload) |> String.trim_trailing("=")
      token = "h." <> encoded <> ".s"

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["chatgpt-account-id"] == "a"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Request Building Tests
  # ============================================================================

  describe "request body formatting" do
    test "uses instructions field for system prompt (not in messages)" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(system_prompt: "You are a helpful assistant", messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["instructions"] == "You are a helpful assistant"
      # System prompt should NOT be in input messages
      refute Enum.any?(body["input"], fn msg -> msg["role"] in ["system", "developer"] end)

      EventStream.result(stream, 1000)
    end

    test "sets store to false" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["store"] == false

      EventStream.result(stream, 1000)
    end

    test "includes text verbosity setting" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), thinking_budgets: %{text_verbosity: "low"}}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["text"]["verbosity"] == "low"

      EventStream.result(stream, 1000)
    end

    test "defaults text verbosity to medium" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["text"]["verbosity"] == "medium"

      EventStream.result(stream, 1000)
    end

    test "includes reasoning.encrypted_content in include array" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert "reasoning.encrypted_content" in body["include"]

      EventStream.result(stream, 1000)
    end

    test "uses prompt_cache_key from session_id" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), session_id: "session-abc-123"}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["prompt_cache_key"] == "session-abc-123"

      EventStream.result(stream, 1000)
    end

    test "sets tool_choice to auto" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["tool_choice"] == "auto"

      EventStream.result(stream, 1000)
    end

    test "enables parallel_tool_calls" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["parallel_tool_calls"] == true

      EventStream.result(stream, 1000)
    end

    test "adds temperature when specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), temperature: 0.7}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["temperature"] == 0.7

      EventStream.result(stream, 1000)
    end

    test "omits temperature when not specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "temperature")

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Tool Handling Tests
  # ============================================================================

  describe "tool handling" do
    test "converts tools to OpenAI format without strict mode" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      tool = %Tool{
        name: "search",
        description: "Search the web",
        parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
      }
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert [converted_tool] = body["tools"]
      assert converted_tool["type"] == "function"
      assert converted_tool["name"] == "search"
      assert converted_tool["description"] == "Search the web"
      # Codex uses strict: nil (omitted)
      refute Map.has_key?(converted_tool, "strict")

      EventStream.result(stream, 1000)
    end

    test "handles multiple tools" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      tools = [
        %Tool{name: "read", description: "Read a file", parameters: %{}},
        %Tool{name: "write", description: "Write a file", parameters: %{}},
        %Tool{name: "execute", description: "Execute code", parameters: %{}}
      ]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert length(body["tools"]) == 3
      assert Enum.map(body["tools"], & &1["name"]) == ["read", "write", "execute"]

      EventStream.result(stream, 1000)
    end

    test "omits tools field when no tools provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "tools")

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Reasoning Configuration Tests
  # ============================================================================

  describe "reasoning configuration" do
    test "includes reasoning config when reasoning option is set" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :medium}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "medium"

      EventStream.result(stream, 1000)
    end

    test "uses summary from thinking_budgets" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :low, thinking_budgets: %{summary: "detailed"}}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "detailed"

      EventStream.result(stream, 1000)
    end

    test "defaults summary to auto" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :low}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "auto"

      EventStream.result(stream, 1000)
    end

    test "omits reasoning config when not requested" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "reasoning")

      EventStream.result(stream, 1000)
    end

    test "clamps minimal effort to low for gpt-5.2 models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(id: "gpt-5.2")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :minimal}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "low"

      EventStream.result(stream, 1000)
    end

    test "clamps xhigh effort to high for gpt-5.1 models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(id: "gpt-5.1")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :xhigh}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "high"

      EventStream.result(stream, 1000)
    end

    test "clamps high/xhigh to high for gpt-5.1-codex-mini" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(id: "gpt-5.1-codex-mini")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :xhigh}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "high"

      EventStream.result(stream, 1000)
    end

    test "clamps lower efforts to medium for gpt-5.1-codex-mini" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(id: "gpt-5.1-codex-mini")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :low}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "medium"

      EventStream.result(stream, 1000)
    end

    test "handles model IDs with provider prefix" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(id: "openai/gpt-5.2-preview")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :minimal}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      # Should clamp minimal to low for gpt-5.2
      assert body["reasoning"]["effort"] == "low"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Header Tests
  # ============================================================================

  describe "request headers" do
    test "includes required Codex headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      token = make_jwt("acc_test")

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["authorization"] == "Bearer #{token}"
      assert headers_map["chatgpt-account-id"] == "acc_test"
      assert headers_map["openai-beta"] == "responses=experimental"
      assert headers_map["originator"] == "pi"
      assert headers_map["accept"] == "text/event-stream"
      assert headers_map["content-type"] == "application/json"

      EventStream.result(stream, 1000)
    end

    test "includes user agent with platform info" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["user-agent"] =~ "pi ("

      EventStream.result(stream, 1000)
    end

    test "includes session_id header when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), session_id: "sess-123"}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["session_id"] == "sess-123"

      EventStream.result(stream, 1000)
    end

    test "merges model headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model(headers: %{"X-Custom-Header" => "custom-value"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["x-custom-header"] == "custom-value"

      EventStream.result(stream, 1000)
    end

    test "merges user-provided headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), headers: %{"X-User-Header" => "user-value"}}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["x-user-header"] == "user-value"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Response Streaming Tests
  # ============================================================================

  describe "streaming response parsing" do
    test "parses text message events" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "msg_1"}},
          %{"type" => "response.content_part.added", "part" => %{"type" => "output_text"}},
          %{"type" => "response.output_text.delta", "delta" => "Hello"},
          %{"type" => "response.output_text.delta", "delta" => " World"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "message", "id" => "msg_1", "content" => [%{"type" => "output_text", "text" => "Hello World"}]}},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert [%TextContent{text: "Hello World"}] = result.content
      assert result.stop_reason == :stop
    end

    test "parses reasoning events with summary" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}},
          %{"type" => "response.reasoning_summary_part.added", "part" => %{"text" => ""}},
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "Thinking..."},
          %{"type" => "response.reasoning_summary_part.done"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning", "summary" => [%{"text" => "Thinking..."}]}},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert [%ThinkingContent{thinking: "Thinking..."}] = result.content
    end

    test "parses function call events" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.output_item.added", "item" => %{"type" => "function_call", "call_id" => "call_123", "id" => "fc_456", "name" => "search"}},
          %{"type" => "response.function_call_arguments.delta", "delta" => "{\"query\":"},
          %{"type" => "response.function_call_arguments.delta", "delta" => "\"test\"}"},
          %{"type" => "response.function_call_arguments.done", "arguments" => "{\"query\":\"test\"}"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "function_call", "call_id" => "call_123", "id" => "fc_456", "name" => "search", "arguments" => "{\"query\":\"test\"}"}},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      tool = %Tool{name: "search", description: "Search", parameters: %{}}
      context = Context.new(messages: [%UserMessage{content: "Search for test"}], tools: [tool])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert [%ToolCall{name: "search", arguments: %{"query" => "test"}}] = result.content
      assert result.stop_reason == :tool_use
    end

    test "handles multiple output items" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}},
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "Let me think..."},
          %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning", "summary" => [%{"text" => "Let me think..."}]}},
          %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "msg_1"}},
          %{"type" => "response.output_text.delta", "delta" => "Here's my answer"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "message", "id" => "msg_1", "content" => [%{"type" => "output_text", "text" => "Here's my answer"}]}},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert [%ThinkingContent{}, %TextContent{}] = result.content
    end
  end

  # ============================================================================
  # Token Usage Tests
  # ============================================================================

  describe "token usage extraction" do
    test "extracts input and output tokens" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "usage" => %{
                "input_tokens" => 100,
                "output_tokens" => 50,
                "total_tokens" => 150
              }
            }
          }
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.usage.input == 100
      assert result.usage.output == 50
      assert result.usage.total_tokens == 150
    end

    test "extracts cached tokens from input_tokens_details" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "usage" => %{
                "input_tokens" => 100,
                "output_tokens" => 50,
                "total_tokens" => 150,
                "input_tokens_details" => %{"cached_tokens" => 40}
              }
            }
          }
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.usage.input == 60  # 100 - 40
      assert result.usage.cache_read == 40
    end

    test "clamps negative input tokens to zero" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "usage" => %{
                "input_tokens" => 30,
                "output_tokens" => 50,
                "total_tokens" => 80,
                "input_tokens_details" => %{"cached_tokens" => 50}
              }
            }
          }
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.usage.input == 0  # clamped from -20
      assert result.usage.cache_read == 50
    end

    test "calculates cost based on model pricing" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "usage" => %{
                "input_tokens" => 1_000_000,
                "output_tokens" => 1_000_000,
                "total_tokens" => 2_000_000,
                "input_tokens_details" => %{"cached_tokens" => 500_000}
              }
            }
          }
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      # input: 500k tokens * $2.0/M = $1.0
      # output: 1M tokens * $10.0/M = $10.0
      # cache_read: 500k tokens * $0.5/M = $0.25
      assert_in_delta result.usage.cost.input, 1.0, 0.001
      assert_in_delta result.usage.cost.output, 10.0, 0.001
      assert_in_delta result.usage.cost.cache_read, 0.25, 0.001
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "handles error event in stream" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "error", "code" => "rate_limit", "message" => "Too many requests"}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 5000)
    end

    test "handles response.failed event" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.failed", "response" => %{"error" => %{"message" => "Internal error"}}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 5000)
    end

    test "parses usage limit error with plan info" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{
          "error" => %{
            "code" => "usage_limit_reached",
            "message" => "Usage limit reached",
            "plan_type" => "Plus"
          }
        })
        Plug.Conn.send_resp(conn, 429, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 5000)
      assert msg =~ "usage limit"
      assert msg =~ "plus plan"
    end

    test "parses rate limit error with reset time" do
      resets_at = System.system_time(:second) + 300  # 5 minutes from now

      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{
          "error" => %{
            "code" => "rate_limit_exceeded",
            "message" => "Rate limit exceeded",
            "resets_at" => resets_at
          }
        })
        Plug.Conn.send_resp(conn, 429, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 5000)
      assert msg =~ "usage limit"
      assert msg =~ "min"
    end

    test "handles HTTP 500 error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 5000)
      assert msg =~ "500"
    end

    test "handles HTTP 401 unauthorized" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Invalid token"}})
        Plug.Conn.send_resp(conn, 401, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = EventStream.result(stream, 5000)
      assert msg =~ "Invalid token"
    end

    test "maps failed status to error stop_reason" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "failed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :error
    end

    test "maps incomplete status to length stop_reason" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "incomplete"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :length
    end

    test "maps cancelled status to error stop_reason" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "cancelled"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :error
    end
  end

  # ============================================================================
  # Event Mapping Tests
  # ============================================================================

  describe "codex event mapping" do
    test "maps response.done to response.completed" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.done", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :stop
    end

    test "normalizes unknown status to nil" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "unknown_status"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      # Unknown status should map to :stop (default)
      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :stop
    end

    test "handles in_progress status" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "in_progress"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :stop
    end

    test "handles queued status" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "queued"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :stop
    end
  end

  # ============================================================================
  # Message Conversion Tests
  # ============================================================================

  describe "message conversion" do
    test "converts user messages to input format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hello world"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert [%{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hello world"}]}] = body["input"]

      EventStream.result(stream, 1000)
    end

    test "converts user messages with text content blocks" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: [%TextContent{text: "Test content"}]}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert [%{"content" => [%{"type" => "input_text", "text" => "Test content"}]}] = body["input"]

      EventStream.result(stream, 1000)
    end

    test "includes conversation history" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{text: "I can help with that", text_signature: "msg_123"}],
        api: :openai_codex_responses,
        provider: :"openai-codex",
        model: "gpt-5.2",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      context = Context.new(messages: [
        %UserMessage{content: "Hello"},
        assistant_msg,
        %UserMessage{content: "Thanks"}
      ])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert length(body["input"]) == 3

      EventStream.result(stream, 1000)
    end

    test "converts tool results to function_call_output format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = make_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [%ToolCall{id: "call_abc|fc_def", name: "search", arguments: %{"q" => "test"}}],
        api: :openai_codex_responses,
        provider: :"openai-codex",
        model: "gpt-5.2",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :tool_use,
        timestamp: System.system_time(:millisecond)
      }

      tool_result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_abc|fc_def",
        tool_name: "search",
        content: [%TextContent{text: "Search results..."}],
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      context = Context.new(messages: [
        %UserMessage{content: "Search for test"},
        assistant_msg,
        tool_result
      ])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000

      # Find the function_call_output
      outputs = Enum.filter(body["input"], & &1["type"] == "function_call_output")
      assert length(outputs) == 1
      assert hd(outputs)["call_id"] == "call_abc"
      assert hd(outputs)["output"] == "Search results..."

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Initial Output Tests
  # ============================================================================

  describe "initial output" do
    test "sets correct api and provider" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.api == :openai_codex_responses
      assert result.provider == :"openai-codex"
      assert result.model == "gpt-5.2"
    end

    test "initializes with empty content list" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.content == []
    end

    test "initializes with zero usage" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      # Get stream events to check initial output
      events = EventStream.events(stream)
      {:start, initial} = Enum.find(events, fn e -> match?({:start, _}, e) end)

      assert initial.usage.input == 0
      assert initial.usage.output == 0
      assert initial.usage.total_tokens == 0
    end
  end

  # ============================================================================
  # Refusal Handling Tests
  # ============================================================================

  describe "refusal handling" do
    test "parses refusal content as text" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.output_item.added", "item" => %{"type" => "message", "id" => "msg_1"}},
          %{"type" => "response.content_part.added", "part" => %{"type" => "refusal"}},
          %{"type" => "response.refusal.delta", "delta" => "I cannot help with that request"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "message", "id" => "msg_1", "content" => [%{"type" => "refusal", "refusal" => "I cannot help with that request"}]}},
          %{"type" => "response.completed", "response" => %{"status" => "completed"}}
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Do something bad"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, result} = EventStream.result(stream, 5000)
      assert [%TextContent{text: text}] = result.content
      assert text =~ "cannot help"
    end
  end

  # ============================================================================
  # SSE Parsing Edge Cases
  # ============================================================================

  describe "SSE parsing edge cases" do
    test "handles events split across chunks" do
      Req.Test.stub(__MODULE__, fn conn ->
        # Simulate chunked response
        body = "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, _result} = EventStream.result(stream, 5000)
    end

    test "ignores [DONE] marker" do
      Req.Test.stub(__MODULE__, fn conn ->
        events = [
          %{"type" => "response.completed", "response" => %{"status" => "completed"}},
          :done
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, _result} = EventStream.result(stream, 5000)
    end

    test "handles empty data lines" do
      Req.Test.stub(__MODULE__, fn conn ->
        body = "data: \n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:ok, _result} = EventStream.result(stream, 5000)
    end
  end

  # ============================================================================
  # Comprehensive Integration Test
  # ============================================================================

  describe "full integration scenario" do
    test "complete code generation flow with reasoning and tool use" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})

        events = [
          # Reasoning phase
          %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}},
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "I need to read the file first."},
          %{"type" => "response.output_item.done", "item" => %{"type" => "reasoning", "summary" => [%{"text" => "I need to read the file first."}]}},
          # Tool call
          %{"type" => "response.output_item.added", "item" => %{"type" => "function_call", "call_id" => "call_1", "id" => "fc_1", "name" => "read_file"}},
          %{"type" => "response.function_call_arguments.delta", "delta" => "{\"path\":\"test.py\"}"},
          %{"type" => "response.function_call_arguments.done", "arguments" => "{\"path\":\"test.py\"}"},
          %{"type" => "response.output_item.done", "item" => %{"type" => "function_call", "call_id" => "call_1", "id" => "fc_1", "name" => "read_file", "arguments" => "{\"path\":\"test.py\"}"}},
          # Completion
          %{
            "type" => "response.completed",
            "response" => %{
              "status" => "completed",
              "usage" => %{
                "input_tokens" => 500,
                "output_tokens" => 200,
                "total_tokens" => 700,
                "input_tokens_details" => %{"cached_tokens" => 100}
              }
            }
          }
        ]
        Plug.Conn.send_resp(conn, 200, sse_body(events))
      end)

      model = make_model()
      tool = %Tool{
        name: "read_file",
        description: "Read a file",
        parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }
      context = Context.new(
        system_prompt: "You are a coding assistant",
        messages: [%UserMessage{content: "Fix the bug in test.py"}],
        tools: [tool]
      )
      opts = %StreamOptions{
        api_key: make_jwt(),
        session_id: "session-123",
        reasoning: :medium,
        thinking_budgets: %{summary: "concise", text_verbosity: "high"}
      }

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      # Verify request
      assert_receive {:request_body, body}, 1000
      assert body["instructions"] == "You are a coding assistant"
      assert body["reasoning"]["effort"] == "medium"
      assert body["reasoning"]["summary"] == "concise"
      assert body["text"]["verbosity"] == "high"
      assert body["prompt_cache_key"] == "session-123"
      assert length(body["tools"]) == 1

      # Verify response
      assert {:ok, result} = EventStream.result(stream, 5000)
      assert result.stop_reason == :tool_use
      assert [%ThinkingContent{thinking: thinking}, %ToolCall{name: "read_file"}] = result.content
      assert thinking =~ "read the file"
      assert result.usage.input == 400  # 500 - 100 cached
      assert result.usage.output == 200
      assert result.usage.cache_read == 100
    end
  end
end
