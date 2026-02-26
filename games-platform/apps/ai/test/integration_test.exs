defmodule Ai.IntegrationTest do
  @moduledoc """
  Integration tests for the AI library that make actual API calls.

  These tests are excluded by default. To run them:

      # Run all integration tests
      mix test --include integration

      # Run tests for a specific provider
      mix test --include integration --only provider:anthropic
      mix test --include integration --only provider:openai
      mix test --include integration --only provider:google

      # Run all tests including integration
      mix test --include integration

  Required environment variables:
    - ANTHROPIC_API_KEY for Anthropic tests
    - OPENAI_API_KEY for OpenAI tests
    - GEMINI_API_KEY or GOOGLE_API_KEY or GOOGLE_GENERATIVE_AI_API_KEY for Google tests

  Note: These tests make real API calls and may incur costs.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias Ai.Types.{
    AssistantMessage,
    Context,
    Model,
    ModelCost,
    Tool,
    ToolCall,
    Usage
  }

  alias Ai.EventStream

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp ensure_registry_started do
    # Initialize the registry (uses persistent_term, safe to call multiple times)
    Ai.ProviderRegistry.init()

    # Register the providers
    Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
    Ai.ProviderRegistry.register(:openai_completions, Ai.Providers.OpenAICompletions)
    Ai.ProviderRegistry.register(:google_generative_ai, Ai.Providers.Google)
  end

  defp anthropic_model do
    %Model{
      id: "claude-3-5-haiku-20241022",
      name: "Claude 3.5 Haiku",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 1.0, output: 5.0, cache_read: 0.1, cache_write: 1.25},
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{}
    }
  end

  defp openai_model do
    %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o Mini",
      api: :openai_completions,
      provider: :openai,
      base_url: "https://api.openai.com/v1",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.15, output: 0.60, cache_read: 0.075, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 16_384,
      headers: %{}
    }
  end

  defp google_model do
    %Model{
      id: "gemini-2.0-flash",
      name: "Gemini 2.0 Flash",
      api: :google_generative_ai,
      provider: :google,
      base_url: "https://generativelanguage.googleapis.com/v1beta",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.10, output: 0.40, cache_read: 0.025, cache_write: 0.0},
      context_window: 1_000_000,
      max_tokens: 8192,
      headers: %{}
    }
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

  defp has_anthropic_key?, do: System.get_env("ANTHROPIC_API_KEY") not in [nil, ""]
  defp has_openai_key?, do: System.get_env("OPENAI_API_KEY") not in [nil, ""]

  defp has_google_key? do
    (System.get_env("GEMINI_API_KEY") ||
       System.get_env("GOOGLE_API_KEY") ||
       System.get_env("GOOGLE_GENERATIVE_AI_API_KEY")) not in [nil, ""]
  end

  defp has_kimi_key?, do: System.get_env("ANTHROPIC_API_KEY") not in [nil, ""]

  defp kimi_model do
    %Model{
      id: "kimi-for-coding",
      name: "Kimi for Coding",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: "https://api.kimi.com/coding",
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 256_000,
      max_tokens: 64_000,
      headers: %{}
    }
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup_all do
    ensure_registry_started()
    :ok
  end

  # ============================================================================
  # Anthropic Tests
  # ============================================================================

  describe "Anthropic" do
    @describetag provider: :anthropic

    @tag :anthropic
    test "completes a simple prompt" do
      unless has_anthropic_key?() do
        IO.puts("Skipping Anthropic test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = anthropic_model()

        context =
          Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
          |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 50})

        assert %AssistantMessage{} = message
        assert message.stop_reason == :stop
        assert message.model == model.id
        assert message.api == :anthropic_messages
        assert message.provider == :anthropic

        text = Ai.get_text(message)
        assert text != ""
        assert String.contains?(text, "4")

        # Verify usage tracking
        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
      end
    end

    @tag :anthropic
    test "streams responses" do
      unless has_anthropic_key?() do
        IO.puts("Skipping Anthropic test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = anthropic_model()

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

    @tag :anthropic
    test "handles tool calling" do
      unless has_anthropic_key?() do
        IO.puts("Skipping Anthropic test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = anthropic_model()
        tool = get_weather_tool()

        context =
          Context.new(
            system_prompt:
              "You are a helpful assistant. Use the get_weather tool when asked about weather.",
            tools: [tool]
          )
          |> Context.add_user_message("What's the weather in Paris?")

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

    @tag :anthropic
    test "tracks usage/tokens" do
      unless has_anthropic_key?() do
        IO.puts("Skipping Anthropic test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = anthropic_model()

        context =
          Context.new(system_prompt: "Be brief.")
          |> Context.add_user_message("Hi")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
        assert message.usage.total_tokens > 0

        # Cost should be calculated
        assert message.usage.cost.total >= 0
      end
    end
  end

  # ============================================================================
  # OpenAI Tests
  # ============================================================================

  describe "OpenAI" do
    @describetag provider: :openai

    @tag :openai
    test "completes a simple prompt" do
      unless has_openai_key?() do
        IO.puts("Skipping OpenAI test: OPENAI_API_KEY not set")
        assert true
      else
        model = openai_model()

        context =
          Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
          |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 50})

        assert %AssistantMessage{} = message
        assert message.stop_reason == :stop
        assert message.model == model.id
        assert message.api == :openai_completions
        assert message.provider == :openai

        text = Ai.get_text(message)
        assert text != ""
        assert String.contains?(text, "4")

        # Verify usage tracking
        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
      end
    end

    @tag :openai
    test "streams responses" do
      unless has_openai_key?() do
        IO.puts("Skipping OpenAI test: OPENAI_API_KEY not set")
        assert true
      else
        model = openai_model()

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

    @tag :openai
    test "handles tool calling" do
      unless has_openai_key?() do
        IO.puts("Skipping OpenAI test: OPENAI_API_KEY not set")
        assert true
      else
        model = openai_model()
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

    @tag :openai
    test "tracks usage/tokens" do
      unless has_openai_key?() do
        IO.puts("Skipping OpenAI test: OPENAI_API_KEY not set")
        assert true
      else
        model = openai_model()

        context =
          Context.new(system_prompt: "Be brief.")
          |> Context.add_user_message("Hi")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
        assert message.usage.total_tokens > 0
      end
    end
  end

  # ============================================================================
  # Google (Gemini) Tests
  # ============================================================================

  describe "Google" do
    @describetag provider: :google

    @tag :google
    test "completes a simple prompt" do
      unless has_google_key?() do
        IO.puts("Skipping Google test: GEMINI_API_KEY/GOOGLE_API_KEY not set")
        assert true
      else
        model = google_model()

        context =
          Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
          |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 50})

        assert %AssistantMessage{} = message
        assert message.stop_reason == :stop
        assert message.model == model.id
        assert message.api == :google_generative_ai
        assert message.provider == :google

        text = Ai.get_text(message)
        assert text != ""
        assert String.contains?(text, "4")

        # Verify usage tracking
        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
      end
    end

    @tag :google
    test "streams responses" do
      unless has_google_key?() do
        IO.puts("Skipping Google test: GEMINI_API_KEY/GOOGLE_API_KEY not set")
        assert true
      else
        model = google_model()

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

    @tag :google
    test "handles tool calling" do
      unless has_google_key?() do
        IO.puts("Skipping Google test: GEMINI_API_KEY/GOOGLE_API_KEY not set")
        assert true
      else
        model = google_model()
        tool = get_weather_tool()

        context =
          Context.new(
            system_prompt:
              "You are a helpful assistant. Use the get_weather tool when asked about weather.",
            tools: [tool]
          )
          |> Context.add_user_message("What's the weather in London?")

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

    @tag :google
    test "tracks usage/tokens" do
      unless has_google_key?() do
        IO.puts("Skipping Google test: GEMINI_API_KEY/GOOGLE_API_KEY not set")
        assert true
      else
        model = google_model()

        context =
          Context.new(system_prompt: "Be brief.")
          |> Context.add_user_message("Hi")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.output > 0
        assert message.usage.total_tokens > 0
      end
    end
  end

  # ============================================================================
  # Kimi Tests (Anthropic-compatible API)
  # ============================================================================

  describe "Kimi" do
    @describetag provider: :kimi

    @tag :kimi
    test "completes a simple prompt" do
      unless has_kimi_key?() do
        IO.puts("Skipping Kimi test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = kimi_model()

        context =
          Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
          |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 50})

        assert %AssistantMessage{} = message
        assert message.stop_reason == :stop
        assert message.model == model.id
        assert message.api == :anthropic_messages
        assert message.provider == :kimi

        text = Ai.get_text(message)
        assert text != ""
        assert String.contains?(text, "4")

        # Verify usage tracking
        assert %Usage{} = message.usage
        assert message.usage.input > 0
      end
    end

    @tag :kimi
    test "streams responses" do
      unless has_kimi_key?() do
        IO.puts("Skipping Kimi test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = kimi_model()

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

    @tag :kimi
    test "handles tool calling" do
      unless has_kimi_key?() do
        IO.puts("Skipping Kimi test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = kimi_model()
        tool = get_weather_tool()

        context =
          Context.new(
            system_prompt:
              "You are a helpful assistant. Use the get_weather tool when asked about weather.",
            tools: [tool]
          )
          |> Context.add_user_message("What's the weather in Berlin?")

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

    @tag :kimi
    test "tracks usage/tokens" do
      unless has_kimi_key?() do
        IO.puts("Skipping Kimi test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = kimi_model()

        context =
          Context.new(system_prompt: "Be brief.")
          |> Context.add_user_message("Hi")

        {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

        assert %Usage{} = message.usage
        assert message.usage.input > 0
        assert message.usage.total_tokens > 0
      end
    end

    @tag :kimi
    test "handles multi-turn conversation" do
      unless has_kimi_key?() do
        IO.puts("Skipping Kimi test: ANTHROPIC_API_KEY not set")
        assert true
      else
        model = kimi_model()

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
  # Cross-Provider Tests
  # ============================================================================

  describe "Cross-provider consistency" do
    @describetag provider: :all

    @tag :cross_provider
    test "all available providers return consistent AssistantMessage structure" do
      models = []

      models =
        if has_anthropic_key?() do
          [{:anthropic, anthropic_model()} | models]
        else
          models
        end

      models =
        if has_openai_key?() do
          [{:openai, openai_model()} | models]
        else
          models
        end

      models =
        if has_google_key?() do
          [{:google, google_model()} | models]
        else
          models
        end

      models =
        if has_kimi_key?() do
          [{:kimi, kimi_model()} | models]
        else
          models
        end

      if length(models) < 2 do
        IO.puts("Skipping cross-provider test: Need at least 2 API keys set")
        assert true
      else
        context =
          Context.new(system_prompt: "Be very brief.")
          |> Context.add_user_message("Say 'test'")

        for {provider_name, model} <- models do
          {:ok, message} = Ai.complete(model, context, %{max_tokens: 20})

          assert %AssistantMessage{} = message,
                 "#{provider_name} should return AssistantMessage"

          assert message.role == :assistant,
                 "#{provider_name} message role should be :assistant"

          assert is_list(message.content),
                 "#{provider_name} message content should be a list"

          assert message.stop_reason in [:stop, :length, :tool_use, :error],
                 "#{provider_name} should have valid stop_reason"

          assert %Usage{} = message.usage,
                 "#{provider_name} should include usage"

          assert message.usage.input >= 0,
                 "#{provider_name} input tokens should be >= 0"

          assert message.usage.output >= 0,
                 "#{provider_name} output tokens should be >= 0"
        end
      end
    end

    @tag :cross_provider
    test "all available providers emit consistent stream events" do
      models = []

      models =
        if has_anthropic_key?() do
          [{:anthropic, anthropic_model()} | models]
        else
          models
        end

      models =
        if has_openai_key?() do
          [{:openai, openai_model()} | models]
        else
          models
        end

      models =
        if has_google_key?() do
          [{:google, google_model()} | models]
        else
          models
        end

      models =
        if has_kimi_key?() do
          [{:kimi, kimi_model()} | models]
        else
          models
        end

      if length(models) < 2 do
        IO.puts("Skipping cross-provider test: Need at least 2 API keys set")
        assert true
      else
        context =
          Context.new(system_prompt: "Be very brief.")
          |> Context.add_user_message("Say 'ok'")

        for {provider_name, model} <- models do
          {:ok, stream} = Ai.stream(model, context, %{max_tokens: 20})
          events = EventStream.events(stream) |> Enum.to_list()

          # All providers should emit :start
          start_events = Enum.filter(events, &match?({:start, _}, &1))

          assert length(start_events) == 1,
                 "#{provider_name} should emit exactly one :start event"

          # All providers should emit :done or :error
          terminal_events =
            Enum.filter(events, fn e ->
              match?({:done, _, _}, e) or match?({:error, _, _}, e)
            end)

          assert length(terminal_events) == 1,
                 "#{provider_name} should emit exactly one terminal event"

          # Should have some content events (text_delta, text_start, etc.)
          content_events =
            Enum.filter(events, fn e ->
              match?({:text_delta, _, _, _}, e) or
                match?({:text_start, _, _}, e) or
                match?({:text_end, _, _, _}, e)
            end)

          assert length(content_events) > 0,
                 "#{provider_name} should emit content events"
        end
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "Error handling" do
    @describetag provider: :error_handling

    @tag :error_handling
    test "handles invalid API key gracefully for Anthropic" do
      model = %Model{
        id: "claude-3-5-haiku-20241022",
        name: "Claude 3.5 Haiku",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://api.anthropic.com",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{},
        context_window: 200_000,
        max_tokens: 8192,
        headers: %{}
      }

      context =
        Context.new(system_prompt: "Test")
        |> Context.add_user_message("Hello")

      {:ok, stream} = Ai.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

      # Wait for the request to complete and get result
      # Use a longer timeout to ensure the API call completes
      result = EventStream.result(stream, 10_000)

      assert {:error, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :error
      assert message.error_message != nil
    end

    @tag :error_handling
    test "handles invalid API key gracefully for OpenAI" do
      model = %Model{
        id: "gpt-4o-mini",
        name: "GPT-4o Mini",
        api: :openai_completions,
        provider: :openai,
        base_url: "https://api.openai.com/v1",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{},
        context_window: 128_000,
        max_tokens: 16_384,
        headers: %{}
      }

      context =
        Context.new(system_prompt: "Test")
        |> Context.add_user_message("Hello")

      {:ok, stream} = Ai.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

      # Wait for the request to complete and get result
      result = EventStream.result(stream, 10_000)

      assert {:error, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :error
      assert message.error_message != nil
    end

    @tag :error_handling
    test "handles invalid API key gracefully for Google" do
      model = %Model{
        id: "gemini-2.0-flash",
        name: "Gemini 2.0 Flash",
        api: :google_generative_ai,
        provider: :google,
        base_url: "https://generativelanguage.googleapis.com/v1beta",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{},
        context_window: 1_000_000,
        max_tokens: 8192,
        headers: %{}
      }

      context =
        Context.new(system_prompt: "Test")
        |> Context.add_user_message("Hello")

      {:ok, stream} = Ai.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

      # Wait for the request to complete and get result
      result = EventStream.result(stream, 10_000)

      assert {:error, message} = result
      assert %AssistantMessage{} = message
      assert message.stop_reason == :error
      assert message.error_message != nil
    end
  end
end
