# Drive the live TCG desk with the sim kernel's agent loop.
#
#   mix run scripts/tcg_agent_loop_demo.exs            # scripted operator, offline
#   mix run scripts/tcg_agent_loop_demo.exs -- --model # configured LLM, offline quotes
#
# The scripted mode needs no model or keys: a canned operator browses,
# buys the cheapest listing, checks the dashboard, sells, and closes.
# --model resolves the configured Lemon default model and lets it trade
# fixture quotes on the paper venue for a few turns.

alias Ai.Types.{AssistantMessage, Model, ToolCall}
alias LemonTcg.Agent.Session
alias LemonTcg.MarketData.Sources.Fixture
alias LemonTcg.Risk.Policy

collection = "demo_vaulted_cards"
mint = "#{collection}_mint_1"

desk_opts = [
  starting_cash_usd: 2_000.0,
  watchlist: [collection],
  market_opts: [source: Fixture, fresh?: true],
  policy: %Policy{
    max_trade_usd: 750.0,
    max_daily_spend_usd: 1_500.0,
    min_cash_reserve_usd: 100.0,
    allowed_collections: [collection]
  }
]

use_model? = "--model" in System.argv()

tool_call = fn name, args ->
  %ToolCall{
    type: :tool_call,
    id: "call_#{name}_#{System.unique_integer([:positive])}",
    name: name,
    arguments: args
  }
end

scripted_opts =
  if use_model? do
    [max_turns: 4]
  else
    script = [
      [
        tool_call.("tcg_live_listings", %{"collection" => collection}),
        tool_call.("tcg_live_buy", %{"collection" => collection, "mint" => mint})
      ],
      [
        tool_call.("tcg_live_dashboard", %{}),
        tool_call.("tcg_live_sell", %{"mint" => mint})
      ],
      [tool_call.("tcg_live_close_session", %{"reason" => "demo complete"})]
    ]

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _context, _stream_opts ->
      turn = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      {:ok,
       %AssistantMessage{
         role: :assistant,
         content: Enum.at(script, min(turn, length(script) - 1)),
         stop_reason: :tool_use,
         timestamp: System.system_time(:millisecond)
       }}
    end

    model = %Model{
      id: "scripted-operator",
      name: "scripted-operator",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{}
    }

    [model: model, stream_options: %{}, complete_fn: complete_fn, max_turns: 4]
  end

IO.puts("== TCG agent loop demo (#{if use_model?, do: "configured model", else: "scripted"}) ==")

case Session.run([desk_opts: desk_opts] ++ scripted_opts) do
  {:ok, final} ->
    mark = final.world.snapshot.mark

    IO.puts("Session status: #{final.world.status} after turn #{final.world.turn}")
    IO.puts("Actions taken:")

    Enum.each(final.world.action_history, fn action ->
      IO.puts("  #{action.kind}: #{inspect(action.payload)}")
    end)

    IO.puts(
      "Final: net worth $#{mark.net_worth_usd}, cash $#{mark.cash_usd}, " <>
        "realized P&L $#{mark.realized_pnl_usd}, fees $#{mark.fees_usd}, " <>
        "invalid actions #{final.world.invalid_action_count}"
    )

  {:error, reason} ->
    IO.puts("Session failed: #{inspect(reason)}")
end
