defmodule LemonAgent.ModelRuntime.TelemetryOptionsTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Agent
  alias LemonAgent.ModelRuntime.StreamOptions
  alias LemonAgent.Test.Mocks

  test "native session identity and both observers survive model runtime and the agent stream seam" do
    parent = self()
    run_id = "offline-parent-run"
    model = LemonAi.Models.get_model(:zai, "glm-5.3")
    assert model.provider == :zai
    assert model.api == :openai_completions
    assert model.base_url == "https://api.z.ai/api/coding/paas/v4"

    payload_observer = fn payload, metadata ->
      send(parent, {:payload_observed, run_id, payload, metadata})
    end

    usage_observer = fn usage, metadata ->
      send(parent, {:usage_observed, run_id, usage, metadata})
    end

    options =
      StreamOptions.build_stream_options(
        model,
        %{},
        %{
          api_key: "offline-fixture-key",
          api_key_authoritative: true,
          session_id: "caller-session",
          on_payload: payload_observer,
          on_usage: usage_observer,
          headers: %{"x-lemon-run-id" => run_id}
        },
        "/offline-fixture"
      )

    assert options.on_payload == payload_observer
    assert options.on_usage == usage_observer
    assert options.session_id == "caller-session"

    response = Mocks.mock_stream_fn_single(Mocks.assistant_message("offline fixture answer"))

    # This is the existing in-memory stream seam, not a provider request. The
    # provider SSE/observer contract itself is exercised by lemon_ai's fixtures.
    stream = fn selected, context, received ->
      send(parent, {:stream_options, selected, received})

      metadata = %{
        provider: selected.provider,
        model: selected.id,
        session_id: received.session_id
      }

      received.on_payload.(%{"model" => selected.id}, metadata)
      received.on_usage.(%{"prompt_tokens" => 100, "completion_tokens" => 30}, metadata)
      response.(selected, context, received)
    end

    agent =
      start_supervised!(
        {Agent,
         initial_state: %{model: model, thinking_level: :off, tools: []},
         convert_to_llm: Mocks.simple_convert_to_llm(),
         session_id: "native-session",
         stream_options: options,
         stream_fn: stream,
         get_api_key: fn _ -> "offline-fixture-key" end,
         max_retries: 0}
      )

    assert :ok = Agent.prompt(agent, "offline fixture")
    assert :ok = Agent.wait_for_idle(agent, 5_000)
    assert_receive {:stream_options, ^model, received}
    assert received.on_payload == payload_observer
    assert received.on_usage == usage_observer
    assert received.session_id == "native-session"
    assert received.headers["x-lemon-run-id"] == run_id
    assert_receive {:payload_observed, ^run_id, %{"model" => "glm-5.3"}, metadata}
    assert metadata == %{provider: :zai, model: "glm-5.3", session_id: "native-session"}
    assert_receive {:usage_observed, ^run_id, %{"prompt_tokens" => 100}, ^metadata}
  end
end
