defmodule LemonAi.Providers.OpenAICodexResponsesTest do
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

  alias LemonAi.EventStream
  alias LemonAi.Providers.OpenAICodexResponses

  alias LemonAi.Types.{
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
      provider: :openai_codex,
      base_url: "https://chatgpt.com",
      reasoning: Keyword.get(opts, :reasoning, true),
      input: Keyword.get(opts, :input, [:text, :image]),
      cost: %ModelCost{input: 2.0, output: 10.0, cache_read: 0.5, cache_write: 1.0},
      headers: Keyword.get(opts, :headers, %{}),
      reasoning_efforts: Keyword.get(opts, :reasoning_efforts, [])
    }
  end

  test "cache keys and all affinity headers stay bounded and stable across turns" do
    test_pid = self()
    session_id = String.duplicate("long-session:", 12) <> "one"

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:cache_request, Jason.decode!(raw), conn.req_headers})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    opts = %StreamOptions{
      api_key: make_jwt(),
      session_id: session_id,
      headers: %{"Session_Id" => "wrong", "Conversation_Id" => "wrong"}
    }

    keys =
      for turn <- ["first turn", "next turn"] do
        {:ok, stream} =
          OpenAICodexResponses.stream(
            make_model(),
            Context.new(messages: [%UserMessage{content: turn}]),
            opts
          )

        assert_receive {:cache_request, body, headers}, 1000
        assert {:error, _} = EventStream.result(stream, 1000)
        key = body["prompt_cache_key"]
        assert is_binary(key) and byte_size(key) <= 64

        for header <- ["session_id", "conversation_id", "x-client-request-id"] do
          assert Enum.filter(headers, fn {name, _} -> name == header end) == [{header, key}]
        end

        key
      end

    assert [key, key] = keys

    refute key ==
             LemonAi.Providers.OpenAIResponsesShared.normalize_prompt_cache_key(
               session_id <> "two"
             )
  end

  test "missing or empty session IDs do not create per-turn affinity" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:cache_request, Jason.decode!(raw), conn.req_headers})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    for session_id <- [nil, ""] do
      {:ok, stream} =
        OpenAICodexResponses.stream(
          make_model(),
          Context.new(messages: [%UserMessage{content: "Hi"}]),
          %StreamOptions{
            api_key: make_jwt(),
            session_id: session_id,
            headers: %{"Session_Id" => "wrong", "Conversation_Id" => "wrong"}
          }
        )

      assert_receive {:cache_request, body, headers}, 1000
      assert body["prompt_cache_key"] == nil

      for header <- ["session_id", "conversation_id", "x-client-request-id"] do
        refute List.keymember?(headers, header, 0)
      end

      assert {:error, _} = EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Provider Behaviour Tests
  # ============================================================================

  describe "provider behaviour" do
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

    test "uses default instructions when system prompt is missing" do
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
      assert body["instructions"] == "You are a coding assistant."

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
    test "optional tool arguments stay optional and payload observers cannot rewrite requests" do
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
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "extras" => %{"type" => "string"}
          },
          "required" => ["query"]
        }
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{
          api_key: make_jwt(),
          on_payload: fn observed, metadata ->
            send(test_pid, {:observed_payload, observed, metadata})
            Map.put(observed, "tools", [])
          end
        })

      assert_receive {:request_body, body}, 1000
      assert [converted_tool] = body["tools"]
      assert converted_tool["type"] == "function"
      assert converted_tool["name"] == "search"
      assert converted_tool["description"] == "Search the web"
      assert converted_tool["strict"] == false
      assert converted_tool["parameters"]["required"] == ["query"]
      assert_receive {:observed_payload, observed, metadata}
      assert observed["tools"] == body["tools"]
      assert metadata.model == model.id
      assert Enum.sort(Map.keys(metadata)) == [:model, :provider, :session_id]

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

    test "clamps effort to the model's declared reasoning_efforts" do
      cases = [
        {[:low, :medium, :high, :xhigh], :minimal, "low"},
        {[:low, :medium, :high], :xhigh, "high"},
        {[:low, :medium, :high], :high, "high"},
        {[:medium, :high], :xhigh, "high"},
        {[:medium, :high], :low, "medium"},
        {[:medium, :high], :minimal, "medium"}
      ]

      for {efforts, requested, expected} <- cases do
        assert request_effort(make_model(reasoning_efforts: efforts), requested) == expected,
               "#{inspect(efforts)} #{inspect(requested)}"
      end
    end

    test "passes effort through when the model declares no reasoning_efforts" do
      model = make_model(id: "gpt-6.0-turbo")
      assert request_effort(model, :xhigh) == "xhigh"
    end
  end

  defp request_effort(model, reasoning) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    opts = %StreamOptions{api_key: make_jwt(), reasoning: reasoning}

    {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000
    EventStream.result(stream, 1000)
    body["reasoning"]["effort"]
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

      {:ok, stream} =
        OpenAICodexResponses.stream(model, context, %StreamOptions{
          api_key: token,
          headers: %{"Version" => "0.0.0"}
        })

      assert_receive {:headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["authorization"] == "Bearer #{token}"
      assert headers_map["chatgpt-account-id"] == "acc_test"
      assert headers_map["openai-beta"] == "responses=experimental"
      assert headers_map["originator"] == "pi"
      assert headers_map["accept"] == "text/event-stream"
      assert headers_map["content-type"] == "application/json"
      assert headers_map["version"] == "0.159.0"

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
        provider: :openai_codex,
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
        provider: :openai_codex,
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

  test "Codex drops unsupported sampling and output caps while forwarding tier and tool policy" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    {:ok, stream} =
      OpenAICodexResponses.stream(
        make_model(),
        Context.new(messages: [%UserMessage{content: "Hi"}]),
        %StreamOptions{
          api_key: make_jwt(),
          temperature: 0.7,
          max_tokens: 8,
          session_id: "cache-session",
          tool_choice: "none",
          thinking_budgets: %{service_tier: "priority"}
        }
      )

    assert_receive {:request_body, body}, 1000
    refute Map.has_key?(body, "temperature")
    refute Map.has_key?(body, "max_output_tokens")
    assert body["service_tier"] == "priority"
    assert body["tool_choice"] == "none"
    assert body["prompt_cache_key"] == "cache-session"
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
