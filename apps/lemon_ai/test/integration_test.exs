defmodule LemonAi.IntegrationTest do
  @moduledoc """
  Integration tests for the AI library that make actual API calls.

  These tests are excluded by default. A selected provider test fails, rather
  than passes, when its credential is missing, so select only the configured
  providers (`--only` includes the selected tests despite the `:integration`
  exclude):

      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:anthropic
      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:openai
      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:google
      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:kimi

      # Two or more configured providers
      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:all

      # Invalid-key handling against a loopback fixture; no network or credentials
      scripts/test path apps/lemon_ai/test/integration_test.exs --only provider:error_handling

  `scripts/test` scrubs provider credentials unless
  `LEMON_TEST_ALLOW_LIVE_CREDENTIALS=1` is set. Required environment variables:
    - ANTHROPIC_API_KEY for Anthropic tests
    - OPENAI_API_KEY for OpenAI tests
    - GEMINI_API_KEY or GOOGLE_API_KEY or GOOGLE_GENERATIVE_AI_API_KEY for Google tests
    - KIMI_API_KEY or MOONSHOT_API_KEY for Kimi tests

  Note: These tests make real API calls and may incur costs.
  """

  use ExUnit.Case, async: false

  @moduletag :integration

  alias LemonAi.Types.{
    AssistantMessage,
    Context,
    Model,
    ModelCost,
    Tool,
    ToolCall,
    Usage
  }

  alias LemonAi.EventStream
  alias LemonAi.Test.StreamServer

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp ensure_registry_started do
    # Initialize the registry (uses persistent_term, safe to call multiple times)
    LemonAi.ProviderRegistry.init()

    # Register the providers
    LemonAi.ProviderRegistry.register(:anthropic_messages, LemonAi.Providers.Anthropic)
    LemonAi.ProviderRegistry.register(:openai_completions, LemonAi.Providers.OpenAICompletions)
    LemonAi.ProviderRegistry.register(:google_generative_ai, LemonAi.Providers.Google)
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

  @provider_env [
    anthropic: ["ANTHROPIC_API_KEY"],
    openai: ["OPENAI_API_KEY"],
    google: ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENERATIVE_AI_API_KEY"],
    kimi: ["KIMI_API_KEY", "MOONSHOT_API_KEY"]
  ]

  defp configured?(provider) do
    @provider_env |> Keyword.fetch!(provider) |> Enum.any?(&(System.get_env(&1) not in [nil, ""]))
  end

  # A selected live test without its credential fails; it never passes vacuously.
  defp require_provider!(provider) do
    unless configured?(provider) do
      vars = @provider_env |> Keyword.fetch!(provider) |> Enum.join(" or ")
      flunk("#{provider} live test requires #{vars}; select configured providers with --only")
    end

    :ok
  end

  defp credential_help do
    Enum.map_join(@provider_env, ", ", fn {provider, vars} ->
      "#{provider} (#{Enum.join(vars, " or ")})"
    end)
  end

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

    setup do: require_provider!(:anthropic)

    @tag :anthropic
    test "completes a simple prompt" do
      model = anthropic_model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 50})

      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
      assert message.model == model.id
      assert message.api == :anthropic_messages
      assert message.provider == :anthropic

      text = LemonAi.get_text(message)
      assert text != ""
      assert String.contains?(text, "4")

      # Verify usage tracking
      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
    end

    @tag :anthropic
    test "streams responses" do
      model = anthropic_model()

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

    @tag :anthropic
    test "handles tool calling" do
      model = anthropic_model()
      tool = get_weather_tool()

      context =
        Context.new(
          system_prompt:
            "You are a helpful assistant. Use the get_weather tool when asked about weather.",
          tools: [tool]
        )
        |> Context.add_user_message("What's the weather in Paris?")

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

    @tag :anthropic
    test "tracks usage/tokens" do
      model = anthropic_model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Hi")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
      assert message.usage.total_tokens > 0

      # Cost should be calculated
      assert message.usage.cost.total >= 0
    end
  end

  # ============================================================================
  # OpenAI Tests
  # ============================================================================

  describe "OpenAI" do
    @describetag provider: :openai

    setup do: require_provider!(:openai)

    @tag :openai
    test "completes a simple prompt" do
      model = openai_model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 50})

      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
      assert message.model == model.id
      assert message.api == :openai_completions
      assert message.provider == :openai

      text = LemonAi.get_text(message)
      assert text != ""
      assert String.contains?(text, "4")

      # Verify usage tracking
      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
    end

    @tag :openai
    test "streams responses" do
      model = openai_model()

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

    @tag :openai
    test "handles tool calling" do
      model = openai_model()
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

    @tag :openai
    test "tracks usage/tokens" do
      model = openai_model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Hi")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
      assert message.usage.total_tokens > 0
    end
  end

  # ============================================================================
  # Google (Gemini) Tests
  # ============================================================================

  describe "Google" do
    @describetag provider: :google

    setup do: require_provider!(:google)

    @tag :google
    test "completes a simple prompt" do
      model = google_model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 50})

      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
      assert message.model == model.id
      assert message.api == :google_generative_ai
      assert message.provider == :google

      text = LemonAi.get_text(message)
      assert text != ""
      assert String.contains?(text, "4")

      # Verify usage tracking
      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
    end

    @tag :google
    test "streams responses" do
      model = google_model()

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

    @tag :google
    test "handles tool calling" do
      model = google_model()
      tool = get_weather_tool()

      context =
        Context.new(
          system_prompt:
            "You are a helpful assistant. Use the get_weather tool when asked about weather.",
          tools: [tool]
        )
        |> Context.add_user_message("What's the weather in London?")

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

    @tag :google
    test "tracks usage/tokens" do
      model = google_model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Hi")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.output > 0
      assert message.usage.total_tokens > 0
    end
  end

  # ============================================================================
  # Kimi Tests (Anthropic-compatible API)
  # ============================================================================

  describe "Kimi" do
    @describetag provider: :kimi

    setup do: require_provider!(:kimi)

    @tag :kimi
    test "completes a simple prompt" do
      model = kimi_model()

      context =
        Context.new(system_prompt: "You are a helpful assistant. Be very brief.")
        |> Context.add_user_message("What is 2 + 2? Reply with just the number.")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 50})

      assert %AssistantMessage{} = message
      assert message.stop_reason == :stop
      assert message.model == model.id
      assert message.api == :anthropic_messages
      assert message.provider == :kimi

      text = LemonAi.get_text(message)
      assert text != ""
      assert String.contains?(text, "4")

      # Verify usage tracking
      assert %Usage{} = message.usage
      assert message.usage.input > 0
    end

    @tag :kimi
    test "streams responses" do
      model = kimi_model()

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

    @tag :kimi
    test "handles tool calling" do
      model = kimi_model()
      tool = get_weather_tool()

      context =
        Context.new(
          system_prompt:
            "You are a helpful assistant. Use the get_weather tool when asked about weather.",
          tools: [tool]
        )
        |> Context.add_user_message("What's the weather in Berlin?")

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

    @tag :kimi
    test "tracks usage/tokens" do
      model = kimi_model()

      context =
        Context.new(system_prompt: "Be brief.")
        |> Context.add_user_message("Hi")

      {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

      assert %Usage{} = message.usage
      assert message.usage.input > 0
      assert message.usage.total_tokens > 0
    end

    @tag :kimi
    test "handles multi-turn conversation" do
      model = kimi_model()

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
  # Cross-Provider Tests
  # ============================================================================

  describe "Cross-provider consistency" do
    @describetag provider: :all

    setup do
      models =
        for {provider, model} <- [
              anthropic: anthropic_model(),
              openai: openai_model(),
              google: google_model(),
              kimi: kimi_model()
            ],
            configured?(provider),
            do: {provider, model}

      if length(models) < 2 do
        flunk("cross-provider tests need credentials for at least two of " <> credential_help())
      end

      {:ok, models: models}
    end

    @tag :cross_provider
    test "all available providers return consistent AssistantMessage structure", %{
      models: models
    } do
      context =
        Context.new(system_prompt: "Be very brief.")
        |> Context.add_user_message("Say 'test'")

      for {provider_name, model} <- models do
        {:ok, message} = LemonAi.complete(model, context, %{max_tokens: 20})

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

    @tag :cross_provider
    test "all available providers emit consistent stream events", %{models: models} do
      context =
        Context.new(system_prompt: "Be very brief.")
        |> Context.add_user_message("Say 'ok'")

      for {provider_name, model} <- models do
        {:ok, stream} = LemonAi.stream(model, context, %{max_tokens: 20})
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
            match?({:text_delta, _, _}, e) or
              match?({:text_start, _}, e) or
              match?({:text_end, _, _}, e)
          end)

        assert content_events != [],
               "#{provider_name} should emit content events"
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  # Offline: each provider sends a real HTTP request to a loopback fixture that
  # rejects the key with 401, so these need neither network nor credentials.
  # Nightly's `integration` job runs them (`--only provider:error_handling`).
  describe "Error handling" do
    @describetag provider: :error_handling

    setup do
      server =
        StreamServer.start(fn _n ->
          [
            {:status, 401,
             ~s({"error":{"type":"authentication_error","message":"invalid api key"}})}
          ]
        end)

      on_exit(fn -> StreamServer.stop(server) end)
      {:ok, server: server}
    end

    for {name, model_fun, path} <- [
          {"Anthropic", :anthropic_model, ""},
          {"OpenAI", :openai_model, "/v1"},
          {"Google", :google_model, "/v1beta"}
        ] do
      @tag :error_handling
      test "reports a rejected API key as an error for #{name}", %{server: server} do
        model = %{unquote(model_fun)() | base_url: server.url <> unquote(path)}

        context =
          Context.new(system_prompt: "Test")
          |> Context.add_user_message("Hello")

        {:ok, stream} =
          LemonAi.stream(model, context, %{api_key: "invalid-key", max_tokens: 10})

        assert {:error, %AssistantMessage{} = message} = EventStream.result(stream, 10_000)
        assert message.stop_reason == :error
        assert message.error_message =~ ~r/401|invalid api key/i
        assert_received {:stream_server, :request, 0, %{body: body}}
        assert body =~ "Hello"
      end
    end
  end
end
