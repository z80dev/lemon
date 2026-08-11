defmodule LemonTcg.Agent.SessionTest do
  use ExUnit.Case, async: true

  alias LemonAgent.Types.AgentTool
  alias LemonAi.Types.{AssistantMessage, Model, ToolCall}
  alias LemonTcg.Agent.{ActionSpace, Session, Updater}
  alias LemonTcg.Desk
  alias LemonTcg.MarketData.Sources.Fixture
  alias LemonTcg.Risk.Policy
  alias LemonSim.Kernel.{Event, State}

  defp fake_model(id) do
    %Model{
      id: id,
      name: id,
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{}
    }
  end

  defp tool_call(name, arguments) do
    %ToolCall{
      type: :tool_call,
      id: "call_#{name}_#{System.unique_integer([:positive])}",
      name: name,
      arguments: arguments
    }
  end

  defp assistant_message(tool_calls) do
    {:ok,
     %AssistantMessage{
       role: :assistant,
       content: tool_calls,
       stop_reason: :tool_use,
       timestamp: System.system_time(:millisecond)
     }}
  end

  defp scripted_complete_fn(turns) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    fn _model, _context, _stream_opts ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
      script = Enum.at(turns, min(turn, length(turns) - 1))
      assistant_message(script.())
    end
  end

  defp desk_opts(collection) do
    [
      starting_cash_usd: 10_000.0,
      watchlist: [collection],
      market_opts: [source: Fixture, fresh?: true],
      policy: %Policy{
        max_trade_usd: 5_000.0,
        max_daily_spend_usd: 8_000.0,
        min_cash_reserve_usd: 0.0
      }
    ]
  end

  defp run_session(collection, turns, opts \\ []) do
    Session.run(
      Keyword.merge(
        [
          desk_opts: desk_opts(collection),
          model: fake_model("operator"),
          stream_options: %{},
          complete_fn: scripted_complete_fn(turns)
        ],
        opts
      )
    )
  end

  test "scripted operator runs browse → buy → sell → close against the paper venue" do
    collection = "session_loop_#{System.unique_integer([:positive])}"
    mint = "#{collection}_mint_1"

    turns = [
      fn ->
        [
          tool_call("tcg_live_listings", %{"collection" => collection}),
          tool_call("tcg_live_buy", %{"collection" => collection, "mint" => mint})
        ]
      end,
      fn ->
        [
          tool_call("tcg_live_dashboard", %{}),
          tool_call("tcg_live_sell", %{"mint" => mint})
        ]
      end,
      fn -> [tool_call("tcg_live_close_session", %{"reason" => "round trip done"})] end
    ]

    assert {:ok, %State{} = final} = run_session(collection, turns)

    assert final.world.status == "complete"

    assert Enum.map(final.world.action_history, & &1.kind) == [
             "tcg_live_bought",
             "tcg_live_sold"
           ]

    assert final.world.snapshot.mark.position_count == 0
    assert final.world.snapshot.mark.realized_pnl_usd != 0.0
    assert final.world.invalid_action_count == 0
  end

  test "waiting consumes market turns until the session auto-completes" do
    collection = "session_wait_#{System.unique_integer([:positive])}"
    turns = [fn -> [tool_call("tcg_live_wait", %{"reason" => "nothing cheap"})] end]

    assert {:ok, %State{} = final} = run_session(collection, turns, max_turns: 2)

    assert final.world.status == "complete"
    assert final.world.turn == 3
    assert final.world.action_history == []
  end

  test "risk-blocked buys are recorded as invalid actions, not crashes" do
    collection = "session_blocked_#{System.unique_integer([:positive])}"
    mint = "#{collection}_mint_1"

    turns = [
      fn -> [tool_call("tcg_live_buy", %{"collection" => collection, "mint" => mint})] end,
      fn -> [tool_call("tcg_live_close_session", %{})] end
    ]

    desk_opts =
      Keyword.put(desk_opts(collection), :policy, %Policy{
        max_trade_usd: 0.01,
        max_daily_spend_usd: 8_000.0
      })

    assert {:ok, %State{} = final} =
             run_session(collection, turns, desk_opts: desk_opts)

    assert final.world.status == "complete"
    assert final.world.invalid_action_count == 1
    assert [%{kind: "tcg_live_action_rejected"}] = final.world.action_history
    assert final.world.snapshot.mark.position_count == 0
  end

  test "session can drive an externally owned desk without stopping it" do
    collection = "session_external_#{System.unique_integer([:positive])}"
    desk = start_supervised!({Desk, desk_opts(collection)})

    turns = [fn -> [tool_call("tcg_live_close_session", %{})] end]

    assert {:ok, %State{}} =
             Session.run(
               desk: desk,
               model: fake_model("operator"),
               stream_options: %{},
               complete_fn: scripted_complete_fn(turns)
             )

    assert Process.alive?(desk)
    assert Desk.snapshot(desk).mark.position_count == 0
  end

  test "default_opts classifies read-only tools as support and actions as terminal" do
    opts =
      Session.default_opts(
        model: fake_model("operator"),
        stream_options: %{},
        complete_fn: fn _model, _context, _stream_opts -> flunk("unused") end
      )

    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_dashboard"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_floor"})
    assert opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_listings"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_buy"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_sell"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_halt"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_wait"})
    refute opts[:support_tool_matcher].(%AgentTool{name: "tcg_live_close_session"})
    assert opts[:require_executed_call_events?]
  end

  test "action space exposes session tools while in progress and none when complete" do
    collection = "session_tools_#{System.unique_integer([:positive])}"
    desk = start_supervised!({Desk, desk_opts(collection)})
    state = Session.initial_state(desk, [])

    {:ok, tools} = ActionSpace.tools(state, [])
    names = Enum.map(tools, & &1.name)

    assert "tcg_live_buy" in names
    assert "tcg_live_wait" in names
    assert "tcg_live_close_session" in names

    done = LemonSim.Kernel.State.put_world(state, %{status: "complete"})
    assert {:ok, []} = ActionSpace.tools(done, [])
  end

  test "updater rejects unknown event kinds" do
    collection = "session_updater_#{System.unique_integer([:positive])}"
    desk = start_supervised!({Desk, desk_opts(collection)})
    state = Session.initial_state(desk, [])

    assert {:error, {:invalid_tcg_live_event, "tcg_live_mystery"}} =
             Updater.apply_event(state, Event.new("tcg_live_mystery", %{}), [])
  end
end
