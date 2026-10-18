defmodule LemonSim.LLM.Deciders.ToolLoopDeciderUsageTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Models
  alias LemonAi.Types.Context
  alias LemonSim.LLM.Deciders.ToolLoopDecider
  alias LemonSim.LLM.Usage

  @fixtures Path.expand("../../../../lemon_ai/test/fixtures/openai_completions", __DIR__)

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

  test "faithful ZAI usage survives the tool loop and stays unknown after a known response" do
    fixture = File.read!(Path.join(@fixtures, "zai_usage_only.sse"))

    stub_responses([
      fixture,
      tool_response(%{
        "prompt_tokens" => 10,
        "completion_tokens" => 5,
        "total_tokens" => 15,
        "prompt_tokens_details" => %{"cached_tokens" => 0, "cache_write_tokens" => 0}
      })
    ])

    {:ok, collector} = Usage.start_link("zai_decider_fixture")
    assert {:ok, decision} = decide(collector)
    assert decision["tool_name"] == "wait"
    assert decision["events"] == [%{"kind" => "wait_committed"}]
    assert Process.alive?(collector)
    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert_receive {:raw_usage, raw}
    assert raw["prompt_tokens"] == 100
    assert raw["prompt_tokens_details"] == %{"cached_tokens" => 20}
    assert_receive {:raw_usage, %{"prompt_tokens" => 10}}

    artifact = Usage.artifact(collector, "zai_decider_fixture")
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == 35
    assert artifact.totals.cache_read_tokens == 20
    assert artifact.totals.cache_write_tokens == nil
    assert artifact.totals.cost_usd == nil
    assert artifact.totals.decisions == 1
    assert artifact.actors["operator"].input_tokens == nil
    assert artifact.actors["operator"].output_tokens == 35
    assert artifact.actors["operator"].cost_usd == nil

    persisted = artifact |> Usage.encode_artifact() |> Jason.decode!()
    assert persisted["totals"]["input_tokens"] == nil
    assert persisted["totals"]["cache_read_tokens"] == 20
    assert persisted["actors"]["operator"]["cache_write_tokens"] == nil

    assert Usage.summary_line(persisted) ==
             "usage: unknown in / 35 out, unknown cost (1 actors)"
  end

  test "partial provider usage completes a tool decision without inventing counters or cost" do
    stub_responses([tool_response(%{"completion_tokens" => 7})])
    {:ok, collector} = Usage.start_link("partial_decider_fixture")
    assert {:ok, decision} = decide(collector)
    assert decision["tool_name"] == "wait"
    assert Process.alive?(collector)
    assert_receive {:route, "api.z.ai", "/api/coding/paas/v4/chat/completions"}
    assert_receive {:raw_usage, %{"completion_tokens" => 7}}

    artifact = Usage.artifact(collector, "partial_decider_fixture")
    refute artifact.cost_known?
    assert artifact.totals.input_tokens == nil
    assert artifact.totals.output_tokens == 7
    assert artifact.totals.cache_read_tokens == nil
    assert artifact.totals.cache_write_tokens == nil
    assert artifact.totals.cost_usd == nil
    assert artifact.totals.decisions == 1
    assert artifact.actors["operator"].output_tokens == 7

    persisted = artifact |> Usage.encode_artifact() |> Jason.decode!()
    refute persisted["cost_known?"]
    assert persisted["actors"]["operator"]["input_tokens"] == nil
    assert persisted["actors"]["operator"]["cost_usd"] == nil

    assert Usage.summary_line(persisted) ==
             "usage: unknown in / 7 out, unknown cost (1 actors)"
  end

  defp stub_responses(bodies) do
    owner = self()
    {:ok, responses} = Agent.start_link(fn -> bodies end)

    Req.Test.stub(__MODULE__, fn conn ->
      send(owner, {:route, conn.host, conn.request_path})

      body =
        Agent.get_and_update(responses, fn
          [body | rest] -> {body, rest}
          [] -> flunk("unexpected offline provider request")
        end)

      Plug.Conn.send_resp(conn, 200, body)
    end)
  end

  defp decide(collector) do
    owner = self()
    model = Models.get_model(:zai, "glm-5.3")
    assert model.provider == :zai
    assert model.cost.input > 0

    context =
      Context.new(system_prompt: "Choose the wait tool.")
      |> Context.add_user_message("Offline fixture only.")

    ToolLoopDecider.decide(context, [wait_tool()],
      model: model,
      usage_collector: collector,
      usage_actor_id: "operator",
      empty_response_retries: 1,
      empty_response_backoff: fn _retry -> :ok end,
      transient_retries: 0,
      stream_options: %{
        api_key: "offline-fixture-not-a-credential",
        retry: [max_attempts: 1],
        on_usage: fn raw, _metadata -> send(owner, {:raw_usage, raw}) end
      }
    )
  end

  defp tool_response(usage) do
    choice = %{
      "index" => 0,
      "delta" => %{
        "tool_calls" => [
          %{
            "index" => 0,
            "id" => "offline-wait",
            "type" => "function",
            "function" => %{"name" => "wait", "arguments" => "{}"}
          }
        ]
      },
      "finish_reason" => "tool_calls"
    }

    "data: " <>
      Jason.encode!(%{"choices" => [choice]}) <>
      "\n\n" <>
      "data: " <>
      Jason.encode!(%{"choices" => [], "usage" => usage}) <>
      "\n\ndata: [DONE]\n\n"
  end

  defp wait_tool do
    %AgentTool{
      name: "wait",
      description: "Wait for the next turn",
      parameters: %{"type" => "object", "properties" => %{}},
      label: "Wait",
      execute: fn _id, _params, _signal, _on_update ->
        {:ok,
         %AgentToolResult{
           content: [LemonAgent.text_content("wait committed")],
           details: %{ok: true, event: %{"kind" => "wait_committed"}},
           trust: :trusted
         }}
      end
    }
  end
end
