# LemonTcg

Live market data and execution for an agent-operated on-chain TCG shop —
the real-world counterpart of `LemonSim.Examples.TcgShop`.

The target market is tokenized graded trading cards (vaulted physical
Pokemon/TCG cards represented as NFTs) on Solana and EVM venues. The app
is paper-trading-first: real quotes, simulated fills, no keys or wallets
required — and a live Collector Crypt venue that builds, signs, and
broadcasts real transactions once a wallet is configured.

## Supported markets

Watchlist entries are venue-qualified (`LemonTcg.Markets`); unqualified
names use the default source.

| Prefix | Venue | Chain | Browse | Buy | Sell | Access |
|---|---|---|---|---|---|---|
| `collector_crypt:` | Collector Crypt (category or `all`) | Solana | ✅ | ✅ live (aggregates ME+Tensor+CC) | ✅ list | no key |
| `phygitals:` | Phygitals (search term or `all`) | Solana | ✅ | — (listings live on Tensor ~86% / ME ~14%; route by `raw["marketplace"]`) | — | no key |
| `opensea:` | OpenSea slug (Courtyard, any Base collection) | Polygon/Base | ✅ | ✅ Seaport fulfillment (EVM signing) | ✅ signed order | **trading** key + EVM wallet |
| `magic_eden:` | Magic Eden symbol | Solana | ✅ | via Collector Crypt aggregation | — | keyless reads |
| `fixture:` | deterministic offline | — | ✅ | ✅ paper | ✅ paper | none |

Parked (not programmatically tradeable today): Phygitals *execution* (its
Tensor-side listings need a gated Tensor API key; pack rip/buyback/redeem
sit behind Privy auth), rip.fun (bot-walled, no discoverable contract),
Tensor (gated key; reachable through Collector Crypt's aggregating buy
anyway).

## Layers

| Layer | Module(s) | Notes |
|---|---|---|
| Market data | `LemonTcg.MarketData` + `Sources.{CollectorCrypt,OpenSea,MagicEden,Fixture}` | Venue-qualified, pluggable, 30s TTL cache. Fixture is deterministic and offline. |
| FX | `LemonTcg.Fx` | Multi-currency → USD (USDC 1:1, SOL/ETH/POL via cached spot). |
| Wallet | `LemonTcg.Wallet` + `SolanaKeypair` / `EvmKeypair` / `Unconfigured` | Solana ed25519 (`Solana.Tx`) and EVM secp256k1 (`Evm.*`) signing, pure Elixir. Default refuses to sign — live venues fail closed. |
| EVM signing | `LemonTcg.Evm.{Keccak,Secp256k1,Rlp,Transaction,Eip712,Rpc}` | Keccak-256, RFC-6979 ECDSA + recovery, RLP, EIP-1559/legacy tx, EIP-712 digest, JSON-RPC. Vector-verified against the Ethereum-book golden tx. |
| Physical comps | `LemonTcg.Comps` + `Sources.PriceCharting` / `Sources.Fixture` | Grade-bucketed slab comps (`LemonTcg.Comps.Grade` parses "PSA 9" etc. from listing names), 10 min TTL. PriceCharting needs `PRICECHARTING_API_TOKEN`. |
| Basis | `LemonTcg.Basis` | Token-vs-physical edge for the buy → redeem → sell-physical round trip, net of taker/redemption/shipping/marketplace fees. |
| Accounting | `LemonTcg.Portfolio`, `LemonTcg.Ledger` | Positions, mark-to-market, append-only audit trail. |
| Risk | `LemonTcg.Risk` | Trade cap, trailing-24h spend cap, collection allowlist, cash reserve, kill switch (blocks buys, never sells). |
| Execution | `LemonTcg.Execution.Venue` + `Venues.Paper` / `Venues.CollectorCrypt` | Paper fills at ask + taker fee; CollectorCrypt builds → signs → broadcasts real Solana txs. Desk `:venue` may be a per-market routing map. |
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

### Live browsing (no keys)

```elixir
LemonTcg.MarketData.listings("collector_crypt:Pokemon", limit: 5)
LemonTcg.MarketData.floor("opensea:courtyard-nft")   # self-provisions an OpenSea key
```

### Live Collector Crypt trading

Route the desk's Collector Crypt market to the live venue and give it a
hot wallet (keep its balance small):

```elixir
Desk.start_link(
  watchlist: ["collector_crypt:Pokemon"],
  venue: %{"collector_crypt" => LemonTcg.Execution.Venues.CollectorCrypt,
           :default => LemonTcg.Execution.Venues.Paper},
  wallet: {LemonTcg.Wallet.SolanaKeypair, keypair_path: "~/.config/solana/id.json"},
  policy: %LemonTcg.Risk.Policy{max_trade_usd: 200.0, allowed_collections: ["collector_crypt:Pokemon"]}
)
```

Buys go build → risk → sign → broadcast; `Desk.sell/2` lists a held card
(pass `list_price_usd` via `market_opts`). Wallet keys resolve from
`config[:secret_key]`, a `solana-keygen` file (`keypair_path` /
`SOLANA_KEYPAIR_FILE`), or base58 `SOLANA_SECRET_KEY`.

### Live OpenSea (EVM) trading

Route the `opensea` market to `Venues.OpenSea` with an `EvmKeypair`
wallet. Two constraints, both fail closed:

- **Buys need a trading-enabled OpenSea key** in `OPENSEA_API_KEY` —
  the self-provisioned read key returns "Account can not perform trading
  operations". Set `evm_rpc_urls` (or `rpc_url`) for the chain.
- Buy only signs a **directly broadcastable** fulfillment tx; if OpenSea
  returns structured ABI args it refuses (`:opensea_fulfillment_shape_unsupported`).
- **Sells** require a caller-built, pre-hashed Seaport order
  (`seaport_order: %{hash: <<32 bytes>>, parameters: ...}`) — the venue
  signs via EIP-712 but never constructs an order blind (a malformed one
  could list a card at 0).

EVM keys resolve from `config[:private_key]` (raw/hex) or
`EVM_PRIVATE_KEY`. The EVM signing stack (`LemonTcg.Evm.*`) is pure
Elixir and vector-verified against the Ethereum-book golden transaction,
but the OpenSea buy path is not yet validated against a live funded
trade — Collector Crypt is the exercised live venue.

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
