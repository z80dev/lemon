defmodule Ai.ProviderIntegrationTest do
  @moduledoc """
  Provider-agnostic integration tests for the AI library.

  These tests make real API calls to whatever provider is configured.
  Configuration is done via environment variables - see Ai.Test.IntegrationConfig.

  ## Running Tests

      # With Kimi (default when using .env.kimi)
      source .env.kimi && mix test apps/ai/test/provider_integration_test.exs --include integration

      # With Anthropic
      INTEGRATION_API_KEY=sk-ant-... \\
      INTEGRATION_PROVIDER=anthropic \\
      INTEGRATION_MODEL=claude-3-5-haiku-20241022 \\
      INTEGRATION_BASE_URL=https://api.anthropic.com \\
      mix test apps/ai/test/provider_integration_test.exs --include integration

  Note: These tests make real API calls and may incur costs.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ai.Types.{AssistantMessage, Context, Tool, ToolCall, Usage}
  alias Ai.EventStream
  alias Ai.Test.IntegrationConfig

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    # Ensure provider registry is initialized
    Ai.ProviderRegistry.init()
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
    Ai.ProviderRegistry.register(:openai_completions, Ai.Providers.OpenAICompletions)
    Ai.ProviderRegistry.register(:google_generative_ai, Ai.Providers.Google)

    IO.puts("\n[Integration Tests] Configuration: #{IntegrationConfig.describe()}")
    :ok
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp skip_unless_configured do
    unless IntegrationConfig.configured?() do
      IO.puts(IntegrationConfig.skip_message())
      :skip
    else
      :ok
    end
  end

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
    test "completes a simple prompt" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()

          context =
            Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
            |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

          result = Ai.complete(model, context, %{max_tokens: 50})

          assert {:ok, message} = result
          assert %AssistantMessage{} = message
          assert message.stop_reason == :stop
          assert message.model == model.id
          assert message.api == model.api
          assert message.provider == model.provider

          text = Ai.get_text(message)
          assert text != ""
          assert String.contains?(text, "4")

          # Verify usage tracking
          assert %Usage{} = message.usage
          assert message.usage.input > 0
      end
    end

    test "handles multi-turn conversation" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()

          # First turn
          context =
            Context.new(system_prompt: "You are a helpful assistant. Be brief.")
            |> Context.add_user_message("My name is Alice.")

          {:ok, first_response} = Ai.complete(model, context, %{max_tokens: 100})
          assert %AssistantMessage{} = first_response

          # Second turn - model should remember the name
          context =
            context
            |> Context.add_assistant_message(first_response)
            |> Context.add_user_message("What is my name?")

          {:ok, second_response} = Ai.complete(model, context, %{max_tokens: 100})
          assert %AssistantMessage{} = second_response

          text = Ai.get_text(second_response)
          assert String.downcase(text) =~ "alice"
      end
    end
  end

  # ============================================================================
  # Streaming Tests
  # ============================================================================

  describe "Streaming" do
    test "streams responses with correct events" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()

          context =
            Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
            |> Context.add_user_message("Say 'hello world' and nothing else.")

          {:ok, stream} = Ai.stream(model, context, %{max_tokens: 50})

          events = EventStream.events(stream) |> Enum.to_list()

          # Should have start, text events, and done
          assert length(events) > 0

          # Check for start event
          start_events = Enum.filter(events, &match?({:start, _}, &1))
          assert length(start_events) == 1

          # Check for text deltas
          text_deltas = Enum.filter(events, &match?({:text_delta, _, _, _}, &1))
          assert length(text_deltas) > 0

          # Check for done event
          done_events = Enum.filter(events, &match?({:done, _, _}, &1))
          assert length(done_events) == 1

          # Collect text from deltas
          collected_text =
            text_deltas
            |> Enum.map(fn {:text_delta, _idx, delta, _partial} -> delta end)
            |> Enum.join("")

          assert String.downcase(collected_text) =~ "hello"
      end
    end

    test "stream result returns final message" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()

          context =
            Context.new(system_prompt: "Be brief.")
            |> Context.add_user_message("Say hi.")

          {:ok, stream} = Ai.stream(model, context, %{max_tokens: 50})

          result = EventStream.result(stream, 30_000)

          assert {:ok, message} = result
          assert %AssistantMessage{} = message
          assert message.stop_reason == :stop
      end
    end
  end

  # ============================================================================
  # Tool Calling Tests
  # ============================================================================

  describe "Tool Calling" do
    test "handles tool calling" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()
          tool = get_weather_tool()

          context =
            Context.new(
              system_prompt:
                "You are a helpful assistant. Use the get_weather tool when asked about weather.",
              tools: [tool]
            )
            |> Context.add_user_message("What's the weather in Tokyo?")

          {:ok, message} = Ai.complete(model, context, %{max_tokens: 200})

          assert %AssistantMessage{} = message
          assert message.stop_reason == :tool_use

          tool_calls = Ai.get_tool_calls(message)
          assert length(tool_calls) > 0

          [tool_call | _] = tool_calls
          assert %ToolCall{} = tool_call
          assert tool_call.name == "get_weather"
          assert is_map(tool_call.arguments)
          assert Map.has_key?(tool_call.arguments, "location")
      end
    end

    test "streams tool calls correctly" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()
          tool = get_weather_tool()

          context =
            Context.new(
              system_prompt: "Use the get_weather tool when asked about weather.",
              tools: [tool]
            )
            |> Context.add_user_message("What's the weather in Paris?")

          {:ok, stream} = Ai.stream(model, context, %{max_tokens: 200})

          events = EventStream.events(stream) |> Enum.to_list()

          # Should have tool call events
          tool_call_starts = Enum.filter(events, &match?({:tool_call_start, _, _}, &1))
          tool_call_ends = Enum.filter(events, &match?({:tool_call_end, _, _, _}, &1))

          assert length(tool_call_starts) > 0
          assert length(tool_call_ends) > 0
      end
    end
  end

  # ============================================================================
  # Usage Tracking Tests
  # ============================================================================

  describe "Usage Tracking" do
    test "tracks input and output tokens" do
      case skip_unless_configured() do
        :skip ->
          assert true

        :ok ->
          model = IntegrationConfig.model()

          context =
            Context.new(system_prompt: "Be brief.")
            |> Context.add_user_message("Hi")

          {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

          assert %Usage{} = message.usage
          assert message.usage.input > 0
          assert message.usage.total_tokens > 0
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "Error Handling" do
    test "handles invalid API key gracefully" do
      # This test doesn't need configuration - we use an invalid key intentionally
      model = %{IntegrationConfig.model() | provider: :test_invalid}

      context =
        Context.new(system_prompt: "Test")
        |> Context.add_user_message("Hello")

      {:ok, stream} = Ai.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

      result = EventStream.result(stream, 10_000)

      assert {:error, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :error
      assert message.error_message != nil
    end
  end
end
