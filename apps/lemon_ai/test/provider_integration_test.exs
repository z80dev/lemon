defmodule LemonAi.ProviderIntegrationTest do
  @moduledoc """
  Provider-agnostic integration tests for the AI library.

  These tests make real API calls to whatever provider is configured.
  Configuration is done via environment variables - see LemonAi.Test.IntegrationConfig.
  Without that configuration the provider tests fail; only the invalid-key case
  (`provider: :error_handling`, a loopback fixture) runs unconfigured.

  ## Running Tests

      # With Kimi (default when using .env.kimi)
      source .env.kimi && LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \\
        scripts/test path apps/lemon_ai/test/provider_integration_test.exs --include integration

      # With Anthropic
      INTEGRATION_API_KEY=sk-ant-... \\
      INTEGRATION_PROVIDER=anthropic \\
      INTEGRATION_MODEL=claude-3-5-haiku-20241022 \\
      INTEGRATION_BASE_URL=https://api.anthropic.com \\
      LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1 \\
      scripts/test path apps/lemon_ai/test/provider_integration_test.exs --include integration

  Note: These tests make real API calls and may incur costs.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias LemonAi.Types.{AssistantMessage, Context, Tool, ToolCall, Usage}
  alias LemonAi.EventStream
  alias LemonAi.Test.IntegrationConfig
  alias LemonAi.Test.StreamServer

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    # Ensure provider registry is initialized
    LemonAi.ProviderRegistry.init()
    LemonAi.ProviderRegistry.register(:anthropic_messages, LemonAi.Providers.Anthropic)
    LemonAi.ProviderRegistry.register(:openai_completions, LemonAi.Providers.OpenAICompletions)
    LemonAi.ProviderRegistry.register(:google_generative_ai, LemonAi.Providers.Google)

    IO.puts("\n[Integration Tests] Configuration: #{IntegrationConfig.describe()}")
    :ok
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp get_weather_tool do
    %Tool{
      name: "get_weather",
      description: "Get the current weather for a location",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "location" => %{
            "type" => "string",
            "description" => "The city name"
          }
        },
        "required" => ["location"]
      }
    }
  end

  # ============================================================================
  # Basic Completion Tests
  # ============================================================================

  describe "Basic Completion" do
    setup do: IntegrationConfig.require_configured!()

    test "completes a simple prompt" do
      model = IntegrationConfig.model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

      result = LemonAi.complete(model, context, %{max_tokens: 50})

      assert {:ok, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
      assert message.model == model.id
      assert message.api == model.api
      assert message.provider == model.provider

      text = LemonAi.get_text(message)
      assert text != ""
      assert String.contains?(text, "4")

      # Verify usage tracking
      assert %Usage{} = message.usage
      assert message.usage.input > 0
    end

    test "handles multi-turn conversation" do
      model = IntegrationConfig.model()

      # First turn
      context =
        Context.new(system_prompt: "You are a helpful assistant. Be brief.")
        |> Context.add_user_message("My name is Alice.")

      {:ok, first_response} = LemonAi.complete(model, context, %{max_tokens: 100})
      assert %AssistantMessage{} = first_response

      # Second turn - model should remember the name
      context =
        context
        |> Context.add_assistant_message(first_response)
        |> Context.add_user_message("What is my name?")

      {:ok, second_response} = LemonAi.complete(model, context, %{max_tokens: 100})
      assert %AssistantMessage{} = second_response

      text = LemonAi.get_text(second_response)
      assert String.downcase(text) =~ "alice"
    end
  end

  # ============================================================================
  # Streaming Tests
  # ============================================================================

  describe "Streaming" do
    setup do: IntegrationConfig.require_configured!()

    test "streams responses with correct events" do
      model = IntegrationConfig.model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("Say 'hello world' and nothing else.")

      {:ok, stream} = LemonAi.stream(model, context, %{max_tokens: 50})

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have start, text events, and done
      assert events != []

      # Check for start event
      start_events = Enum.filter(events, &match?({:start, _}, &1))
      assert length(start_events) == 1

      # Check for text deltas
      text_deltas = Enum.filter(events, &match?({:text_delta, _, _}, &1))
      assert text_deltas != []

      # Check for done event
      done_events = Enum.filter(events, &match?({:done, _, _}, &1))
      assert length(done_events) == 1

      # Collect text from deltas
      collected_text =
        text_deltas
        |> Enum.map(fn {:text_delta, _idx, delta} -> delta end)
        |> Enum.join("")

      assert String.downcase(collected_text) =~ "hello"
    end

    test "stream result returns final message" do
      model = IntegrationConfig.model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Say hi.")

      {:ok, stream} = LemonAi.stream(model, context, %{max_tokens: 50})

      result = EventStream.result(stream, 30_000)

      assert {:ok, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
    end
  end

  # ============================================================================
  # Tool Calling Tests
  # ============================================================================

  describe "Tool Calling" do
    setup do: IntegrationConfig.require_configured!()

    test "handles tool calling" do
      model = IntegrationConfig.model()
      tool = get_weather_tool()

      context =
        Context.new(
          system_prompt:
            "You are a helpful assistant. Use the get_weather tool when asked about weather.",
          tools: [tool]
        )
        |> Context.add_user_message("What's the weather in Tokyo?")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 200})

      assert %AssistantMessage{} = message
      assert message.stop_reason == :tool_use

      tool_calls = LemonAi.get_tool_calls(message)
      assert tool_calls != []

      [tool_call | _] = tool_calls
      assert %ToolCall{} = tool_call
      assert tool_call.name == "get_weather"
      assert is_map(tool_call.arguments)
      assert Map.has_key?(tool_call.arguments, "location")
    end

    test "streams tool calls correctly" do
      model = IntegrationConfig.model()
      tool = get_weather_tool()

      context =
        Context.new(
          system_prompt: "Use the get_weather tool when asked about weather.",
          tools: [tool]
        )
        |> Context.add_user_message("What's the weather in Paris?")

      {:ok, stream} = LemonAi.stream(model, context, %{max_tokens: 200})

      events = EventStream.events(stream) |> Enum.to_list()

      # Should have tool call events
      tool_call_starts = Enum.filter(events, &match?({:tool_call_start, _, _}, &1))
      tool_call_ends = Enum.filter(events, &match?({:tool_call_end, _, _}, &1))

      assert tool_call_starts != []
      assert tool_call_ends != []
    end
  end

  # ============================================================================
  # Usage Tracking Tests
  # ============================================================================

  describe "Usage Tracking" do
    setup do: IntegrationConfig.require_configured!()

    test "tracks input and output tokens" do
      model = IntegrationConfig.model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Hi")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.total_tokens > 0
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  # Offline: a loopback fixture rejects the key with 401, so this needs neither
  # network nor credentials (nightly `integration` job).
  describe "Error Handling" do
    @describetag provider: :error_handling

    test "reports a rejected API key as an error" do
      server =
        StreamServer.start(fn _n ->
          [{:status, 401, ~s({"error":{"message":"invalid api key"}})}]
        end)

      on_exit(fn -> StreamServer.stop(server) end)
      model = %{IntegrationConfig.model() | provider: :test_invalid, base_url: server.url}

      context =
        Context.new(system_prompt: "Test")
        |> Context.add_user_message("Hello")

      {:ok, stream} = LemonAi.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

      assert {:error, %AssistantMessage{} = message} = EventStream.result(stream, 10_000)
      assert message.stop_reason == :error
      assert message.error_message =~ ~r/401|invalid api key/i
      assert_received {:stream_server, :request, 0, %{body: body}}
      assert body =~ "Hello"
    end
  end
end
