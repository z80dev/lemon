defmodule CodingAgent.GatewayEngineFallbackTest do
  use ExUnit.Case

  alias LemonAi.Types.{AssistantMessage, TextContent, Usage}
  alias CodingAgent.GatewayEngine, as: Lemon
  alias LemonGateway.Types.Job

  @moduletag :tmp_dir

  # Runs through the gateway engine path (SessionRunner -> Session -> Lifecycle)
  # with an explicit model in job.meta and provider routing configured via the
  # project config. The stream must fall back to the routed provider when the
  # primary errors before emitting content.
  test "gateway engine sessions with an explicit model fall back to routed providers", %{
    tmp_dir: tmp_dir
  } do
    write_project_config(tmp_dir)

    primary = LemonAi.Models.get_model(:openai, "gpt-4")
    parent = self()

    stream_fn = fn model, _context, _options ->
      send(parent, {:attempt, model.provider})

      case model.provider do
        :openai -> {:ok, error_stream(model)}
        :azure_openai_responses -> {:ok, success_stream(model, "fallback response")}
      end
    end

    job = %Job{
      run_id: "run_fallback_#{System.unique_integer([:positive])}",
      session_key: "test:lemon:#{System.unique_integer([:positive])}",
      prompt: "hello",
      engine_id: "lemon",
      cwd: tmp_dir,
      meta: %{model: primary, stream_fn: stream_fn}
    }

    {:ok, run_ref, _ctx} = Lemon.start_run(job, %{stream_fn: stream_fn}, self())

    assert_receive {:attempt, :openai}, 5_000
    assert_receive {:attempt, :azure_openai_responses}, 5_000

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed} = completed}, 5_000
    assert completed.ok
    assert completed.answer =~ "fallback response"
  end

  defp write_project_config(tmp_dir) do
    config_dir = Path.join(tmp_dir, ".lemon")
    File.mkdir_p!(config_dir)

    File.write!(Path.join(config_dir, "config.toml"), """
    [runtime.provider_routing]
    enabled = true
    fallback_providers = ["azure_openai_responses"]
    require_credentials = true

    [providers.openai]
    api_key = "primary-key"

    [providers.azure_openai_responses]
    api_key = "fallback-key"
    """)
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

  defp error_stream(model) do
    message = message(model, :error, "", "provider_unavailable")
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
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
end
