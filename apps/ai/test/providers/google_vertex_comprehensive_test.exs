defmodule Ai.Providers.GoogleVertexComprehensiveTest do
  @moduledoc """
  Comprehensive unit tests for Google Vertex AI provider.
  Tests cover authentication, endpoint construction, request formatting,
  response parsing, streaming events, error handling, usage extraction,
  safety settings, and model version handling.
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.GoogleVertex
  alias Ai.Providers.GoogleShared

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
  # Setup
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

  # Helper to build SSE response body
  defp sse_body(chunks) do
    chunks
    |> Enum.map(&("data: " <> Jason.encode!(&1)))
    |> Enum.join("\n")
  end

  # Default test model
  defp test_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "gemini-2.5-pro"),
      name: Keyword.get(opts, :name, "Gemini 2.5 Pro"),
      api: :google_vertex,
      provider: :google_vertex,
      base_url: "https://example.test",
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0}),
      context_window: 1_000_000,
      max_tokens: 8192,
      headers: Keyword.get(opts, :headers, %{})
    }
  end

  # Default stream options with required Vertex AI fields
  defp default_opts(opts \\ []) do
    %StreamOptions{
      project: Keyword.get(opts, :project, "test-project"),
      location: Keyword.get(opts, :location, "us-central1"),
      access_token: Keyword.get(opts, :access_token, "test-token"),
      temperature: Keyword.get(opts, :temperature),
      max_tokens: Keyword.get(opts, :max_tokens),
      reasoning: Keyword.get(opts, :reasoning),
      thinking_budgets: Keyword.get(opts, :thinking_budgets, %{}),
      tool_choice: Keyword.get(opts, :tool_choice),
      headers: Keyword.get(opts, :headers, %{})
    }
  end

  # ============================================================================
  # Provider Identification Tests
  # ============================================================================

  describe "provider identification" do
    test "provider_id returns :google_vertex" do
      assert GoogleVertex.provider_id() == :google_vertex
    end

    test "api_id returns :google_vertex" do
      assert GoogleVertex.api_id() == :google_vertex
    end

    test "get_env_api_key returns nil (uses ADC)" do
      assert GoogleVertex.get_env_api_key() == nil
    end
  end

  # ============================================================================
  # Authentication Flow Tests
  # ============================================================================

  describe "authentication - project resolution" do
    test "uses project from opts when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:url, conn.request_path})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(project: "my-custom-project")

      {:ok, _stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:url, url}, 1000
      assert String.contains?(url, "projects/my-custom-project")
    end

    test "returns error when project is missing" do
      # Clear environment variables
      prev_gcloud_project = System.get_env("GOOGLE_CLOUD_PROJECT")
      prev_gcloud = System.get_env("GCLOUD_PROJECT")
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GCLOUD_PROJECT")

      on_exit(fn ->
        if prev_gcloud_project, do: System.put_env("GOOGLE_CLOUD_PROJECT", prev_gcloud_project)
        if prev_gcloud, do: System.put_env("GCLOUD_PROJECT", prev_gcloud)
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{location: "us-central1", access_token: "token"}

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "project"
    end

    test "returns error when location is missing" do
      # Clear environment variables
      prev_location = System.get_env("GOOGLE_CLOUD_LOCATION")
      System.delete_env("GOOGLE_CLOUD_LOCATION")

      on_exit(fn ->
        if prev_location, do: System.put_env("GOOGLE_CLOUD_LOCATION", prev_location)
      end)

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{project: "proj", access_token: "token"}

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "location"
    end
  end

  describe "authentication - access token" do
    test "uses access_token from opts when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        auth_header = Enum.find_value(conn.req_headers, fn
          {"authorization", v} -> v
          _ -> nil
        end)
        send(test_pid, {:auth, auth_header})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(access_token: "my-secret-token")

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:auth, auth}, 1000
      assert auth == "Bearer my-secret-token"
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Regional Endpoint Construction Tests
  # ============================================================================

  describe "regional endpoint construction" do
    test "constructs URL with us-central1 region" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:host_path, {conn.host, conn.request_path}})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(location: "us-central1")

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:host_path, {host, path}}, 1000
      assert host == "us-central1-aiplatform.googleapis.com"
      assert path =~ "/v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-pro:streamGenerateContent"
      EventStream.result(stream, 1000)
    end

    test "constructs URL with europe-west4 region" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:host_path, {conn.host, conn.request_path}})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(location: "europe-west4")

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:host_path, {host, _path}}, 1000
      assert host == "europe-west4-aiplatform.googleapis.com"
      EventStream.result(stream, 1000)
    end

    test "constructs URL with asia-southeast1 region" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:host_path, {conn.host, conn.request_path}})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(location: "asia-southeast1")

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:host_path, {host, _path}}, 1000
      assert host == "asia-southeast1-aiplatform.googleapis.com"
      EventStream.result(stream, 1000)
    end

    test "includes alt=sse query parameter" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:query, conn.query_string})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:query, query}, 1000
      assert query == "alt=sse"
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Request Formatting Tests (Vertex AI Specific)
  # ============================================================================

  describe "request formatting - basic structure" do
    test "formats simple text message correctly" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hello, Gemini!"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "Hello, Gemini!"}]}]
      EventStream.result(stream, 1000)
    end

    test "includes system instruction when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(system_prompt: "You are a helpful assistant", messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["systemInstruction"] == %{"parts" => [%{"text" => "You are a helpful assistant"}]}
      EventStream.result(stream, 1000)
    end

    test "omits system instruction when nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "systemInstruction")
      EventStream.result(stream, 1000)
    end
  end

  describe "request formatting - generation config" do
    test "includes temperature when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(temperature: 0.7)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["generationConfig"]["temperature"] == 0.7
      EventStream.result(stream, 1000)
    end

    test "includes max_tokens as maxOutputTokens" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(max_tokens: 1024)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["generationConfig"]["maxOutputTokens"] == 1024
      EventStream.result(stream, 1000)
    end

    test "omits generationConfig when no options provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "generationConfig")
      EventStream.result(stream, 1000)
    end
  end

  describe "request formatting - tools" do
    test "includes tools as functionDeclarations" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()

      tools = [
        %Tool{
          name: "get_weather",
          description: "Get the current weather",
          parameters: %{
            "type" => "object",
            "properties" => %{"location" => %{"type" => "string"}},
            "required" => ["location"]
          }
        }
      ]

      context = Context.new(messages: [%UserMessage{content: "What's the weather?"}], tools: tools)
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      assert body["tools"] == [
               %{
                 "functionDeclarations" => [
                   %{
                     "name" => "get_weather",
                     "description" => "Get the current weather",
                     "parameters" => %{
                       "type" => "object",
                       "properties" => %{"location" => %{"type" => "string"}},
                       "required" => ["location"]
                     }
                   }
                 ]
               }
             ]

      EventStream.result(stream, 1000)
    end

    test "includes multiple tools" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()

      tools = [
        %Tool{name: "read_file", description: "Read a file", parameters: %{"type" => "object"}},
        %Tool{name: "write_file", description: "Write a file", parameters: %{"type" => "object"}}
      ]

      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      declarations = body["tools"] |> hd() |> Map.get("functionDeclarations")
      assert length(declarations) == 2
      assert Enum.any?(declarations, &(&1["name"] == "read_file"))
      assert Enum.any?(declarations, &(&1["name"] == "write_file"))
      EventStream.result(stream, 1000)
    end

    test "omits tools when empty list" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "tools")
      EventStream.result(stream, 1000)
    end
  end

  describe "request formatting - tool choice" do
    test "includes toolConfig with AUTO mode" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = default_opts(tool_choice: :auto)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "AUTO"}}
      EventStream.result(stream, 1000)
    end

    test "includes toolConfig with NONE mode" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = default_opts(tool_choice: :none)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "NONE"}}
      EventStream.result(stream, 1000)
    end

    test "includes toolConfig with ANY mode" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = default_opts(tool_choice: :any)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "ANY"}}
      EventStream.result(stream, 1000)
    end

    test "omits toolConfig when tool_choice is nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      tools = [%Tool{name: "test", description: "Test", parameters: %{}}]
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "toolConfig")
      EventStream.result(stream, 1000)
    end
  end

  describe "request formatting - thinking/reasoning config" do
    test "includes thinkingConfig when reasoning is enabled" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(reasoning: :low, thinking_budgets: %{level: "LOW"})

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["generationConfig"]["thinkingConfig"] == %{"includeThoughts" => true, "thinkingLevel" => "LOW"}
      EventStream.result(stream, 1000)
    end

    test "includes thinkingBudget when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(reasoning: :medium, thinking_budgets: %{budget_tokens: 4096})

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["generationConfig"]["thinkingConfig"] == %{"includeThoughts" => true, "thinkingBudget" => 4096}
      EventStream.result(stream, 1000)
    end

    test "omits thinkingConfig when model does not support reasoning" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(reasoning: false)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(reasoning: :low)

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "generationConfig")
      EventStream.result(stream, 1000)
    end

    test "omits thinkingConfig when reasoning option is nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "generationConfig")
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Response Parsing Tests
  # ============================================================================

  describe "response parsing - text content" do
    test "parses simple text response" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello, world!"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      text = EventStream.collect_text(stream)
      assert text == "Hello, world!"
    end

    test "concatenates multiple text chunks" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => ", "}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "world!"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      text = EventStream.collect_text(stream)
      assert text == "Hello, world!"
    end
  end

  describe "response parsing - tool calls" do
    test "parses function call response" do
      body =
        sse_body([
          %{
            "candidates" => [
              %{
                "content" => %{
                  "parts" => [
                    %{
                      "functionCall" => %{
                        "name" => "get_weather",
                        "args" => %{"location" => "San Francisco"}
                      }
                    }
                  ]
                }
              }
            ]
          },
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Weather?"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      tool_calls = Enum.filter(result.content, &match?(%ToolCall{}, &1))
      assert length(tool_calls) == 1

      [tool_call] = tool_calls
      assert tool_call.name == "get_weather"
      assert tool_call.arguments == %{"location" => "San Francisco"}
      assert result.stop_reason == :tool_use
    end

    test "parses multiple function calls" do
      body =
        sse_body([
          %{
            "candidates" => [
              %{
                "content" => %{
                  "parts" => [
                    %{"functionCall" => %{"name" => "tool1", "args" => %{"a" => 1}}},
                    %{"functionCall" => %{"name" => "tool2", "args" => %{"b" => 2}}}
                  ]
                }
              }
            ]
          },
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      tool_calls = Enum.filter(result.content, &match?(%ToolCall{}, &1))
      assert length(tool_calls) == 2
      assert Enum.any?(tool_calls, &(&1.name == "tool1"))
      assert Enum.any?(tool_calls, &(&1.name == "tool2"))
    end

    test "generates unique tool call IDs" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"functionCall" => %{"name" => "test", "args" => %{}}}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"functionCall" => %{"name" => "test", "args" => %{}}}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      tool_calls = Enum.filter(result.content, &match?(%ToolCall{}, &1))
      ids = Enum.map(tool_calls, & &1.id)
      assert length(ids) == length(Enum.uniq(ids)), "Tool call IDs should be unique"
    end
  end

  describe "response parsing - thinking content" do
    test "parses thinking content with thought=true marker" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Let me think...", "thought" => true}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Here is my answer."}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      thinking = Enum.filter(result.content, &match?(%ThinkingContent{}, &1))
      text = Enum.filter(result.content, &match?(%TextContent{}, &1))

      assert length(thinking) == 1
      assert length(text) == 1
      assert hd(thinking).thinking == "Let me think..."
      assert hd(text).text == "Here is my answer."
    end
  end

  # ============================================================================
  # Streaming Events Tests
  # ============================================================================

  describe "streaming events" do
    test "emits start event and completes successfully" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      # Collect events via the events stream
      events = stream |> EventStream.events() |> Enum.to_list()

      assert Enum.any?(events, fn
               {:start, _} -> true
               _ -> false
             end)
    end

    test "emits text_start and text_end events" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      events = stream |> EventStream.events() |> Enum.to_list()

      has_text_start = Enum.any?(events, fn
        {:text_start, _idx, _output} -> true
        _ -> false
      end)

      has_text_end = Enum.any?(events, fn
        {:text_end, _idx, _text, _output} -> true
        _ -> false
      end)

      assert has_text_start
      assert has_text_end
    end

    test "emits text_delta events" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => " world"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      events = stream |> EventStream.events() |> Enum.to_list()

      deltas =
        Enum.filter(events, fn
          {:text_delta, _idx, _delta, _output} -> true
          _ -> false
        end)

      assert length(deltas) >= 2
    end

    test "emits tool_call events" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"functionCall" => %{"name" => "test", "args" => %{}}}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      events = stream |> EventStream.events() |> Enum.to_list()

      has_tool_call_start = Enum.any?(events, fn
        {:tool_call_start, _idx, _output} -> true
        _ -> false
      end)

      has_tool_call_end = Enum.any?(events, fn
        {:tool_call_end, _idx, _tool_call, _output} -> true
        _ -> false
      end)

      assert has_tool_call_start
      assert has_tool_call_end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling - HTTP errors" do
    test "handles 400 Bad Request" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Invalid request"}})
        Plug.Conn.send_resp(conn, 400, error_body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} =
               EventStream.result(stream, 1000)

      assert msg =~ "400"
    end

    test "handles 401 Unauthorized" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Invalid credentials"}})
        Plug.Conn.send_resp(conn, 401, error_body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error}} =
               EventStream.result(stream, 1000)
    end

    test "handles 403 Forbidden (permission error)" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Permission denied on resource"}})
        Plug.Conn.send_resp(conn, 403, error_body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error}} =
               EventStream.result(stream, 1000)
    end

    test "handles 404 Not Found (region/model error)" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Model not found in region"}})
        Plug.Conn.send_resp(conn, 404, error_body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error}} =
               EventStream.result(stream, 1000)
    end

    test "handles 429 quota exceeded" do
      Req.Test.stub(__MODULE__, fn conn ->
        error_body = Jason.encode!(%{"error" => %{"message" => "Quota exceeded. Your quota will reset after 60s"}})
        Plug.Conn.send_resp(conn, 429, error_body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error}} =
               EventStream.result(stream, 1000)
    end

    test "handles 500 Internal Server Error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 500, "Internal Server Error")
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:error, %AssistantMessage{stop_reason: :error}} =
               EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Token/Usage Extraction Tests
  # ============================================================================

  describe "usage extraction" do
    test "extracts prompt and candidate token counts" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]},
          %{
            "candidates" => [%{"finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 100,
              "candidatesTokenCount" => 50,
              "thoughtsTokenCount" => 0,
              "cachedContentTokenCount" => 0,
              "totalTokenCount" => 150
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert result.usage.input == 100
      assert result.usage.output == 50
      assert result.usage.total_tokens == 150
    end

    test "includes thoughts token count in output" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]},
          %{
            "candidates" => [%{"finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 100,
              "candidatesTokenCount" => 30,
              "thoughtsTokenCount" => 20,
              "totalTokenCount" => 150
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model(reasoning: true)
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      # Output should include both candidatesTokenCount + thoughtsTokenCount
      assert result.usage.output == 50
    end

    test "extracts cached content token count" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]},
          %{
            "candidates" => [%{"finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 100,
              "candidatesTokenCount" => 50,
              "cachedContentTokenCount" => 25,
              "totalTokenCount" => 150
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      assert result.usage.cache_read == 25
    end

    test "calculates cost based on model pricing" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hi"}]}}]},
          %{
            "candidates" => [%{"finishReason" => "STOP"}],
            "usageMetadata" => %{
              "promptTokenCount" => 1000,
              "candidatesTokenCount" => 500,
              "cachedContentTokenCount" => 200,
              "totalTokenCount" => 1500
            }
          }
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model(cost: %ModelCost{input: 1.25, output: 5.0, cache_read: 0.3125, cache_write: 0.0})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      # input: 1000 * 1.25 / 1_000_000 = 0.00125
      assert_in_delta result.usage.cost.input, 0.00125, 0.000001
      # output: 500 * 5.0 / 1_000_000 = 0.0025
      assert_in_delta result.usage.cost.output, 0.0025, 0.000001
      # cache_read: 200 * 0.3125 / 1_000_000 = 0.0000625
      assert_in_delta result.usage.cost.cache_read, 0.0000625, 0.0000001
    end
  end

  # ============================================================================
  # Stop Reason Mapping Tests
  # ============================================================================

  describe "stop reason mapping" do
    test "maps STOP to :stop" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Done"}]}, "finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :stop
    end

    test "maps MAX_TOKENS to :length" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Truncated"}]}, "finishReason" => "MAX_TOKENS"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :length
    end

    test "sets :tool_use when function calls present" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"functionCall" => %{"name" => "test", "args" => %{}}}]}, "finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :tool_use
    end
  end

  # ============================================================================
  # Model Version Handling Tests
  # ============================================================================

  describe "model version handling" do
    test "handles gemini-2.5-pro model" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(id: "gemini-2.5-pro")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:path, path}, 1000
      assert path =~ "gemini-2.5-pro"
      EventStream.result(stream, 1000)
    end

    test "handles gemini-2.5-flash model" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(id: "gemini-2.5-flash")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:path, path}, 1000
      assert path =~ "gemini-2.5-flash"
      EventStream.result(stream, 1000)
    end

    test "handles gemini-3-pro model" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(id: "gemini-3-pro-preview-0520")
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:path, path}, 1000
      assert path =~ "gemini-3-pro-preview-0520"
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Headers Tests
  # ============================================================================

  describe "custom headers" do
    test "includes model headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        headers = Enum.into(conn.req_headers, %{})
        send(test_pid, {:headers, headers})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model(headers: %{"X-Custom-Model-Header" => "model-value"})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      assert headers["x-custom-model-header"] == "model-value"
      EventStream.result(stream, 1000)
    end

    test "includes opts headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        headers = Enum.into(conn.req_headers, %{})
        send(test_pid, {:headers, headers})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts(headers: %{"X-Custom-Request-Header" => "request-value"})

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      assert headers["x-custom-request-header"] == "request-value"
      EventStream.result(stream, 1000)
    end

    test "includes Content-Type header" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        headers = Enum.into(conn.req_headers, %{})
        send(test_pid, {:headers, headers})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:headers, headers}, 1000
      assert headers["content-type"] =~ "application/json"
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # GoogleShared Integration Tests
  # ============================================================================

  describe "GoogleShared utilities" do
    test "map_tool_choice returns correct modes" do
      assert GoogleShared.map_tool_choice(:auto) == "AUTO"
      assert GoogleShared.map_tool_choice(:none) == "NONE"
      assert GoogleShared.map_tool_choice(:any) == "ANY"
      assert GoogleShared.map_tool_choice(:unknown) == "AUTO"
    end

    test "map_stop_reason maps correctly" do
      assert GoogleShared.map_stop_reason("STOP") == :stop
      assert GoogleShared.map_stop_reason("MAX_TOKENS") == :length
      assert GoogleShared.map_stop_reason("SAFETY") == :error
      assert GoogleShared.map_stop_reason("OTHER") == :error
    end

    test "thinking_part? detects thought marker" do
      assert GoogleShared.thinking_part?(%{"thought" => true})
      refute GoogleShared.thinking_part?(%{"thought" => false})
      refute GoogleShared.thinking_part?(%{"text" => "hello"})
      refute GoogleShared.thinking_part?(%{"thoughtSignature" => "sig123"})
    end

    test "retain_thought_signature preserves signatures" do
      assert GoogleShared.retain_thought_signature(nil, "new_sig") == "new_sig"
      assert GoogleShared.retain_thought_signature("old_sig", "new_sig") == "new_sig"
      assert GoogleShared.retain_thought_signature("old_sig", nil) == "old_sig"
      assert GoogleShared.retain_thought_signature("old_sig", "") == "old_sig"
    end

    test "valid_thought_signature? validates base64 format" do
      assert GoogleShared.valid_thought_signature?("AAAA")
      assert GoogleShared.valid_thought_signature?("YWJjZA==")
      refute GoogleShared.valid_thought_signature?(nil)
      refute GoogleShared.valid_thought_signature?("not-base64!")
      refute GoogleShared.valid_thought_signature?("abc")
    end

    test "sanitize_surrogates handles valid UTF-8" do
      assert GoogleShared.sanitize_surrogates("Hello, world!") == "Hello, world!"
      assert GoogleShared.sanitize_surrogates("Emoji: \u{1F600}") == "Emoji: \u{1F600}"
    end

    test "requires_tool_call_id? detects Claude/GPT models" do
      assert GoogleShared.requires_tool_call_id?("claude-3-sonnet")
      assert GoogleShared.requires_tool_call_id?("gpt-oss-4")
      refute GoogleShared.requires_tool_call_id?("gemini-2.5-pro")
    end
  end

  # ============================================================================
  # Registration Tests
  # ============================================================================

  describe "provider registration" do
    test "register/1 registers provider" do
      result = GoogleVertex.register([])
      assert result == :ignore
    end

    test "child_spec returns correct spec" do
      spec = GoogleVertex.child_spec([])
      assert spec.id == GoogleVertex
      assert spec.type == :worker
      assert spec.restart == :transient
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles empty response parts" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => []}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :stop
    end

    test "handles missing candidate content" do
      body =
        sse_body([
          %{"candidates" => [%{}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)
      assert result.stop_reason == :stop
    end

    test "handles empty text parts" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => ""}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Hello"}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      text = EventStream.collect_text(stream)
      assert text == "Hello"
    end

    test "handles mixed text and function calls" do
      body =
        sse_body([
          %{"candidates" => [%{"content" => %{"parts" => [%{"text" => "Let me check... "}]}}]},
          %{"candidates" => [%{"content" => %{"parts" => [%{"functionCall" => %{"name" => "search", "args" => %{"q" => "test"}}}]}}]},
          %{"candidates" => [%{"finishReason" => "STOP"}]}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert {:ok, result} = EventStream.result(stream, 1000)

      text_blocks = Enum.filter(result.content, &match?(%TextContent{}, &1))
      tool_calls = Enum.filter(result.content, &match?(%ToolCall{}, &1))

      assert length(text_blocks) == 1
      assert length(tool_calls) == 1
      assert hd(text_blocks).text == "Let me check... "
      assert hd(tool_calls).name == "search"
      assert result.stop_reason == :tool_use
    end
  end

  # ============================================================================
  # Message Conversion Tests (via GoogleShared)
  # ============================================================================

  describe "message conversion" do
    test "converts user message with text content list" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()
      context = Context.new(messages: [%UserMessage{content: [%TextContent{text: "Hello"}]}])
      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["contents"] == [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]
      EventStream.result(stream, 1000)
    end

    test "converts assistant message with tool call" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [
          %TextContent{text: "I'll search for that"},
          %ToolCall{id: "call_123", name: "search", arguments: %{"q" => "test"}}
        ],
        provider: :google_vertex,
        model: "gemini-2.5-pro"
      }

      tool_result = %ToolResultMessage{
        tool_call_id: "call_123",
        tool_name: "search",
        content: [%TextContent{text: "Search results..."}]
      }

      context = Context.new(messages: [
        %UserMessage{content: "Search for test"},
        assistant_msg,
        tool_result,
        %UserMessage{content: "Thanks"}
      ])

      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      # Verify the conversation structure is properly converted
      assert length(body["contents"]) >= 3
      EventStream.result(stream, 1000)
    end

    test "converts tool result message" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [%ToolCall{id: "call_1", name: "read_file", arguments: %{"path" => "/test.txt"}}],
        provider: :google_vertex,
        model: "gemini-2.5-pro"
      }

      tool_result = %ToolResultMessage{
        tool_call_id: "call_1",
        tool_name: "read_file",
        content: [%TextContent{text: "File contents here"}],
        is_error: false
      }

      context = Context.new(messages: [
        %UserMessage{content: "Read the file"},
        assistant_msg,
        tool_result
      ])

      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      # Find the function response
      user_parts =
        body["contents"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> Enum.flat_map(&(&1["parts"] || []))

      fn_response = Enum.find(user_parts, &Map.has_key?(&1, "functionResponse"))
      assert fn_response != nil
      assert fn_response["functionResponse"]["name"] == "read_file"
      EventStream.result(stream, 1000)
    end

    test "converts error tool result" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([%{"candidates" => [%{"finishReason" => "STOP"}]}]))
      end)

      model = test_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [%ToolCall{id: "call_1", name: "read_file", arguments: %{}}],
        provider: :google_vertex,
        model: "gemini-2.5-pro"
      }

      tool_result = %ToolResultMessage{
        tool_call_id: "call_1",
        tool_name: "read_file",
        content: [%TextContent{text: "File not found"}],
        is_error: true
      }

      context = Context.new(messages: [
        %UserMessage{content: "Read file"},
        assistant_msg,
        tool_result
      ])

      opts = default_opts()

      {:ok, stream} = GoogleVertex.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      user_parts =
        body["contents"]
        |> Enum.filter(&(&1["role"] == "user"))
        |> Enum.flat_map(&(&1["parts"] || []))

      fn_response = Enum.find(user_parts, &Map.has_key?(&1, "functionResponse"))
      assert fn_response != nil
      assert fn_response["functionResponse"]["response"]["error"] == "File not found"
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Thinking Budget Tests
  # ============================================================================

  describe "thinking budget configuration" do
    test "default budgets for 2.5 Pro model" do
      budgets = GoogleShared.default_budgets_2_5_pro()

      assert budgets[:minimal] == 128
      assert budgets[:low] == 2048
      assert budgets[:medium] == 8192
      assert budgets[:high] == 32768
    end

    test "default budgets for 2.5 Flash model" do
      budgets = GoogleShared.default_budgets_2_5_flash()

      assert budgets[:minimal] == 128
      assert budgets[:low] == 2048
      assert budgets[:medium] == 8192
      assert budgets[:high] == 24576
    end

    test "get_thinking_budget uses custom budget when provided" do
      model = test_model(id: "gemini-2.5-pro")
      custom_budgets = %{low: 5000}

      budget = GoogleShared.get_thinking_budget(model, :low, custom_budgets)
      assert budget == 5000
    end

    test "get_thinking_budget falls back to model defaults" do
      model = test_model(id: "gemini-2.5-pro")

      budget = GoogleShared.get_thinking_budget(model, :low, %{})
      assert budget == 2048
    end

    test "clamp_reasoning handles various levels" do
      assert GoogleShared.clamp_reasoning(nil) == nil
      assert GoogleShared.clamp_reasoning(:minimal) == :minimal
      assert GoogleShared.clamp_reasoning(:low) == :low
      assert GoogleShared.clamp_reasoning(:medium) == :medium
      assert GoogleShared.clamp_reasoning(:high) == :high
      assert GoogleShared.clamp_reasoning(:xhigh) == :high
      assert GoogleShared.clamp_reasoning(:unknown) == nil
    end
  end

  # ============================================================================
  # Gemini 3 Specific Tests
  # ============================================================================

  describe "Gemini 3 model detection" do
    test "gemini_3_pro? detects pro model" do
      assert GoogleShared.gemini_3_pro?("gemini-3-pro")
      assert GoogleShared.gemini_3_pro?("gemini-3-pro-preview-0520")
      refute GoogleShared.gemini_3_pro?("gemini-3-flash")
      refute GoogleShared.gemini_3_pro?("gemini-2.5-pro")
    end

    test "gemini_3_flash? detects flash model" do
      assert GoogleShared.gemini_3_flash?("gemini-3-flash")
      assert GoogleShared.gemini_3_flash?("gemini-3-flash-preview")
      refute GoogleShared.gemini_3_flash?("gemini-3-pro")
      refute GoogleShared.gemini_3_flash?("gemini-2.5-flash")
    end

    test "get_gemini_3_thinking_level returns correct levels for pro" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-pro") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-pro") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-pro") == "HIGH"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-pro") == "HIGH"
    end

    test "get_gemini_3_thinking_level returns all levels for flash" do
      assert GoogleShared.get_gemini_3_thinking_level(:minimal, "gemini-3-flash") == "MINIMAL"
      assert GoogleShared.get_gemini_3_thinking_level(:low, "gemini-3-flash") == "LOW"
      assert GoogleShared.get_gemini_3_thinking_level(:medium, "gemini-3-flash") == "MEDIUM"
      assert GoogleShared.get_gemini_3_thinking_level(:high, "gemini-3-flash") == "HIGH"
    end
  end
end
