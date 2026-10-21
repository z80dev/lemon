defmodule LemonAi.PromptDiagnosticsTest do
  use ExUnit.Case, async: false

  alias LemonAi.{Models, PromptDiagnostics}
  alias LemonAi.Types.{AssistantMessage, Context, StreamOptions, Usage, UserMessage}

  @fixtures Path.expand("../fixtures/openai_completions", __DIR__)
  @event [:lemon_ai, :prompt_diagnostics, :llm_call]

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
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

  test "nullable components propagate to inclusive input while known zeros remain known" do
    for missing <- [:input, :cache_read, :cache_write] do
      usage = struct(Usage, Map.put(%{input: 70, cache_read: 20, cache_write: 10}, missing, nil))
      assert :ok = record(usage)
      assert_receive {:diagnostics, data}
      assert data.total_input_tokens == nil
      assert Map.fetch!(data, token_key(missing)) == nil
      assert Jason.decode!(Jason.encode!(data))["total_input_tokens"] == nil
    end

    assert :ok = record(%Usage{input: 70, cache_read: 20, cache_write: 10})
    assert_receive {:diagnostics, %{total_input_tokens: 100}}
    assert :ok = record(%Usage{input: 0, cache_read: 0, cache_write: 0})
    assert_receive {:diagnostics, %{total_input_tokens: 0}}
    assert :ok = record(nil)
    assert_receive {:diagnostics, %{usage_present: false}}
  end

  test "complete succeeds with faithful ZAI usage and emits unknown components as null" do
    result = complete(File.read!(Path.join(@fixtures, "zai_usage_only.sse")))
    assert result.usage.input == nil
    assert result.usage.cache_write == nil
    assert result.usage.cost.total == nil
    assert_receive {:diagnostics, data}
    assert data.usage_present
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

  test "complete succeeds without usage and diagnostics retain all unknown counters" do
    result =
      complete(
        "data: {\"choices\":[{\"delta\":{\"content\":\"Fixture\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      )

    assert result.stop_reason == :stop
    assert result.usage.total_tokens == nil
    assert_receive {:diagnostics, data}

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

  defp record(usage) do
    PromptDiagnostics.record_llm_call(
      Models.get_model(:zai, "glm-5.3"),
      Context.new(messages: []),
      %StreamOptions{},
      %AssistantMessage{usage: usage, stop_reason: :stop}
    )
  end

  defp token_key(:input), do: :input_tokens
  defp token_key(:cache_read), do: :cache_read_tokens
  defp token_key(:cache_write), do: :cache_write_tokens

  defp complete(body) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:route, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    assert {:ok, result} =
             LemonAi.complete(
               Models.get_model(:zai, "glm-5.3"),
               Context.new(messages: [%UserMessage{content: "Offline fixture only."}]),
               %{api_key: "offline-fixture-not-a-credential", retry: [max_attempts: 1]}
             )

    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert result.stop_reason == :stop
    result
  end
end
