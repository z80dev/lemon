defmodule LemonAgent.ModelRuntime.ModelRoutingAnthropicTest do
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.ModelRouting
  alias LemonAi.{EventStream, Models}
  alias LemonAi.Providers.Anthropic
  alias LemonAi.Types.{Context, StreamOptions, UserMessage}

  setup do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "cap accounts for actual Anthropic manual-thinking output expansion" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(body)})
      Plug.Conn.send_resp(conn, 200, "event: message_stop\ndata: {}\n\n")
    end)

    model = Models.get_model(:anthropic, "claude-3-7-sonnet-20250219")
    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    options = %StreamOptions{api_key: "test-key", max_tokens: 100, reasoning: :medium}

    # Exercise the real wire-option calculation, not a fake provider's limits.
    {:ok, stream} = Anthropic.stream(model, context, options)
    assert_receive {:request_body, body}, 1000
    assert body["max_tokens"] == 14_096
    assert body["thinking"]["budget_tokens"] == 10_000
    assert {:ok, _} = EventStream.result(stream, 1000)

    # This cap would allow the requested 100 tokens but not the actual wire bound.
    cap = (100 + body["max_tokens"]) / 2 * model.cost.output / 1_000_000

    policy =
      ModelRouting.prepare(
        %{enabled: true, max_cost_usd: cap, rules: [%{model: "anthropic:#{model.id}"}]},
        fn _ -> model end
      )

    assert {:error, :model_routing_cost_cap} =
             ModelRouting.select(policy, model, context, options)

    assert {:error, :model_routing_cost_cap} =
             ModelRouting.check_cap(policy, model, context, options)

    # The catalog ceiling remains safe for caller-configured thinking budgets too.
    large_budget = %{options | thinking_budgets: %{medium: 30_000}}

    assert {:error, :model_routing_cost_cap} =
             ModelRouting.check_cap(policy, model, context, large_budget)
  end
end
