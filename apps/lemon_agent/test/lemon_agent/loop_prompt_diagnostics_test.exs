defmodule LemonAgent.LoopPromptDiagnosticsTest do
  use ExUnit.Case, async: false

  alias LemonAgent.{EventStream, Loop}
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig}
  alias LemonAi.Types.{AssistantMessage, StreamOptions, UserMessage}

  @fixtures Path.expand("../../../lemon_ai/test/fixtures/openai_completions", __DIR__)
  @event [:lemon_ai, :prompt_diagnostics, :llm_call]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_agent)
    previous_req = Req.default_options()
    previous_diagnostics = System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS")
    System.put_env("LEMON_AI_PROMPT_DIAGNOSTICS", "1")
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    handler = {__MODULE__, make_ref()}
    :ok = :telemetry.attach(handler, @event, &__MODULE__.handle_event/4, self())

    on_exit(fn ->
      :telemetry.detach(handler)
      Req.default_options(previous_req)
      Req.Test.set_req_test_to_private(%{})

      if previous_diagnostics do
        System.put_env("LEMON_AI_PROMPT_DIAGNOSTICS", previous_diagnostics)
      else
        System.delete_env("LEMON_AI_PROMPT_DIAGNOSTICS")
      end
    end)

    :ok
  end

  def handle_event(_event, _measurements, metadata, owner) do
    send(owner, {:diagnostics, metadata.data})
  end

  test "native loop completes faithful ZAI usage with diagnostics enabled" do
    result = run_loop(File.read!(Path.join(@fixtures, "zai_usage_only.sse")))
    assert result.usage.input == nil
    assert result.usage.cache_write == nil
    assert result.usage.cost.total == nil
    assert_receive {:diagnostics, data}
    assert data.input_tokens == nil
    assert data.cache_read_tokens == 20
    assert data.cache_write_tokens == nil
    assert data.output_tokens == 30
    assert data.total_tokens == 130
    assert data.total_input_tokens == nil
    json = Jason.decode!(Jason.encode!(data))
    assert Map.fetch!(json, "input_tokens") == nil
    assert Map.fetch!(json, "cache_write_tokens") == nil
    assert Map.fetch!(json, "total_input_tokens") == nil
  end

  test "native loop completes missing usage without inventing diagnostic counters" do
    result =
      run_loop(
        "data: {\"choices\":[{\"delta\":{\"content\":\"Fixture\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      )

    assert result.usage.total_tokens == nil
    assert result.usage.cost.total == nil
    assert_receive {:diagnostics, data}
    assert data.usage_present

    for key <- [
          :input_tokens,
          :output_tokens,
          :cache_read_tokens,
          :cache_write_tokens,
          :total_tokens,
          :total_input_tokens
        ] do
      assert Map.fetch!(data, key) == nil
      assert Map.fetch!(Jason.decode!(Jason.encode!(data)), Atom.to_string(key)) == nil
    end
  end

  defp run_loop(body) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:route, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    config = %AgentLoopConfig{
      model: LemonAi.Models.get_model(:zai, "glm-5.3"),
      convert_to_llm: fn messages -> messages end,
      stream_options: %StreamOptions{api_key: "offline-fixture-not-a-credential"}
    }

    stream =
      Loop.agent_loop(
        [%UserMessage{content: "Offline fixture only."}],
        AgentContext.new(messages: [], tools: []),
        config,
        nil,
        nil
      )

    assert {:ok, messages} = EventStream.result(stream, 5_000)
    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert %AssistantMessage{stop_reason: :stop} = result = List.last(messages)
    result
  end
end
