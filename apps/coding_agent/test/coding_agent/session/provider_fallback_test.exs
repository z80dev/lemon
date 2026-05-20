defmodule CodingAgent.Session.ProviderFallbackTest do
  use ExUnit.Case, async: false

  alias Ai.Types.{AssistantMessage, Context, StreamOptions, TextContent, Usage}
  alias CodingAgent.Session.ProviderFallback
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager

  test "falls back after a provider stream error before content is emitted" do
    primary = Ai.Models.get_model(:openai, "gpt-4")

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

    assert {:ok, message} = Ai.EventStream.result(stream, 1_000)
    assert message.provider == :azure_openai_responses
    assert message.model == "gpt-4"
    assert [%TextContent{text: "fallback response"}] = message.content

    assert_receive {:attempt, :openai, "primary-key"}
    assert_receive {:attempt, :azure_openai_responses, "fallback-key"}
  end

  test "does not fall back after useful content has been emitted" do
    primary = Ai.Models.get_model(:openai, "gpt-4")

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

    assert {:error, message} = Ai.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert message.error_message == "provider_error_after_content"

    assert_receive {:attempt, :openai, "primary-key"}
    refute_receive {:attempt, :azure_openai_responses, _}, 100
  end

  test "relays useful content before the upstream stream completes" do
    primary = Ai.Models.get_model(:openai, "gpt-4")
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
    assert {:ok, message} = Ai.EventStream.result(stream, 1_000)
    assert message.provider == :openai
    assert [%TextContent{text: "streamed"}] = message.content
  end

  test "session lifecycle does not wrap explicitly selected models" do
    primary = Ai.Models.get_model(:openai, "gpt-4")
    settings = routing_settings()
    parent = self()

    stream_fn = fn model, _context, options ->
      send(parent, {:attempt, model.provider, options.api_key})

      case model.provider do
        :openai -> {:ok, error_stream(model)}
        :azure_openai_responses -> {:ok, success_stream(model, "unexpected fallback")}
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
    refute_receive {:attempt, :azure_openai_responses, _}, 100
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
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, message})
      Ai.EventStream.push(stream, {:text_start, 0, message})
      Ai.EventStream.push(stream, {:text_delta, 0, text, message})
      Ai.EventStream.push(stream, {:text_end, 0, text, message})
      Ai.EventStream.complete(stream, message)
    end)

    stream
  end

  defp delayed_success_stream(model, text, parent) do
    message = message(model, :stop, text, nil)
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, message})
      Ai.EventStream.push(stream, {:text_start, 0, message})
      Ai.EventStream.push(stream, {:text_delta, 0, text, message})
      send(parent, {:delta_pushed, self()})

      receive do
        :finish_stream -> :ok
      after
        1_000 -> :ok
      end

      Ai.EventStream.push(stream, {:text_end, 0, text, message})
      Ai.EventStream.complete(stream, message)
    end)

    stream
  end

  defp error_stream(model) do
    message = message(model, :error, "", "provider_unavailable")
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, message})
      Ai.EventStream.error(stream, message)
    end)

    stream
  end

  defp content_then_error_stream(model) do
    message = message(model, :error, "partial", "provider_error_after_content")
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      Ai.EventStream.push(stream, {:start, message})
      Ai.EventStream.push(stream, {:text_delta, 0, "partial", message})
      Ai.EventStream.error(stream, message)
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
