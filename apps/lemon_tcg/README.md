# LemonTcg

Live market data and execution for an agent-operated on-chain TCG shop —
the real-world counterpart of `LemonSim.Examples.TcgShop`.

The target market is tokenized graded trading cards (vaulted physical
Pokemon/TCG cards represented as NFTs) on venues like Magic Eden. The app
is paper-trading-first: real quotes, simulated fills, no keys or wallets
required. On-chain signing venues plug in later behind the same
`LemonTcg.Execution.Venue` behaviour.

## Layers

| Layer | Module(s) | Notes |
|---|---|---|
| Market data | `LemonTcg.MarketData` + `Sources.MagicEden` / `Sources.Fixture` | Pluggable sources, 30s TTL cache. Fixture is deterministic and offline. |
| Physical comps | `LemonTcg.Comps` + `Sources.PriceCharting` / `Sources.Fixture` | Grade-bucketed slab comps (`LemonTcg.Comps.Grade` parses "PSA 9" etc. from listing names), 10 min TTL. PriceCharting needs `PRICECHARTING_API_TOKEN`. |
| Basis | `LemonTcg.Basis` | Token-vs-physical edge for the buy → redeem → sell-physical round trip, net of taker/redemption/shipping/marketplace fees. |
| Accounting | `LemonTcg.Portfolio`, `LemonTcg.Ledger` | Positions, mark-to-market, append-only audit trail. |
| Risk | `LemonTcg.Risk` | Trade cap, trailing-24h spend cap, collection allowlist, cash reserve, kill switch (blocks buys, never sells). |
| Execution | `LemonTcg.Execution.Venue` + `Venues.Paper` | Paper venue fills at ask + taker fee; exits at floor − haircut. |
| Session | `LemonTcg.Desk` | GenServer; serializes quote → risk → venue → ledger. |
| Agent surface | `LemonTcg.Agent.Tools` | `tcg_live_*` AgentTools mirroring the sim's action space. |
| Agent loop | `LemonTcg.Agent.Session` (+ `ActionSpace`, `Updater`) | Runs the LemonSim kernel (SectionedProjector → ToolLoopDecider → ExecutedCallEvents) against a live desk. |

## Quick start (offline paper trading)

```elixir
alias LemonTcg.{Desk, Risk.Policy}
alias LemonTcg.MarketData.Sources.Fixture

{:ok, desk} =
  Desk.start_link(
    starting_cash_usd: 1_000.0,
    watchlist: ["my_collection"],
    market_opts: [source: Fixture],
    policy: %Policy{max_trade_usd: 500.0}
  )

{:ok, listings} = Desk.listings(desk, "my_collection")
{:ok, fill} = Desk.buy(desk, "my_collection", hd(listings).mint)
Desk.snapshot(desk)
```

Against live Magic Eden data, drop `market_opts` (or set
`market_opts: []`) and use real collection symbols in the watchlist.
`MAGIC_EDEN_API_KEY` is optional and only raises rate limits. Run the demo:

```sh
mix run scripts/tcg_live_demo.exs                 # offline fixture data
mix run scripts/tcg_live_demo.exs -- --live SYMBOL  # live Magic Eden quotes, paper fills
```

## Agent loop

`LemonTcg.Agent.Session.run/1` drives the desk with the same kernel stack
the sim games use — each turn the model inspects with support tools, then
takes exactly one terminal action (buy/sell/halt/wait/close):

```sh
mix run scripts/tcg_agent_loop_demo.exs            # scripted operator, offline
mix run scripts/tcg_agent_loop_demo.exs -- --model # configured Lemon model
```

Pass `desk_opts` to let the session own a desk, or `desk: pid` to attach
to one you manage. `turn_interval_ms` paces `tcg_live_wait` against real
market refresh cadence.

## Comps and basis

`Desk.comp/3` returns a grade-matched physical price; `Desk.basis/5`
evaluates a live listing against it end to end. The agent gets both as
support tools (`tcg_live_check_comp`, `tcg_live_price_basis`) and is
prompted to price basis before any buy — a discount to comp can still be
a negative-edge trade once fees, redemption, and shipping are paid.
Comp sources plug in via `market_opts[:comp_source]`; grade buckets below
9 fall back to the grade-9 comp and should be read as upper bounds.

## Roadmap

1. **Live venues** — Magic Eden buy-now instruction building + wallet
   signing behind `Execution.Venue`, gated by the risk policy plus human
   approval thresholds.
2. **Persistence** — desk session snapshots via `LemonCore` storage so
   restarts keep the ledger (and the daily-spend window) intact.
