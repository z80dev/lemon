defmodule LemonAi.Providers.OpenAICompletionsUsageTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, Models}
  alias LemonAi.Providers.OpenAICompletions
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

  @fixtures Path.expand("../fixtures/openai_completions", __DIR__)

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp replay(body) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:route, conn.host, conn.request_path})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = Models.get_model(:zai, "glm-5.3")
    assert model.provider == :zai
    assert model.api == :openai_completions
    assert model.base_url == "https://api.z.ai/api/coding/paas/v4"

    opts = %StreamOptions{
      api_key: "offline-fixture-not-a-credential",
      session_id: "offline-session",
      on_payload: fn payload, metadata -> send(owner, {:payload, payload, metadata}) end,
      on_usage: fn usage, metadata -> send(owner, {:usage, usage, metadata}) end
    }

    context = Context.new(messages: [%UserMessage{content: "Offline fixture only."}])
    {:ok, stream} = OpenAICompletions.stream(model, context, opts)
    assert {:ok, result} = EventStream.result(stream, 5_000)
    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert_receive {:payload, payload, metadata}
    assert payload["model"] == "glm-5.3" or payload[:model] == "glm-5.3"
    assert metadata == %{provider: :zai, model: "glm-5.3", session_id: "offline-session"}
    {result, metadata}
  end

  test "usage-only chunk preserves exact disjoint counts and does not add reasoning twice" do
    {result, metadata} = replay(File.read!(Path.join(@fixtures, "compatible_complete.sse")))
    assert_receive {:usage, raw, ^metadata}
    assert raw["completion_tokens_details"]["reasoning_tokens"] == 12
    assert result.usage.input == 70
    assert result.usage.output == 30
    assert result.usage.cache_read == 20
    assert result.usage.cache_write == 10
    assert result.usage.total_tokens == 130
    assert is_float(result.usage.cost.total)
    refute_receive {:usage, _, _}
  end

  test "faithful ZAI usage does not invent missing cache-write measurements" do
    {result, metadata} = replay(File.read!(Path.join(@fixtures, "zai_usage_only.sse")))
    assert_receive {:usage, raw, ^metadata}
    refute Map.has_key?(raw["prompt_tokens_details"], "cache_write_tokens")
    assert result.usage.input == nil
    assert result.usage.cache_read == 20
    assert result.usage.cache_write == nil
    assert result.usage.output == 30
    assert result.usage.total_tokens == 130
    assert result.usage.cost.total == nil
  end

  test "final choice usage is observed once and explicit zero remains zero" do
    raw = %{
      "prompt_tokens" => 100,
      "completion_tokens" => 30,
      "total_tokens" => 130,
      "prompt_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
    }

    event = %{
      "choices" => [%{"delta" => %{"content" => "Fixture"}, "finish_reason" => "stop"}],
      "usage" => raw
    }

    {result, metadata} = replay("data: " <> Jason.encode!(event) <> "\n\ndata: [DONE]\n\n")
    assert_receive {:usage, ^raw, ^metadata}
    assert result.usage.input == 100
    assert result.usage.cache_read == 0
    assert result.usage.cache_write == 0
    assert result.usage.output == 30
    refute_receive {:usage, _, _}
  end

  test "missing usage remains unknown despite a successful final choice" do
    {result, _} =
      replay(
        "data: {\"choices\":[{\"delta\":{\"content\":\"Fixture\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      )

    assert result.stop_reason == :stop
    assert result.usage.input == nil
    assert result.usage.output == nil
    assert result.usage.cache_read == nil
    assert result.usage.cache_write == nil
    assert result.usage.total_tokens == nil
    assert result.usage.cost.total == nil
    refute_receive {:usage, _, _}
  end

  test "partial usage preserves independently observed counters and raw shape" do
    {result, metadata} =
      replay("data: {\"choices\":[],\"usage\":{\"completion_tokens\":7}}\n\ndata: [DONE]\n\n")

    assert_receive {:usage, %{"completion_tokens" => 7}, ^metadata}
    assert result.usage.output == 7
    assert result.usage.input == nil
    assert result.usage.total_tokens == nil
    assert result.usage.cost.output != nil
    assert result.usage.cost.total == nil
  end
end
