defmodule AiTest do
  use ExUnit.Case

  alias Ai.EventStream
  alias Ai.ProviderRegistry

  alias Ai.Types.{
    Context,
    UserMessage,
    TextContent,
    AssistantMessage,
    Usage,
    Cost,
    Model,
    StreamOptions
  }

  defmodule StreamTimeoutProvider do
    @behaviour Ai.Provider

    @impl true
    def api_id, do: :stream_timeout_test

    @impl true
    def provider_id, do: :test

    @impl true
    def stream(_model, _context, %StreamOptions{} = opts) do
      send(self(), {:received_opts, opts})
      EventStream.start_link()
    end
  end

  defmodule ImmediateProvider do
    @behaviour Ai.Provider

    @impl true
    def api_id, do: :immediate_test

    @impl true
    def provider_id, do: :test

    @impl true
    def stream(_model, _context, %StreamOptions{}) do
      {:ok, stream} = EventStream.start_link()

      output = %AssistantMessage{
        role: :assistant,
        content: [%TextContent{text: "ok"}],
        api: :immediate_test,
        provider: :test,
        model: "test",
        usage: %Usage{cost: %Cost{}},
        stop_reason: :stop,
        timestamp: System.system_time(:millisecond)
      }

      EventStream.complete(stream, output)
      {:ok, stream}
    end
  end

  describe "Context" do
    test "creates empty context" do
      ctx = Context.new()
      assert ctx.system_prompt == nil
      assert ctx.messages == []
      assert ctx.tools == []
    end

    test "creates context with system prompt" do
      ctx = Context.new(system_prompt: "You are helpful")
      assert ctx.system_prompt == "You are helpful"
    end

    test "adds user message" do
      ctx =
        Context.new()
        |> Context.add_user_message("Hello!")

      assert length(ctx.messages) == 1
      [msg] = ctx.messages
      assert %UserMessage{} = msg
      assert msg.content == "Hello!"
      assert msg.timestamp > 0
    end
  end

  describe "get_text/1" do
    test "extracts text from assistant message" do
      message = %AssistantMessage{
        content: [
          %TextContent{text: "Hello "},
          %TextContent{text: "world!"}
        ],
        api: :test,
        provider: :test,
        model: "test",
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: 0
      }

      assert Ai.get_text(message) == "Hello world!"
    end

    test "returns empty string for no text content" do
      message = %AssistantMessage{
        content: [],
        api: :test,
        provider: :test,
        model: "test",
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: 0
      }

      assert Ai.get_text(message) == ""
    end
  end

  describe "get_thinking/1" do
    test "extracts thinking from assistant message" do
      message = %AssistantMessage{
        content: [
          %Ai.Types.ThinkingContent{thinking: "Step one."},
          %Ai.Types.ThinkingContent{thinking: "Step two."}
        ],
        api: :test,
        provider: :test,
        model: "test",
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: 0
      }

      assert Ai.get_thinking(message) == "Step one.Step two."
    end

    test "returns empty string for no thinking content" do
      message = %AssistantMessage{
        content: [],
        api: :test,
        provider: :test,
        model: "test",
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: 0
      }

      assert Ai.get_thinking(message) == ""
    end
  end

  describe "get_tool_calls/1" do
    test "extracts tool calls from assistant message" do
      tool_call = %Ai.Types.ToolCall{id: "call_1", name: "tool_a", arguments: %{"a" => 1}}

      message = %AssistantMessage{
        content: [
          %TextContent{text: "Hello"},
          tool_call
        ],
        api: :test,
        provider: :test,
        model: "test",
        usage: %Usage{},
        stop_reason: :stop,
        timestamp: 0
      }

      assert Ai.get_tool_calls(message) == [tool_call]
    end
  end

  describe "calculate_cost/2" do
    test "calculates cost correctly" do
      model = %Ai.Types.Model{
        id: "test-model",
        name: "Test Model",
        api: :test,
        provider: :test,
        base_url: "https://example.com",
        cost: %Ai.Types.ModelCost{
          input: 3.0,
          output: 15.0,
          cache_read: 0.3,
          cache_write: 3.75
        }
      }

      usage = %Usage{
        input: 1000,
        output: 500,
        cache_read: 200,
        cache_write: 100,
        total_tokens: 1800,
        cost: %Cost{}
      }

      cost = Ai.calculate_cost(model, usage)

      # 1000 * 3.0 / 1_000_000 = 0.003
      assert_in_delta cost.input, 0.003, 0.0001
      # 500 * 15.0 / 1_000_000 = 0.0075
      assert_in_delta cost.output, 0.0075, 0.0001
      # 200 * 0.3 / 1_000_000 = 0.00006
      assert_in_delta cost.cache_read, 0.00006, 0.00001
      # 100 * 3.75 / 1_000_000 = 0.000375
      assert_in_delta cost.cache_write, 0.000375, 0.0001
    end
  end

  describe "stream options normalization" do
    test "accepts keyword list options and preserves defaults" do
      ProviderRegistry.register(:stream_timeout_test, StreamTimeoutProvider)
      on_exit(fn -> ProviderRegistry.unregister(:stream_timeout_test) end)

      model = %Model{
        id: "test",
        name: "Test",
        api: :stream_timeout_test,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      {:ok, stream} = Ai.stream(model, context, temperature: 0.5)

      assert_receive {:received_opts,
                      %StreamOptions{
                        temperature: 0.5,
                        stream_timeout: 300_000,
                        headers: %{},
                        thinking_budgets: %{}
                      }},
                     1000

      EventStream.cancel(stream, :test_cleanup)
    end

    test "propagates stream_timeout to providers" do
      ProviderRegistry.register(:stream_timeout_test, StreamTimeoutProvider)
      on_exit(fn -> ProviderRegistry.unregister(:stream_timeout_test) end)

      model = %Model{
        id: "test",
        name: "Test",
        api: :stream_timeout_test,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      {:ok, stream} = Ai.stream(model, context, %{stream_timeout: 12_345})

      assert_receive {:received_opts, %StreamOptions{stream_timeout: 12_345}}, 1000

      EventStream.cancel(stream, :test_cleanup)
    end

    test "propagates provider-specific options to providers" do
      ProviderRegistry.register(:stream_timeout_test, StreamTimeoutProvider)
      on_exit(fn -> ProviderRegistry.unregister(:stream_timeout_test) end)

      model = %Model{
        id: "test",
        name: "Test",
        api: :stream_timeout_test,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      {:ok, stream} =
        Ai.stream(model, context, %{
          tool_choice: :none,
          project: "demo-project",
          location: "us-central1",
          access_token: "test-token"
        })

      assert_receive {:received_opts,
                      %StreamOptions{
                        tool_choice: :none,
                        project: "demo-project",
                        location: "us-central1",
                        access_token: "test-token"
                      }},
                     1000

      EventStream.cancel(stream, :test_cleanup)
    end

    test "drops unknown options before passing to provider" do
      ProviderRegistry.register(:stream_timeout_test, StreamTimeoutProvider)
      on_exit(fn -> ProviderRegistry.unregister(:stream_timeout_test) end)

      model = %Model{
        id: "test",
        name: "Test",
        api: :stream_timeout_test,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      {:ok, stream} =
        Ai.stream(model, context, %{
          temperature: 0.9,
          unknown_option: "nope"
        })

      assert_receive {:received_opts, %StreamOptions{} = opts}, 1000
      refute Map.has_key?(Map.from_struct(opts), :unknown_option)

      EventStream.cancel(stream, :test_cleanup)
    end
  end

  describe "dispatcher integration" do
    test "returns rate_limited when dispatcher blocks the request" do
      ProviderRegistry.register(:stream_timeout_test, StreamTimeoutProvider)
      on_exit(fn -> ProviderRegistry.unregister(:stream_timeout_test) end)

      provider = :rate_limit_test

      start_supervised!({Ai.RateLimiter, provider: provider, tokens_per_second: 0, max_tokens: 1})
      start_supervised!({Ai.CircuitBreaker, provider: provider, failure_threshold: 5})

      # Consume the single token so the next request is rate-limited.
      assert :ok = Ai.RateLimiter.acquire(provider)

      model = %Model{
        id: "test",
        name: "Test",
        api: :stream_timeout_test,
        provider: provider,
        base_url: "https://example.com"
      }

      context = Context.new()

      assert {:error, :rate_limited} = Ai.stream(model, context)
      refute_receive {:received_opts, _opts}
    end
  end

  describe "unknown api handling" do
    test "returns unknown_api error for unregistered providers" do
      model = %Model{
        id: "test",
        name: "Test",
        api: :unknown_api,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      assert {:error, {:unknown_api, :unknown_api}} = Ai.stream(model, context)
    end
  end

  describe "complete/3" do
    test "returns final message from provider stream" do
      ProviderRegistry.register(:immediate_test, ImmediateProvider)
      on_exit(fn -> ProviderRegistry.unregister(:immediate_test) end)

      model = %Model{
        id: "test",
        name: "Test",
        api: :immediate_test,
        provider: :test,
        base_url: "https://example.com"
      }

      context = Context.new()

      assert {:ok, %AssistantMessage{} = message} = Ai.complete(model, context)
      assert Ai.get_text(message) == "ok"
    end
  end
end
