defmodule Ai.Providers.AzureOpenAIResponsesComprehensiveTest do
  @moduledoc """
  Comprehensive unit tests for Azure OpenAI Responses API provider.
  Tests request formatting, response parsing, error handling,
  deployment name resolution, streaming events, and Azure-specific configuration.
  """
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.AzureOpenAIResponses
  alias Ai.Providers.OpenAIResponsesShared

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Cost,
    ImageContent,
    Model,
    ModelCost,
    StreamOptions,
    TextContent,
    ThinkingContent,
    Tool,
    ToolCall,
    ToolResultMessage,
    Usage,
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

    # Clear any environment variables that might interfere
    prev_api_key = System.get_env("AZURE_OPENAI_API_KEY")
    prev_base_url = System.get_env("AZURE_OPENAI_BASE_URL")
    prev_resource = System.get_env("AZURE_OPENAI_RESOURCE_NAME")
    prev_api_version = System.get_env("AZURE_OPENAI_API_VERSION")
    prev_deployment_map = System.get_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")

    System.delete_env("AZURE_OPENAI_API_KEY")
    System.delete_env("AZURE_OPENAI_BASE_URL")
    System.delete_env("AZURE_OPENAI_RESOURCE_NAME")
    System.delete_env("AZURE_OPENAI_API_VERSION")
    System.delete_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})

      # Restore environment variables
      if prev_api_key, do: System.put_env("AZURE_OPENAI_API_KEY", prev_api_key)
      if prev_base_url, do: System.put_env("AZURE_OPENAI_BASE_URL", prev_base_url)
      if prev_resource, do: System.put_env("AZURE_OPENAI_RESOURCE_NAME", prev_resource)
      if prev_api_version, do: System.put_env("AZURE_OPENAI_API_VERSION", prev_api_version)

      if prev_deployment_map,
        do: System.put_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", prev_deployment_map)
    end)

    :ok
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp sse_body(events) do
    events
    |> Enum.map(fn
      :done -> "data: [DONE]"
      event -> "data: " <> Jason.encode!(event)
    end)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n\n")
  end

  defp base_model(overrides \\ %{}) do
    %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :azure_openai_responses,
      provider: :"azure-openai-responses",
      base_url: "https://myresource.openai.azure.com/openai/v1",
      reasoning: Map.get(overrides, :reasoning, false),
      input: Map.get(overrides, :input, [:text]),
      cost: %ModelCost{input: 2.5, output: 10.0, cache_read: 1.25, cache_write: 0.0}
    }
    |> Map.merge(Map.drop(overrides, [:reasoning, :input]))
  end

  # ============================================================================
  # Provider Identification Tests
  # ============================================================================

  describe "provider identification" do
    test "api_id returns correct identifier" do
      assert AzureOpenAIResponses.api_id() == :azure_openai_responses
    end

    test "provider_id returns correct identifier" do
      assert AzureOpenAIResponses.provider_id() == :"azure-openai-responses"
    end

    test "get_env_api_key reads from environment" do
      System.put_env("AZURE_OPENAI_API_KEY", "test-azure-key")
      assert AzureOpenAIResponses.get_env_api_key() == "test-azure-key"
      System.delete_env("AZURE_OPENAI_API_KEY")
    end

    test "get_env_api_key returns nil when not set" do
      assert AzureOpenAIResponses.get_env_api_key() == nil
    end
  end

  # ============================================================================
  # Request Headers Tests
  # ============================================================================

  describe "request headers" do
    test "includes api-key header" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "my-azure-api-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["api-key"] == "my-azure-api-key"

      EventStream.result(stream, 1000)
    end

    test "includes content-type header" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["content-type"] == "application/json"

      EventStream.result(stream, 1000)
    end

    test "includes accept header for SSE" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["accept"] == "text/event-stream"

      EventStream.result(stream, 1000)
    end

    test "merges model-specific headers" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | headers: %{"x-custom-model" => "custom-value"}}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["x-custom-model"] == "custom-value"

      EventStream.result(stream, 1000)
    end

    test "merges user-provided headers from opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", headers: %{"x-user-header" => "user-value"}}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)

      assert headers_map["x-user-header"] == "user-value"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # URL Construction Tests
  # ============================================================================

  describe "URL construction" do
    test "includes api-version query parameter" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_query, conn.query_string})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        thinking_budgets: %{azure_api_version: "2024-12-01-preview"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_query, query}, 1000
      assert String.contains?(query, "api-version=2024-12-01-preview")

      EventStream.result(stream, 1000)
    end

    test "uses default api-version when not specified" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_query, conn.query_string})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_query, query}, 1000
      assert String.contains?(query, "api-version=v1")

      EventStream.result(stream, 1000)
    end

    test "uses api-version from environment variable" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_API_VERSION", "2025-01-01")

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_query, conn.query_string})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_query, query}, 1000
      assert String.contains?(query, "api-version=2025-01-01")

      System.delete_env("AZURE_OPENAI_API_VERSION")
      EventStream.result(stream, 1000)
    end

    test "appends /responses to base URL" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_path, path}, 1000
      assert String.ends_with?(path, "/responses")

      EventStream.result(stream, 1000)
    end

    test "trims trailing slash from base URL" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_path, conn.request_path})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: "https://myresource.openai.azure.com/openai/v1/"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_path, path}, 1000
      refute String.contains?(path, "//responses")
      assert String.ends_with?(path, "/responses")

      EventStream.result(stream, 1000)
    end

    test "uses AZURE_OPENAI_BASE_URL from environment" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_BASE_URL", "https://envresource.openai.azure.com/openai/v1")

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_host, conn.host})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: nil}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_host, host}, 1000
      assert host == "envresource.openai.azure.com"

      System.delete_env("AZURE_OPENAI_BASE_URL")
      EventStream.result(stream, 1000)
    end

    test "builds URL from AZURE_OPENAI_RESOURCE_NAME" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_RESOURCE_NAME", "myazureresource")

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_host, conn.host})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: nil}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_host, host}, 1000
      assert host == "myazureresource.openai.azure.com"

      System.delete_env("AZURE_OPENAI_RESOURCE_NAME")
      EventStream.result(stream, 1000)
    end

    test "uses azure_base_url from thinking_budgets opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_host, conn.host})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: nil}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        thinking_budgets: %{azure_base_url: "https://optsresource.openai.azure.com/openai/v1"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_host, host}, 1000
      assert host == "optsresource.openai.azure.com"

      EventStream.result(stream, 1000)
    end

    test "uses azure_resource_name from thinking_budgets opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_host, conn.host})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: nil}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        thinking_budgets: %{azure_resource_name: "optsresourcename"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_host, host}, 1000
      assert host == "optsresourcename.openai.azure.com"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Deployment Name Resolution Tests
  # ============================================================================

  describe "deployment name resolution" do
    test "uses model id as default deployment name" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | id: "gpt-4o-deployment"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "gpt-4o-deployment"

      EventStream.result(stream, 1000)
    end

    test "uses azure_deployment_name from opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | id: "gpt-4o"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        thinking_budgets: %{azure_deployment_name: "my-custom-deployment"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "my-custom-deployment"

      EventStream.result(stream, 1000)
    end

    test "uses deployment name from environment mapping" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "gpt-4o=gpt4o-prod-deployment")

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | id: "gpt-4o"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "gpt4o-prod-deployment"

      System.delete_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")
      EventStream.result(stream, 1000)
    end

    test "handles multiple deployment mappings" do
      test_pid = self()

      System.put_env(
        "AZURE_OPENAI_DEPLOYMENT_NAME_MAP",
        "gpt-4o=gpt4o-prod,gpt-3.5-turbo=gpt35-prod,o1-mini=o1mini-deploy"
      )

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | id: "o1-mini"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "o1mini-deploy"

      System.delete_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")
      EventStream.result(stream, 1000)
    end

    test "opts deployment name takes precedence over env mapping" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP", "gpt-4o=env-deployment")

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | id: "gpt-4o"}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        thinking_budgets: %{azure_deployment_name: "opts-deployment"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "opts-deployment"

      System.delete_env("AZURE_OPENAI_DEPLOYMENT_NAME_MAP")
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Request Body Structure Tests
  # ============================================================================

  describe "request body structure" do
    test "includes model field with deployment name" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["model"] == "gpt-4o"

      EventStream.result(stream, 1000)
    end

    test "includes stream field set to true" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["stream"] == true

      EventStream.result(stream, 1000)
    end

    test "includes input array with messages" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hello world"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert is_list(body["input"])
      assert length(body["input"]) == 1

      [msg] = body["input"]
      assert msg["role"] == "user"
      assert [%{"type" => "input_text", "text" => "Hello world"}] = msg["content"]

      EventStream.result(stream, 1000)
    end

    test "includes system prompt as developer role for reasoning models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: true})

      context =
        Context.new(system_prompt: "You are helpful", messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{api_key: "test-key", reasoning: :medium}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [system_msg | _] = body["input"]
      assert system_msg["role"] == "developer"
      assert system_msg["content"] == "You are helpful"

      EventStream.result(stream, 1000)
    end

    test "includes system prompt as system role for non-reasoning models" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: false})

      context =
        Context.new(system_prompt: "You are helpful", messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [system_msg | _] = body["input"]
      assert system_msg["role"] == "system"
      assert system_msg["content"] == "You are helpful"

      EventStream.result(stream, 1000)
    end

    test "includes prompt_cache_key when session_id provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", session_id: "my-session-123"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["prompt_cache_key"] == "my-session-123"

      EventStream.result(stream, 1000)
    end

    test "includes max_output_tokens when max_tokens provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", max_tokens: 4096}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["max_output_tokens"] == 4096

      EventStream.result(stream, 1000)
    end

    test "includes temperature when provided" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", temperature: 0.7}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["temperature"] == 0.7

      EventStream.result(stream, 1000)
    end

    test "omits optional params when nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "prompt_cache_key")
      refute Map.has_key?(body, "max_output_tokens")
      refute Map.has_key?(body, "temperature")

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Tools Conversion Tests
  # ============================================================================

  describe "tools conversion" do
    test "includes tools in request body" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      tool = %Tool{
        name: "read_file",
        description: "Read a file from disk",
        parameters: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      }

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert is_list(body["tools"])
      assert length(body["tools"]) == 1

      [converted_tool] = body["tools"]
      assert converted_tool["type"] == "function"
      assert converted_tool["name"] == "read_file"
      assert converted_tool["description"] == "Read a file from disk"

      EventStream.result(stream, 1000)
    end

    test "includes multiple tools" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      tools = [
        %Tool{name: "tool_a", description: "Tool A", parameters: %{}},
        %Tool{name: "tool_b", description: "Tool B", parameters: %{}},
        %Tool{name: "tool_c", description: "Tool C", parameters: %{}}
      ]

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: tools)
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert length(body["tools"]) == 3

      EventStream.result(stream, 1000)
    end

    test "omits tools when empty list" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "tools")

      EventStream.result(stream, 1000)
    end

    test "tool parameters are passed through" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      tool = %Tool{
        name: "search",
        description: "Search for things",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query"},
            "limit" => %{"type" => "integer", "default" => 10}
          },
          "required" => ["query"]
        }
      }

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}], tools: [tool])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [converted] = body["tools"]
      assert converted["parameters"]["properties"]["query"]["type"] == "string"
      assert converted["parameters"]["required"] == ["query"]

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Reasoning Configuration Tests
  # ============================================================================

  describe "reasoning configuration" do
    test "includes reasoning config for reasoning models with effort" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", reasoning: :high}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["effort"] == "high"
      assert "reasoning.encrypted_content" in body["include"]

      EventStream.result(stream, 1000)
    end

    test "includes reasoning summary from opts" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      opts = %StreamOptions{
        api_key: "test-key",
        reasoning: :medium,
        thinking_budgets: %{summary: "detailed"}
      }

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "detailed"

      EventStream.result(stream, 1000)
    end

    test "uses auto summary by default" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key", reasoning: :low}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      assert body["reasoning"]["summary"] == "auto"

      EventStream.result(stream, 1000)
    end

    test "omits reasoning when not reasoning model" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: false})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      refute Map.has_key?(body, "reasoning")
      refute Map.has_key?(body, "include")

      EventStream.result(stream, 1000)
    end

    test "defaults to medium reasoning effort when opts.reasoning is nil" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      # No reasoning option specified
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      # Azure defaults to :medium when reasoning is nil
      assert body["reasoning"]["effort"] == "medium"
      assert "reasoning.encrypted_content" in body["include"]

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "returns error when API key is missing" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: nil}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "returns error when API key is empty string" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: ""}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles 400 bad request error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 400, Jason.encode!(%{error: %{message: "Invalid request"}}))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles 401 unauthorized error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 401, Jason.encode!(%{error: %{message: "Invalid API key"}}))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "invalid-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles 429 rate limit error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 429, Jason.encode!(%{error: %{message: "Rate limit exceeded"}}))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles 500 server error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          500,
          Jason.encode!(%{error: %{message: "Internal server error"}})
        )
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles 503 service unavailable error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 503, Jason.encode!(%{error: %{message: "Service unavailable"}}))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles Azure-specific deployment not found error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          404,
          Jason.encode!(%{
            error: %{
              code: "DeploymentNotFound",
              message: "The API deployment for this resource does not exist."
            }
          })
        )
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles Azure content filter error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(
          conn,
          400,
          Jason.encode!(%{
            error: %{
              code: "content_filter",
              message:
                "The response was filtered due to the prompt triggering Azure OpenAI's content management policy."
            }
          })
        )
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Bad content"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 1000)
    end

    test "handles missing base URL error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = %{base_model() | base_url: nil}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      result = EventStream.result(stream, 1000)
      assert {:error, %AssistantMessage{stop_reason: :error, error_message: msg}} = result
      assert String.contains?(msg, "base URL")
    end
  end

  # ============================================================================
  # Streaming Response Parsing Tests
  # ============================================================================

  describe "streaming response parsing" do
    test "parses text response" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Hello, "},
        %{"type" => "response.output_text.delta", "delta" => "world!"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "id" => "msg_123",
            "content" => [%{"type" => "output_text", "text" => "Hello, world!"}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      assert result.stop_reason == :stop
      [%TextContent{text: text}] = result.content
      assert text == "Hello, world!"
    end

    test "parses function call response" do
      events = [
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_abc123",
            "id" => "fc_xyz",
            "name" => "read_file"
          }
        },
        %{"type" => "response.function_call_arguments.delta", "delta" => "{\"path\":"},
        %{"type" => "response.function_call_arguments.delta", "delta" => "\"/test.txt\"}"},
        %{
          "type" => "response.function_call_arguments.done",
          "arguments" => "{\"path\":\"/test.txt\"}"
        },
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_abc123",
            "id" => "fc_xyz",
            "name" => "read_file",
            "arguments" => "{\"path\":\"/test.txt\"}"
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()

      tool = %Tool{
        name: "read_file",
        description: "Read a file",
        parameters: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }

      context = Context.new(messages: [%UserMessage{content: "Read /test.txt"}], tools: [tool])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      assert result.stop_reason == :tool_use
      [%ToolCall{} = tc] = result.content
      assert tc.name == "read_file"
      assert tc.arguments == %{"path" => "/test.txt"}
      assert tc.id == "call_abc123|fc_xyz"
    end

    test "parses reasoning response" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "reasoning"}},
        %{
          "type" => "response.reasoning_summary_part.added",
          "part" => %{"type" => "summary_text"}
        },
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "Let me think "},
        %{"type" => "response.reasoning_summary_text.delta", "delta" => "about this."},
        %{"type" => "response.reasoning_summary_part.done"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "reasoning",
            "summary" => [%{"text" => "Let me think about this."}]
          }
        },
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Here is the answer."},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "id" => "msg_456",
            "content" => [%{"type" => "output_text", "text" => "Here is the answer."}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model(%{reasoning: true})
      context = Context.new(messages: [%UserMessage{content: "Think about this"}])
      opts = %StreamOptions{api_key: "test-key", reasoning: :medium}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      assert length(result.content) == 2
      [thinking, text] = result.content
      assert %ThinkingContent{thinking: thinking_text} = thinking
      assert String.contains?(thinking_text, "Let me think")
      assert %TextContent{text: answer} = text
      assert answer == "Here is the answer."
    end

    test "parses refusal response" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.refusal.delta", "delta" => "I cannot "},
        %{"type" => "response.refusal.delta", "delta" => "help with that."},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "refusal", "refusal" => "I cannot help with that."}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Do something bad"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      [%TextContent{text: text}] = result.content
      assert text == "I cannot help with that."
    end

    test "handles stream error event" do
      events = [
        %{"type" => "error", "code" => "rate_limit_exceeded", "message" => "Too many requests"}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 2000)
    end

    test "handles response.failed event" do
      events = [
        %{"type" => "response.failed"}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:error, %AssistantMessage{stop_reason: :error}} = EventStream.result(stream, 2000)
    end
  end

  # ============================================================================
  # Token Usage Tests
  # ============================================================================

  describe "token usage extraction" do
    test "extracts input and output tokens" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello"}]
          }
        },
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

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      assert result.usage.input == 100
      assert result.usage.output == 50
      assert result.usage.total_tokens == 150
    end

    test "extracts cached tokens" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello"}]
          }
        },
        %{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 50,
              "total_tokens" => 150,
              "input_tokens_details" => %{
                "cached_tokens" => 80
              }
            }
          }
        }
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      assert result.usage.cache_read == 80
      # Input minus cached
      assert result.usage.input == 20
    end

    test "calculates cost based on model pricing" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Hello"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Hello"}]
          }
        },
        %{
          "type" => "response.completed",
          "response" => %{
            "status" => "completed",
            "usage" => %{
              "input_tokens" => 1_000_000,
              "output_tokens" => 1_000_000,
              "total_tokens" => 2_000_000
            }
          }
        }
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)

      # Model cost is input: 2.5, output: 10.0 per million tokens
      assert result.usage.cost.input == 2.5
      assert result.usage.cost.output == 10.0
      assert result.usage.cost.total == 12.5
    end
  end

  # ============================================================================
  # Stop Reason Mapping Tests
  # ============================================================================

  describe "stop reason mapping" do
    test "completed maps to :stop" do
      events = [
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :stop
    end

    test "incomplete maps to :length" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Partial..."},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Partial..."}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "incomplete"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :length
    end

    test "cancelled maps to :error" do
      events = [
        %{"type" => "response.completed", "response" => %{"status" => "cancelled"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :error
    end

    test "tool calls change stop_reason to :tool_use" do
      events = [
        %{
          "type" => "response.output_item.added",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_123",
            "id" => "fc_456",
            "name" => "test_tool"
          }
        },
        %{"type" => "response.function_call_arguments.done", "arguments" => "{}"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "function_call",
            "call_id" => "call_123",
            "id" => "fc_456",
            "name" => "test_tool",
            "arguments" => "{}"
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      tool = %Tool{name: "test_tool", description: "Test", parameters: %{}}
      context = Context.new(messages: [%UserMessage{content: "Use tool"}], tools: [tool])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      assert result.stop_reason == :tool_use
    end
  end

  # ============================================================================
  # Message Conversion Tests
  # ============================================================================

  describe "message conversion" do
    test "converts user message with text content" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hello world"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [msg] = body["input"]
      assert msg["role"] == "user"
      assert [%{"type" => "input_text", "text" => "Hello world"}] = msg["content"]

      EventStream.result(stream, 1000)
    end

    test "converts user message with image content" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{input: [:text, :image]})
      image = %ImageContent{data: "base64data==", mime_type: "image/png"}
      context = Context.new(messages: [%UserMessage{content: [image]}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [msg] = body["input"]

      [img_content] = msg["content"]
      assert img_content["type"] == "input_image"
      assert String.contains?(img_content["image_url"], "data:image/png;base64,")

      EventStream.result(stream, 1000)
    end

    test "filters images when model doesn't support them" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model(%{input: [:text]})
      image = %ImageContent{data: "base64data==", mime_type: "image/png"}
      text = %TextContent{text: "Check this out"}
      context = Context.new(messages: [%UserMessage{content: [text, image]}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000
      [msg] = body["input"]

      # Should only have text, no image
      assert length(msg["content"]) == 1
      [content] = msg["content"]
      assert content["type"] == "input_text"

      EventStream.result(stream, 1000)
    end

    test "converts tool result message" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()

      assistant_msg = %AssistantMessage{
        role: :assistant,
        content: [
          %ToolCall{
            type: :tool_call,
            id: "call_abc|fc_123",
            name: "read_file",
            arguments: %{"path" => "/test.txt"}
          }
        ],
        api: :azure_openai_responses,
        provider: :"azure-openai-responses",
        model: "gpt-4o",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :tool_use,
        timestamp: System.system_time(:millisecond)
      }

      tool_result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_abc|fc_123",
        tool_name: "read_file",
        content: [%TextContent{text: "File contents here"}],
        is_error: false,
        timestamp: System.system_time(:millisecond)
      }

      context =
        Context.new(messages: [%UserMessage{content: "Read file"}, assistant_msg, tool_result])

      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      # Find the function call output
      func_outputs =
        body["input"]
        |> Enum.filter(&(&1["type"] == "function_call_output"))

      assert length(func_outputs) == 1
      [output] = func_outputs
      assert output["call_id"] == "call_abc"
      assert output["output"] == "File contents here"

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # SSE Parsing Edge Cases Tests
  # ============================================================================

  describe "SSE parsing edge cases" do
    test "handles events with standard line endings" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Test response"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "id" => "msg_test",
            "content" => [%{"type" => "output_text", "text" => "Test response"}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      [%TextContent{text: text}] = result.content
      assert text == "Test response"
    end

    test "handles chunked events across multiple data frames" do
      events = [
        %{"type" => "response.output_item.added", "item" => %{"type" => "message"}},
        %{"type" => "response.output_text.delta", "delta" => "Chunk 1 "},
        %{"type" => "response.output_text.delta", "delta" => "Chunk 2"},
        %{
          "type" => "response.output_item.done",
          "item" => %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "Chunk 1 Chunk 2"}]
          }
        },
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 200, sse_body(events ++ [:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, result} = EventStream.result(stream, 2000)
      [%TextContent{text: text}] = result.content
      assert text == "Chunk 1 Chunk 2"
    end

    test "ignores [DONE] marker" do
      events = [
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        body = sse_body(events) <> "data: [DONE]\n\n"
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, _} = EventStream.result(stream, 2000)
    end

    test "handles empty events gracefully" do
      events = [
        %{"type" => "response.completed", "response" => %{"status" => "completed"}}
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        body = "data: \n\n" <> sse_body(events ++ [:done])
        Plug.Conn.send_resp(conn, 200, body)
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)
      assert {:ok, _} = EventStream.result(stream, 2000)
    end
  end

  # ============================================================================
  # API Key Environment Variable Tests
  # ============================================================================

  describe "API key from environment" do
    test "uses AZURE_OPENAI_API_KEY from environment" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_API_KEY", "env-api-key-123")

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      # No api_key in opts
      opts = %StreamOptions{}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["api-key"] == "env-api-key-123"

      System.delete_env("AZURE_OPENAI_API_KEY")
      EventStream.result(stream, 1000)
    end

    test "opts api_key takes precedence over environment" do
      test_pid = self()

      System.put_env("AZURE_OPENAI_API_KEY", "env-api-key")

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:request_headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      opts = %StreamOptions{api_key: "opts-api-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_headers, headers}, 1000
      headers_map = Map.new(headers)
      assert headers_map["api-key"] == "opts-api-key"

      System.delete_env("AZURE_OPENAI_API_KEY")
      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Complex Conversation Tests
  # ============================================================================

  describe "complex conversation handling" do
    test "handles multi-turn conversation" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()

      assistant1 = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{text: "First response", text_signature: "msg_1"}],
        api: :azure_openai_responses,
        provider: :"azure-openai-responses",
        model: "gpt-4o",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :stop,
        timestamp: 100
      }

      context =
        Context.new(
          system_prompt: "You are helpful",
          messages: [
            %UserMessage{content: "First message"},
            assistant1,
            %UserMessage{content: "Second message"}
          ]
        )

      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      # Should have system + 3 messages (user, assistant, user)
      assert length(body["input"]) >= 4

      EventStream.result(stream, 1000)
    end

    test "handles conversation with tool calls and results" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 200, sse_body([:done]))
      end)

      model = base_model()

      tool_call_msg = %AssistantMessage{
        role: :assistant,
        content: [
          %ToolCall{
            type: :tool_call,
            id: "call_abc|fc_123",
            name: "get_weather",
            arguments: %{"city" => "NYC"}
          }
        ],
        api: :azure_openai_responses,
        provider: :"azure-openai-responses",
        model: "gpt-4o",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :tool_use,
        timestamp: 100
      }

      tool_result = %ToolResultMessage{
        role: :tool_result,
        tool_call_id: "call_abc|fc_123",
        tool_name: "get_weather",
        content: [%TextContent{text: "Sunny, 75F"}],
        is_error: false,
        timestamp: 101
      }

      context =
        Context.new(
          messages: [
            %UserMessage{content: "What's the weather in NYC?"},
            tool_call_msg,
            tool_result
          ]
        )

      opts = %StreamOptions{api_key: "test-key"}

      {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

      assert_receive {:request_body, body}, 1000

      # Should include function_call and function_call_output
      func_calls =
        body["input"]
        |> Enum.filter(&(&1["type"] == "function_call"))

      func_outputs =
        body["input"]
        |> Enum.filter(&(&1["type"] == "function_call_output"))

      assert length(func_calls) == 1
      assert length(func_outputs) == 1

      EventStream.result(stream, 1000)
    end
  end

  # ============================================================================
  # Shared Module Integration Tests
  # ============================================================================

  describe "OpenAIResponsesShared integration" do
    test "tool conversion uses shared module" do
      tools = [
        %Tool{
          name: "test_tool",
          description: "A test tool",
          parameters: %{"type" => "object", "properties" => %{}}
        }
      ]

      converted = OpenAIResponsesShared.convert_tools(tools)
      assert [%{"type" => "function", "name" => "test_tool"}] = converted
    end

    test "short_hash produces consistent results" do
      hash1 = OpenAIResponsesShared.short_hash("test_string")
      hash2 = OpenAIResponsesShared.short_hash("test_string")
      assert hash1 == hash2
    end

    test "parse_streaming_json handles incomplete JSON" do
      result = OpenAIResponsesShared.parse_streaming_json("{\"key\": \"val")
      assert is_map(result)
    end

    test "service_tier_cost_multiplier returns correct values" do
      assert OpenAIResponsesShared.service_tier_cost_multiplier("flex") == 0.5
      assert OpenAIResponsesShared.service_tier_cost_multiplier("priority") == 2.0
      assert OpenAIResponsesShared.service_tier_cost_multiplier(nil) == 1.0
    end
  end
end
