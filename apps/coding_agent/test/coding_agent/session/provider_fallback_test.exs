defmodule CodingAgent.Session.ProviderFallbackTest do
  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, TextContent, Usage}
  alias CodingAgent.Session.ProviderFallback
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager

  test "falls back after a provider stream error before content is emitted" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")

    settings = %SettingsManager{
      providers: %{
        "openai" => %{api_key: "primary-key"},
        "azure_openai_responses" => %{api_key: "fallback-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai -> {:ok, error_stream(model)}
        :azure_openai_responses -> {:ok, success_stream(model, "fallback response")}
      end
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:ok, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :azure_openai_responses
    assert message.model == "gpt-4"
    assert [%TextContent{text: "fallback response"}] = message.content

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  test "does not fall back on a client-shaped (400) pre-commit stream error" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai ->
          {:ok, error_stream(model, "Invalid request (HTTP 400): messages must be non-empty")}

        :azure_openai_responses ->
          {:ok, success_stream(model, "unexpected fallback")}
      end
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:error, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert message.error_message =~ "HTTP 400"

    assert_receive {:attempt, :openai, "primary-key"}
    refute_receive {:attempt, :azure_openai_responses, _}, 100
  end

  test "does not fall back on a context-length pre-commit stream error" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai ->
          {:ok,
           error_stream(model, "maximum context length is 8192 tokens (context_length_exceeded)")}

        :azure_openai_responses ->
          {:ok, success_stream(model, "unexpected fallback")}
      end
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:error, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert message.error_message =~ "context_length_exceeded"

    assert_receive {:attempt, :openai, "primary-key"}
    refute_receive {:attempt, :azure_openai_responses, _}, 100
  end

  test "falls back on a transient-shaped (503) pre-commit stream error" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai ->
          {:ok, error_stream(model, "Service temporarily unavailable (HTTP 503)")}

        :azure_openai_responses ->
          {:ok, success_stream(model, "fallback response")}
      end
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:ok, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :azure_openai_responses
    assert [%TextContent{text: "fallback response"}] = message.content

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  test "falls back on an auth-shaped (401) pre-commit stream error" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai ->
          {:ok, error_stream(model, "Authentication failed (HTTP 401): invalid api key")}

        :azure_openai_responses ->
          {:ok, success_stream(model, "fallback response")}
      end
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:ok, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :azure_openai_responses

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  test "does not fall back after useful content has been emitted" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")

    settings = %SettingsManager{
      providers: %{
        "openai" => %{api_key: "primary-key"},
        "azure_openai_responses" => %{api_key: "fallback-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }

    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})
      {:ok, content_then_error_stream(model)}
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert {:error, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert message.error_message == "provider_error_after_content"

    assert_receive {:attempt, :openai, "primary-key"}
    refute_receive {:attempt, :azure_openai_responses, _}, 100
  end

  test "relays useful content before the upstream stream completes" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, _options ->
      {:ok, delayed_success_stream(model, "streamed", parent)}
    end

    wrapped = ProviderFallback.maybe_wrap(stream_fn, primary, settings, File.cwd!())
    {:ok, stream} = wrapped.(primary, %Context{}, %StreamOptions{})

    assert_receive {:delta_pushed, producer}, 1_000
    assert {:event, {:start, _message}} = GenServer.call(stream, :take, 500)
    send(producer, :finish_stream)
    assert {:ok, message} = LemonAi.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert [%TextContent{text: "streamed"}] = message.content
  end

  test "session lifecycle wraps explicitly selected models" do
    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai -> {:ok, error_stream(model)}
        :azure_openai_responses -> {:ok, success_stream(model, "fallback response")}
      end
    end

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        model: primary,
        settings_manager: settings,
        stream_fn: stream_fn
      )

    :ok = Session.prompt(session, "hello")
    wait_for_idle(session)

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  test "session lifecycle wraps default model streams" do
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai -> {:ok, error_stream(model)}
        :azure_openai_responses -> {:ok, success_stream(model, "fallback response")}
      end
    end

    {:ok, session} =
      Session.start_link(
        cwd: System.tmp_dir!(),
        settings_manager: settings,
        stream_fn: stream_fn
      )

    :ok = Session.prompt(session, "hello")
    wait_for_idle(session)

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  defp success_stream(model, text) do
    message = message(model, :stop, text, nil)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:text_start, 0, message})
      LemonAi.EventStream.push(stream, {:text_delta, 0, text, message})
      LemonAi.EventStream.push(stream, {:text_end, 0, text, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end

  defp delayed_success_stream(model, text, parent) do
    message = message(model, :stop, text, nil)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:text_start, 0, message})
      LemonAi.EventStream.push(stream, {:text_delta, 0, text, message})
      send(parent, {:delta_pushed, self()})

      receive do
        :finish_stream -> :ok
      after
        1_000 -> :ok
      end

      LemonAi.EventStream.push(stream, {:text_end, 0, text, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end

  defp error_stream(model, error_message \\ "provider_unavailable") do
    message = message(model, :error, "", error_message)
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.error(stream, message)
    end)

    stream
  end

  defp content_then_error_stream(model) do
    message = message(model, :error, "partial", "provider_error_after_content")
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:text_delta, 0, "partial", message})
      LemonAi.EventStream.error(stream, message)
    end)

    stream
  end

  defp message(model, stop_reason, text, error_message) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: %Usage{},
      stop_reason: stop_reason,
      error_message: error_message,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp routing_settings do
    %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      providers: %{
        "openai" => %{api_key: "primary-key"},
        "azure_openai_responses" => %{api_key: "fallback-key"}
      },
      provider_routing: %{
        enabled: true,
        fallback_providers: ["azure_openai_responses"],
        require_credentials: true
      }
    }
  end

  defp wait_for_idle(session) do
    if Session.get_state(session).is_streaming do
      Process.sleep(10)
      wait_for_idle(session)
    else
      :ok
    end
  end
end
