defmodule LemonAi.Providers.GoogleTest do
  use ExUnit.Case, async: false

  alias LemonAi.Providers.Google
  alias LemonAi.EventStream

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Model,
    ModelCost,
    StreamOptions,
    Tool,
    ToolCall,
    UserMessage
  }

  # ============================================================================
  # Helpers
  # ============================================================================

  defp build_model(overrides \\ %{}) do
    defaults = %{
      id: "gemini-2.5-flash",
      name: "Gemini 2.5 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.15, output: 0.6, cache_read: 0.0375, cache_write: 0.0},
      context_window: 1_048_576,
      max_tokens: 65_536,
      headers: %{},
      compat: nil
    }

    struct(Model, Map.merge(defaults, overrides))
  end

  defp build_context(overrides \\ %{}) do
    defaults = %{
      system_prompt: nil,
      messages: [%UserMessage{role: :user, content: "Hello"}],
      tools: []
    }

    struct(Context, Map.merge(defaults, overrides))
  end

  defp build_opts(overrides \\ %{}) do
    defaults = %{
      temperature: nil,
      max_tokens: nil,
      api_key: "test-google-api-key",
      session_id: nil,
      headers: %{},
      reasoning: nil,
      thinking_budgets: %{},
      stream_timeout: 5_000,
      tool_choice: nil,
      project: nil,
      location: nil,
      access_token: nil
    }

    struct(StreamOptions, Map.merge(defaults, overrides))
  end

  defp sse_data(json_map) do
    "data: #{Jason.encode!(json_map)}\n\n"
  end

  defp text_chunk(text, opts) do
    chunk = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [%{"text" => text}],
            "role" => "model"
          }
        }
      ]
    }

    chunk =
      if finish_reason = opts[:finish_reason] do
        put_in(chunk, ["candidates", Access.at(0), "finishReason"], finish_reason)
      else
        chunk
      end

    if usage = opts[:usage] do
      Map.put(chunk, "usageMetadata", usage)
    else
      chunk
    end
  end

  defp tool_call_chunk(name, args) do
    %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [%{"functionCall" => %{"name" => name, "args" => args}}],
            "role" => "model"
          }
        }
      ]
    }
  end

  defp usage_metadata(prompt_tokens, candidates_tokens, total_tokens) do
    %{
      "promptTokenCount" => prompt_tokens,
      "candidatesTokenCount" => candidates_tokens,
      "totalTokenCount" => total_tokens
    }
  end

  # ============================================================================
  # Provider Callbacks
  # ============================================================================

  describe "provider_id/0" do
    test "returns :google" do
      assert Google.provider_id() == :google
    end
  end

  describe "api_id/0" do
    test "returns :google_generative_ai" do
      assert Google.api_id() == :google_generative_ai
    end
  end

  # ============================================================================
  # Registration
  # ============================================================================

  describe "child_spec/1" do
    test "returns a proper child spec" do
      spec = Google.child_spec([])

      assert spec.id == Google
      assert spec.type == :worker
      assert spec.restart == :transient
      assert {Google, :register, [[]]} = spec.start
    end
  end

  describe "register/1" do
    test "registers provider with the registry" do
      assert Google.register() == :ignore
      assert {:ok, Google} = LemonAi.ProviderRegistry.get(:google_generative_ai)
    end
  end

  # ============================================================================
  # Streaming - Request Building
  # ============================================================================

  describe "stream/3 request building" do
    setup do
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)

      :ok
    end

    test "constructs correct URL with default base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path ==
                 "/v1beta/models/gemini-2.5-flash:streamGenerateContent"

        assert conn.query_string == "alt=sse"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "constructs correct URL with custom base URL" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path ==
                 "/v1/models/gemini-2.5-flash:streamGenerateContent"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{base_url: "https://custom.api.example.com/v1"})
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "uses resolved provider_options api_key and base_url" do
      test_pid = self()
      prev_google = System.get_env("GOOGLE_GENERATIVE_AI_API_KEY")
      prev_google_api = System.get_env("GOOGLE_API_KEY")
      prev_gemini = System.get_env("GEMINI_API_KEY")

      System.delete_env("GOOGLE_GENERATIVE_AI_API_KEY")
      System.delete_env("GOOGLE_API_KEY")
      System.delete_env("GEMINI_API_KEY")

      on_exit(fn ->
        if is_binary(prev_google),
          do: System.put_env("GOOGLE_GENERATIVE_AI_API_KEY", prev_google),
          else: System.delete_env("GOOGLE_GENERATIVE_AI_API_KEY")

        if is_binary(prev_google_api),
          do: System.put_env("GOOGLE_API_KEY", prev_google_api),
          else: System.delete_env("GOOGLE_API_KEY")

        if is_binary(prev_gemini),
          do: System.put_env("GEMINI_API_KEY", prev_gemini),
          else: System.delete_env("GEMINI_API_KEY")
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request, conn.host, conn.request_path, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("OK", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{base_url: "https://fallback.google.test"})
      context = build_context()

      opts =
        build_opts(%{
          api_key: nil,
          provider_options: %{
            google: %{
              api_key: "google-resolved-key",
              base_url: "https://override.google.test/v1beta"
            }
          }
        })

      {:ok, stream} = Google.stream(model, context, opts)

      assert_receive {:request, "override.google.test",
                      "/v1beta/models/gemini-2.5-flash:streamGenerateContent", headers},
                     5_000

      assert Map.new(headers)["x-goog-api-key"] == "google-resolved-key"
      assert {:ok, _} = EventStream.result(stream, 5_000)
    end

    test "includes API key in headers" do
      Req.Test.stub(__MODULE__, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "x-goog-api-key")
        assert api_key == "test-google-api-key"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "includes content-type header" do
      Req.Test.stub(__MODULE__, fn conn ->
        [content_type] = Plug.Conn.get_req_header(conn, "content-type")
        assert content_type =~ "application/json"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "includes model-level custom headers" do
      Req.Test.stub(__MODULE__, fn conn ->
        [custom_val] = Plug.Conn.get_req_header(conn, "x-custom-model")
        assert custom_val == "model-value"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{headers: %{"x-custom-model" => "model-value"}})
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "includes opts-level custom headers" do
      Req.Test.stub(__MODULE__, fn conn ->
        [custom_val] = Plug.Conn.get_req_header(conn, "x-custom-opt")
        assert custom_val == "opt-value"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts(%{headers: %{"x-custom-opt" => "opt-value"}})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body includes system prompt" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["systemInstruction"] == %{
                 "parts" => [%{"text" => "You are a helpful assistant"}]
               }

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context(%{system_prompt: "You are a helpful assistant"})
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body omits system prompt when nil" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "systemInstruction")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context(%{system_prompt: nil})
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body includes generation config with temperature and max_tokens" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["generationConfig"]["temperature"] == 0.7
        assert decoded["generationConfig"]["maxOutputTokens"] == 4096

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts(%{temperature: 0.7, max_tokens: 4096})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body omits generation config when no options set" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute Map.has_key?(decoded, "generationConfig")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body includes tools when provided" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        [tool_group] = decoded["tools"]
        [func_decl] = tool_group["functionDeclarations"]
        assert func_decl["name"] == "get_weather"
        assert func_decl["description"] == "Gets weather for a city"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      tool = %Tool{
        name: "get_weather",
        description: "Gets weather for a city",
        parameters: %{"type" => "object", "properties" => %{"city" => %{"type" => "string"}}}
      }

      model = build_model()
      context = build_context(%{tools: [tool]})
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body includes thinking config for reasoning models" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["generationConfig"]["thinkingConfig"]["includeThoughts"] == true

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{reasoning: true})
      context = build_context()
      opts = build_opts(%{reasoning: :high, thinking_budgets: %{}})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "request body includes thinking budget when specified" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        thinking_config = decoded["generationConfig"]["thinkingConfig"]
        assert thinking_config["includeThoughts"] == true
        assert thinking_config["thinkingBudget"] == 8192

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("hi", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{reasoning: true})
      context = build_context()
      opts = build_opts(%{reasoning: :medium, thinking_budgets: %{budget_tokens: 8192}})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end
  end

  # ============================================================================
  # Streaming - Response Parsing
  # ============================================================================

  describe "stream/3 response parsing" do
    setup do
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)

      :ok
    end

    test "returns {:ok, stream} immediately" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      assert {:ok, stream} = Google.stream(model, context, opts)
      assert is_pid(stream)
      EventStream.result(stream, 5_000)
    end

    test "initializes output with correct metadata" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(
          200,
          sse_data(text_chunk("hello", %{finish_reason: "STOP"}))
        )
      end)

      model = build_model(%{id: "gemini-2.5-pro"})
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)

      case EventStream.result(stream, 5_000) do
        {:ok, %AssistantMessage{} = msg} ->
          assert msg.role == :assistant
          assert msg.api == :google_generative_ai
          assert msg.provider == :google
          assert msg.model == "gemini-2.5-pro"

        {:error, %AssistantMessage{} = msg} ->
          # Even in error, metadata should be set
          assert msg.api == :google_generative_ai
      end
    end

    test "handles HTTP error responses" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(%{"error" => %{"message" => "Invalid API key"}})
        )
      end)

      model = build_model()
      context = build_context()
      opts = build_opts(%{api_key: "bad-key"})

      {:ok, stream} = Google.stream(model, context, opts)
      result = EventStream.result(stream, 5_000)

      assert {:error, %AssistantMessage{} = msg} = result
      assert msg.stop_reason == :error
      assert is_binary(msg.error_message)
      assert msg.error_message =~ "400"
    end

    test "handles 500 server error" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => %{"message" => "Server error"}}))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      result = EventStream.result(stream, 5_000)

      assert {:error, %AssistantMessage{} = msg} = result
      assert msg.stop_reason == :error
      assert msg.error_message =~ "500"
    end

    test "sets stop_reason to :tool_use when tool calls present" do
      Req.Test.stub(__MODULE__, fn conn ->
        body =
          sse_data(
            tool_call_chunk("get_weather", %{"city" => "Paris"})
            |> put_in(["candidates", Access.at(0), "finishReason"], "STOP")
            |> Map.put(
              "usageMetadata",
              usage_metadata(10, 20, 30)
            )
          )

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      result = EventStream.result(stream, 5_000)

      assert {:ok, %AssistantMessage{} = msg} = result
      assert msg.stop_reason == :tool_use

      tool_calls = Enum.filter(msg.content, &match?(%ToolCall{}, &1))
      assert length(tool_calls) == 1
      [tc] = tool_calls
      assert tc.name == "get_weather"
      assert tc.arguments == %{"city" => "Paris"}
    end

    test "parses usage metadata and calculates cost" do
      Req.Test.stub(__MODULE__, fn conn ->
        body =
          sse_data(
            text_chunk("response text", %{
              finish_reason: "STOP",
              usage: usage_metadata(100, 50, 150)
            })
          )

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      model =
        build_model(%{
          cost: %ModelCost{input: 1.0, output: 2.0, cache_read: 0.5, cache_write: 0.0}
        })

      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      result = EventStream.result(stream, 5_000)

      assert {:ok, %AssistantMessage{} = msg} = result
      assert msg.usage.input == 100
      assert msg.usage.output == 50
      assert msg.usage.total_tokens == 150
      # Cost: 100 * 1.0 / 1M = 0.0001, 50 * 2.0 / 1M = 0.0001
      assert msg.usage.cost.input == 100 * 1.0 / 1_000_000
      assert msg.usage.cost.output == 50 * 2.0 / 1_000_000
    end

    test "maps MAX_TOKENS finish reason to :length" do
      Req.Test.stub(__MODULE__, fn conn ->
        body = sse_data(text_chunk("truncated", %{finish_reason: "MAX_TOKENS"}))

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      model = build_model()
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      result = EventStream.result(stream, 5_000)

      assert {:ok, %AssistantMessage{} = msg} = result
      assert msg.stop_reason == :length
    end
  end

  # ============================================================================
  # Streaming - Model-Specific Behavior
  # ============================================================================

  describe "stream/3 model-specific behavior" do
    setup do
      previous_defaults = Req.default_options()
      Req.default_options(plug: {Req.Test, __MODULE__})
      Req.Test.set_req_test_to_shared(%{})

      on_exit(fn ->
        Req.default_options(previous_defaults)
        Req.Test.set_req_test_to_private(%{})
      end)

      :ok
    end

    test "strips trailing slash from custom base_url" do
      Req.Test.stub(__MODULE__, fn conn ->
        # The path should not have double slashes
        refute String.contains?(conn.request_path, "//")

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{base_url: "https://example.com/api/"})
      context = build_context()
      opts = build_opts()

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "uses opts api_key over env vars" do
      Req.Test.stub(__MODULE__, fn conn ->
        [api_key] = Plug.Conn.get_req_header(conn, "x-goog-api-key")
        assert api_key == "opts-key-override"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      model = build_model()
      context = build_context()
      opts = build_opts(%{api_key: "opts-key-override"})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "includes tool config when tool_choice is set" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["toolConfig"]["functionCallingConfig"]["mode"] == "ANY"

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      tool = %Tool{
        name: "search",
        description: "Search the web",
        parameters: %{"type" => "object", "properties" => %{}}
      }

      model = build_model()
      context = build_context(%{tools: [tool]})
      opts = build_opts(%{tool_choice: :any})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "does not include thinking config for non-reasoning models" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute get_in(decoded, ["generationConfig", "thinkingConfig"])

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{reasoning: false})
      context = build_context()
      opts = build_opts(%{reasoning: :high, thinking_budgets: %{}})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end

    test "does not include thinking config when reasoning is nil" do
      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        refute get_in(decoded, ["generationConfig", "thinkingConfig"])

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, sse_data(text_chunk("ok", %{finish_reason: "STOP"})))
      end)

      model = build_model(%{reasoning: true})
      context = build_context()
      opts = build_opts(%{reasoning: nil, thinking_budgets: %{}})

      {:ok, stream} = Google.stream(model, context, opts)
      EventStream.result(stream, 5_000)
    end
  end

  # ============================================================================
  # SSE framing across transport frames (#637)
  # ============================================================================

  describe "events split across transport frames" do
    setup do
      previous_defaults = Req.default_options()
      on_exit(fn -> Req.default_options(previous_defaults) end)
      :ok
    end

    @split_event %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [
              %{"text" => "Héllo"},
              %{
                "functionCall" => %{"id" => "call-1", "name" => "lookup", "args" => %{"q" => "ü"}}
              }
            ]
          },
          "finishReason" => "STOP"
        }
      ],
      "usageMetadata" => %{
        "promptTokenCount" => 12,
        "candidatesTokenCount" => 5,
        "cachedContentTokenCount" => 2,
        "totalTokenCount" => 17
      }
    }

    for provider <- [:google, :google_vertex, :google_gemini_cli] do
      test "#{provider} decodes one event split at every byte offset like the unsplit event" do
        provider = unquote(provider)
        frame = split_frame(provider, @split_event)
        {expected, expected_events} = run_frames(provider, [frame])

        assert %AssistantMessage{stop_reason: :tool_use} = expected

        assert [%{text: "Héllo"}, %ToolCall{id: "call-1", arguments: %{"q" => "ü"}}] =
                 expected.content

        assert expected.usage.total_tokens == 17

        for offset <- 1..(byte_size(frame) - 1) do
          <<first::binary-size(^offset), rest::binary>> = frame
          {message, events} = run_frames(provider, [first, rest])

          assert {message.content, message.usage, message.stop_reason} ==
                   {expected.content, expected.usage, expected.stop_reason},
                 "split at byte #{offset}"

          assert events == expected_events, "split at byte #{offset}"
        end
      end

      test "#{provider} keeps a finishReason and usageMetadata block split across frames" do
        provider = unquote(provider)

        text =
          split_frame(provider, %{
            "candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]
          })

        terminal =
          split_frame(provider, %{
            "candidates" => [%{"finishReason" => "MAX_TOKENS"}],
            "usageMetadata" => %{
              "promptTokenCount" => 9,
              "candidatesTokenCount" => 4,
              "totalTokenCount" => 13
            }
          })

        {position, _} = :binary.match(terminal, "TokenCount")
        <<head::binary-size(^position), tail::binary>> = terminal
        {message, _events} = run_frames(provider, [text <> head, tail])

        assert message.stop_reason == :length
        assert LemonAi.get_text(message) == "Hi"
        assert %{input: 9, output: 4, total_tokens: 13} = message.usage
      end
    end

    defp split_frame(:google_gemini_cli, event),
      do: "data: " <> Jason.encode!(%{"response" => event}) <> "\r\n\r\n"

    defp split_frame(_provider, event), do: "data: " <> Jason.encode!(event) <> "\r\n\r\n"

    # Delivers each frame as its own Req async body message.
    defp run_frames(provider, frames) do
      Req.default_options(
        adapter: fn request ->
          ref = make_ref()
          Enum.each(frames, &send(self(), {ref, {:data, &1}}))
          send(self(), {ref, :done})

          async = %Req.Response.Async{
            pid: self(),
            ref: ref,
            stream_fun: fn
              ^ref, {^ref, {:data, data}} -> {:ok, [data: data]}
              ^ref, {^ref, :done} -> {:ok, [:done]}
              _ref, _message -> :unknown
            end,
            cancel_fun: fn _ref -> :ok end
          }

          {request, Req.Response.new(status: 200, body: async)}
        end
      )

      {module, model, opts} = split_request(provider)
      {:ok, stream} = module.stream(model, build_context(), opts)
      events = stream |> EventStream.events() |> Enum.reject(&match?({:done, _, _}, &1))
      {:ok, message} = EventStream.result(stream, 5_000)
      {message, Enum.map(events, &without_timestamps/1)}
    end

    defp without_timestamps({:start, message}), do: {:start, %{message | timestamp: 0}}
    defp without_timestamps(event), do: event

    defp split_request(:google), do: {Google, build_model(), build_opts()}

    defp split_request(:google_vertex) do
      model = build_model(%{api: :google_vertex, provider: :google_vertex})

      {LemonAi.Providers.GoogleVertex, model,
       build_opts(%{project: "p", location: "us-central1", access_token: "token"})}
    end

    defp split_request(:google_gemini_cli) do
      model = build_model(%{api: :google_gemini_cli, provider: :google_gemini_cli})
      key = Jason.encode!(%{"token" => "token", "projectId" => "project"})
      {LemonAi.Providers.GoogleGeminiCli, model, build_opts(%{api_key: key})}
    end
  end
end
