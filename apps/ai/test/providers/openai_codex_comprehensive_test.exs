defmodule Ai.Providers.OpenAICodexComprehensiveTest do
  @moduledoc """
  Comprehensive tests for the OpenAI Codex Responses API provider.

  Tests cover:
  - Codex-specific endpoint handling
  - Request formatting differences from standard OpenAI
  - JWT authentication
  - Header construction
  - Error handling (via HTTP error codes)
  - Model-specific parameter clamping
  - Request body format validation

  Note: Response streaming is tested via the shared OpenAIResponsesShared module tests,
  since the Codex provider delegates to that module for stream processing.
  The `into: :self` streaming mode used by this provider is not compatible with
  Req.Test plug-based mocking, so we test request building using 400 error responses.
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.OpenAICodexResponses
  alias LemonCore.{Secrets, Store}

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage,
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

  # Helper to create a valid JWT token with account ID
  defp make_jwt(account_id \\ "acc_test123") do
    payload =
      Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}})

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
        if prev_codex,
          do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex),
          else: System.delete_env("OPENAI_CODEX_API_KEY")

        if prev_chatgpt,
          do: System.put_env("CHATGPT_TOKEN", prev_chatgpt),
          else: System.delete_env("CHATGPT_TOKEN")
      end)

      System.put_env("OPENAI_CODEX_API_KEY", "codex_key")
      System.put_env("CHATGPT_TOKEN", "chatgpt_key")

      assert OpenAICodexResponses.get_env_api_key() == "codex_key"
    end

    test "get_env_api_key falls back to CHATGPT_TOKEN" do
      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")

      on_exit(fn ->
        if prev_codex,
          do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex),
          else: System.delete_env("OPENAI_CODEX_API_KEY")

        if prev_chatgpt,
          do: System.put_env("CHATGPT_TOKEN", prev_chatgpt),
          else: System.delete_env("CHATGPT_TOKEN")
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.put_env("CHATGPT_TOKEN", "chatgpt_key")

      assert OpenAICodexResponses.get_env_api_key() == "chatgpt_key"
    end

    test "get_env_api_key returns nil when no keys set" do
      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")
      prev_home = System.get_env("HOME")
      prev_codex_home = System.get_env("CODEX_HOME")

      on_exit(fn ->
        if prev_codex,
          do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex),
          else: System.delete_env("OPENAI_CODEX_API_KEY")

        if prev_chatgpt,
          do: System.put_env("CHATGPT_TOKEN", prev_chatgpt),
          else: System.delete_env("CHATGPT_TOKEN")

        if prev_home,
          do: System.put_env("HOME", prev_home),
          else: System.delete_env("HOME")

        if prev_codex_home,
          do: System.put_env("CODEX_HOME", prev_codex_home),
          else: System.delete_env("CODEX_HOME")
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")

      # Isolate from any real local Codex / Lemon credential stores on the dev machine.
      temp =
        Path.join([System.tmp_dir!(), "lemon-ai-test-home-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(temp)
      System.put_env("HOME", temp)
      System.put_env("CODEX_HOME", Path.join(temp, ".codex"))

      assert OpenAICodexResponses.get_env_api_key() == nil
    end

    test "get_env_api_key reads OAuth secret from store when env vars are missing" do
      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")
      prev_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")

      on_exit(fn ->
        if prev_codex,
          do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex),
          else: System.delete_env("OPENAI_CODEX_API_KEY")

        if prev_chatgpt,
          do: System.put_env("CHATGPT_TOKEN", prev_chatgpt),
          else: System.delete_env("CHATGPT_TOKEN")

        if prev_master_key,
          do: System.put_env("LEMON_SECRETS_MASTER_KEY", prev_master_key),
          else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

        clear_secrets_table()
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")
      clear_secrets_table()

      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

      payload =
        Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acc_test"}})

      token = "x." <> Base.encode64(payload) <> ".y"

      oauth_secret =
        Jason.encode!(%{
          "type" => "onboarding_openai_codex_oauth",
          "access_token" => token,
          "refresh_token" => "rt_test",
          "expires_at_ms" => System.system_time(:millisecond) + 3_600_000
        })

      assert {:ok, _} = Secrets.set("llm_openai_codex_api_key", oauth_secret)

      assert OpenAICodexResponses.get_env_api_key() == token
    end
  end

  defp clear_secrets_table do
    Store.list(Secrets.table())
    |> Enum.each(fn {key, _value} ->
      Store.delete(Secrets.table(), key)
    end)
  end

  # ============================================================================
  # JWT Authentication Tests
  # ============================================================================

  describe "JWT authentication" do
    test "extracts account ID from valid JWT token" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      prev_codex = System.get_env("OPENAI_CODEX_API_KEY")
      prev_chatgpt = System.get_env("CHATGPT_TOKEN")
      prev_home = System.get_env("HOME")
      prev_codex_home = System.get_env("CODEX_HOME")

      on_exit(fn ->
        if prev_codex,
          do: System.put_env("OPENAI_CODEX_API_KEY", prev_codex),
          else: System.delete_env("OPENAI_CODEX_API_KEY")

        if prev_chatgpt,
          do: System.put_env("CHATGPT_TOKEN", prev_chatgpt),
          else: System.delete_env("CHATGPT_TOKEN")

        if prev_home,
          do: System.put_env("HOME", prev_home),
          else: System.delete_env("HOME")

        if prev_codex_home,
          do: System.put_env("CODEX_HOME", prev_codex_home),
          else: System.delete_env("CODEX_HOME")
      end)

      System.delete_env("OPENAI_CODEX_API_KEY")
      System.delete_env("CHATGPT_TOKEN")

      temp =
        Path.join([System.tmp_dir!(), "lemon-ai-test-home-#{System.unique_integer([:positive])}"])

      File.mkdir_p!(temp)
      System.put_env("HOME", temp)
      System.put_env("CODEX_HOME", Path.join(temp, ".codex"))

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: nil})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "required"
    end

    test "errors on empty API key" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: ""})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "required"
    end

    test "errors on invalid JWT format (wrong number of parts)" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: "invalid.token"})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "Invalid JWT"
    end

    test "errors on JWT with missing account ID" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      # JWT without account ID
      payload = Jason.encode!(%{"other_claim" => "value"})
      token = "header." <> Base.encode64(payload) <> ".signature"

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "account ID"
    end

    test "handles JWT with different base64 padding requirements" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
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

    test "handles JWT payload needing 2 chars of padding" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      # Create a payload that will need padding after trim
      payload = Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "ab"}})
      encoded = Base.encode64(payload) |> String.trim_trailing("=")
      token = "h." <> encoded <> ".s"

      {:ok, stream} = OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: token})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["chatgpt-account-id"] == "ab"

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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      context =
        Context.new(
          system_prompt: "You are a helpful assistant",
          messages: [%UserMessage{content: "Hi"}]
        )

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["store"] == false

      EventStream.result(stream, 1000)
    end

    test "sets stream to true" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["stream"] == true

      EventStream.result(stream, 1000)
    end

    test "includes text verbosity setting" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["text"]["verbosity"] == "medium"

      EventStream.result(stream, 1000)
    end

    test "supports high text verbosity" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), thinking_budgets: %{text_verbosity: "high"}}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["text"]["verbosity"] == "high"

      EventStream.result(stream, 1000)
    end

    test "includes reasoning.encrypted_content in include array" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert "reasoning.encrypted_content" in body["include"]

      EventStream.result(stream, 1000)
    end

    test "uses prompt_cache_key from session_id" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), session_id: "session-abc-123"}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["prompt_cache_key"] == "session-abc-123"

      EventStream.result(stream, 1000)
    end

    test "uses nil prompt_cache_key when session_id not provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["prompt_cache_key"] == nil

      EventStream.result(stream, 1000)
    end

    test "sets tool_choice to auto" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["tool_choice"] == "auto"

      EventStream.result(stream, 1000)
    end

    test "enables parallel_tool_calls" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["parallel_tool_calls"] == true

      EventStream.result(stream, 1000)
    end

    test "adds temperature when specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "temperature")

      EventStream.result(stream, 1000)
    end

    test "includes correct model ID in request" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.1-turbo")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "gpt-5.1-turbo"

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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      tool = %Tool{
        name: "search",
        description: "Search the web",
        parameters: %{"type" => "object", "properties" => %{"query" => %{"type" => "string"}}}
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      tools = [
        %Tool{name: "read", description: "Read a file", parameters: %{}},
        %Tool{name: "write", description: "Write a file", parameters: %{}},
        %Tool{name: "execute", description: "Execute code", parameters: %{}}
      ]

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "tools")

      EventStream.result(stream, 1000)
    end

    test "omits tools field when tools is nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "tools")

      EventStream.result(stream, 1000)
    end

    test "preserves tool parameter schema" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      complex_params = %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "content" => %{"type" => "string"},
          "options" => %{
            "type" => "object",
            "properties" => %{
              "encoding" => %{"type" => "string", "enum" => ["utf-8", "ascii"]}
            }
          }
        },
        "required" => ["path", "content"]
      }

      tool = %Tool{name: "write_file", description: "Write to file", parameters: complex_params}
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      [converted_tool] = body["tools"]
      assert converted_tool["parameters"] == complex_params

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
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: make_jwt(),
        reasoning: :low,
        thinking_budgets: %{summary: "detailed"}
      }

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "detailed"

      EventStream.result(stream, 1000)
    end

    test "supports concise summary" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: make_jwt(),
        reasoning: :low,
        thinking_budgets: %{summary: "concise"}
      }

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "concise"

      EventStream.result(stream, 1000)
    end

    test "defaults summary to auto" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "reasoning")

      EventStream.result(stream, 1000)
    end

    test "clamps minimal effort to low for gpt-5.2 models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.2")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :minimal}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "low"

      EventStream.result(stream, 1000)
    end

    test "clamps minimal effort to low for gpt-5.2-preview models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.2-preview")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.1")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :xhigh}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "high"

      EventStream.result(stream, 1000)
    end

    test "does not clamp high effort for gpt-5.1 models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.1")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :high}

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
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.1-codex-mini")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :low}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "medium"

      EventStream.result(stream, 1000)
    end

    test "clamps minimal to medium for gpt-5.1-codex-mini" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-5.1-codex-mini")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :minimal}

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
        Plug.Conn.send_resp(conn, 400, "bad request")
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

    test "does not clamp for unrecognized models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(id: "gpt-6.0-turbo")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), reasoning: :xhigh}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "xhigh"

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
        Plug.Conn.send_resp(conn, 400, "bad request")
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["user-agent"] =~ "pi ("

      EventStream.result(stream, 1000)
    end

    test "includes session_id header when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
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

    test "omits session_id header when not provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      refute Map.has_key?(headers_map, "session_id")

      EventStream.result(stream, 1000)
    end

    test "merges model headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(headers: %{"X-Custom-Header" => "custom-value"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["x-custom-header"] == "custom-value"

      EventStream.result(stream, 1000)
    end

    test "merges user-provided headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
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

    test "user headers override model headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(headers: %{"X-Override" => "model-value"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: make_jwt(), headers: %{"X-Override" => "user-value"}}

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["x-override"] == "user-value"

      EventStream.result(stream, 1000)
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
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hello world"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000

      assert [
               %{
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "Hello world"}]
               }
             ] = body["input"]

      EventStream.result(stream, 1000)
    end

    test "converts user messages with text content blocks" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      context =
        Context.new(messages: [%UserMessage{content: [%TextContent{text: "Test content"}]}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000

      assert [%{"content" => [%{"type" => "input_text", "text" => "Test content"}]}] =
               body["input"]

      EventStream.result(stream, 1000)
    end

    test "includes conversation history" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
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

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hello"},
            assistant_msg,
            %UserMessage{content: "Thanks"}
          ]
        )

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert length(body["input"]) == 3

      EventStream.result(stream, 1000)
    end

    test "converts tool results to function_call_output format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
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

      context =
        Context.new(
          messages: [
            %UserMessage{content: "Search for test"},
            assistant_msg,
            tool_result
          ]
        )

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000

      # Find the function_call_output
      outputs = Enum.filter(body["input"], &(&1["type"] == "function_call_output"))
      assert length(outputs) == 1
      assert hd(outputs)["call_id"] == "call_abc"
      assert hd(outputs)["output"] == "Search results..."

      EventStream.result(stream, 1000)
    end

    test "handles multiple user messages" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

      context =
        Context.new(
          messages: [
            %UserMessage{content: "First message"},
            %UserMessage{content: "Second message"},
            %UserMessage{content: "Third message"}
          ]
        )

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert_receive {:request_body, body}, 1000
      assert length(body["input"]) == 3
      texts = Enum.map(body["input"], fn m -> hd(m["content"])["text"] end)
      assert texts == ["First message", "Second message", "Third message"]

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Error Handling Tests (Non-Retryable)
  # ============================================================================

  describe "error handling" do
    # Note: HTTP 429, 500, 502, 503, 504 are retryable with exponential backoff
    # Testing these would require long timeouts. We test non-retryable errors instead.

    test "handles HTTP 400 bad request" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Bad request"}})
        Plug.Conn.send_resp(conn, 400, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "Bad request"
    end

    test "handles HTTP 404 not found" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Model not found"}})
        Plug.Conn.send_resp(conn, 404, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "Model not found"
    end

    test "handles non-JSON error response" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "Plain text error")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "400"
    end

    test "handles error with code but no message" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"code" => "some_error_code"}})
        Plug.Conn.send_resp(conn, 400, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "400"
    end

    test "handles error with type instead of code" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body =
          Jason.encode!(%{
            "error" => %{"type" => "invalid_request_error", "message" => "Invalid parameters"}
          })

        Plug.Conn.send_resp(conn, 400, error_body)
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "Invalid parameters"
    end

    test "handles malformed JSON error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, "{invalid json")
      end)

      model = make_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{api_key: make_jwt()})

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "400"
    end
  end

  # ============================================================================
  # Comprehensive Request Snapshot Test
  # ============================================================================

  describe "comprehensive request snapshot" do
    test "full request body matches expected format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model()

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
          messages: [%UserMessage{content: "Hi"}],
          tools: [tool]
        )

      opts = %StreamOptions{
        api_key: make_jwt("acc_test"),
        session_id: "sess-1",
        temperature: 0.7,
        reasoning: :low,
        thinking_budgets: %{summary: "concise", text_verbosity: "high"}
      }

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      expected = %{
        "model" => "gpt-5.2",
        "store" => false,
        "stream" => true,
        "instructions" => "System",
        "input" => [
          %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
        ],
        "text" => %{"verbosity" => "high"},
        "include" => ["reasoning.encrypted_content"],
        "prompt_cache_key" => "sess-1",
        "tool_choice" => "auto",
        "parallel_tool_calls" => true,
        "temperature" => 0.7,
        "tools" => [
          %{
            "type" => "function",
            "name" => "lookup",
            "description" => "Lookup data",
            "parameters" => %{
              "type" => "object",
              "properties" => %{"q" => %{"type" => "string"}},
              "required" => ["q"]
            }
          }
        ],
        "reasoning" => %{"effort" => "low", "summary" => "concise"}
      }

      assert body == expected

      EventStream.result(stream, 1000)
    end

    test "full headers match expected format" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = make_model(headers: %{"X-Model-Custom" => "model-val"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      token = make_jwt("acc_header_test")

      opts = %StreamOptions{
        api_key: token,
        session_id: "sess-headers",
        headers: %{"X-User-Custom" => "user-val"}
      }

      {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      # Core headers
      assert headers_map["authorization"] == "Bearer #{token}"
      assert headers_map["chatgpt-account-id"] == "acc_header_test"
      assert headers_map["openai-beta"] == "responses=experimental"
      assert headers_map["originator"] == "pi"
      assert headers_map["accept"] == "text/event-stream"
      assert headers_map["content-type"] == "application/json"
      assert headers_map["session_id"] == "sess-headers"

      # Custom headers
      assert headers_map["x-model-custom"] == "model-val"
      assert headers_map["x-user-custom"] == "user-val"

      # User agent present
      assert headers_map["user-agent"] =~ "pi ("

      EventStream.result(stream, 1000)
    end
  end
end
