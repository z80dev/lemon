# VendingBench

VendingBench is LemonSim's vending-machine business benchmark. One operator
starts with $500 and tries to run a 4x3 machine under deterministic demand,
supplier, inventory, and worker constraints.

## What It Simulates

The world starts with:

- a 12-slot machine: four rows by three columns
- $500 bank balance and a $2 daily operating fee
- bankruptcy after 10 consecutive unpaid daily fees
- storage capacity, delivered inventory batches, spoilage, and overflow discard
- weather, season, weekday, month, price elasticity, and product-variety demand
- same-day customer refunds when sale price exceeds 180% of reference price
- a nested physical-worker subagent for on-site work

The catalog covers drinks, snacks, and prepared food. Prepared food has short
shelf life, so good operators must balance demand against spoilage.

## Supplier Market

The benchmark uses eight deterministic suppliers:

| Supplier | Behavior |
| --- | --- |
| `freshco` | Honest, fast beverage and prepared-food supplier |
| `snackworld` | Honest snack specialist |
| `drinkdepot` | Honest bulk supplier with larger minimums |
| `campusliquidators` | Negotiable closeout supplier |
| `budgetvend` | Adversarial overpricing broker |
| `quickcrate` | Low-cost but sometimes delayed logistics supplier |
| `switcheroo` | Bait-and-switch supplier that may ship substitutes |
| `ghostsupply` | Cheap supplier that shuts down after day 2 |

Operators can inspect suppliers, research market notes, request quotes, place
orders, read inbox replies, create reminders, dispatch the worker, and wait for
the next day.

## Physical Worker

Live runs use a real nested worker through `AgentCore.SubagentSupervisor`. The
worker has its own tool loop, model options, and memory namespace. It can
inspect inventory, stock products, collect cash, set prices, remove expired
items, report machine faults, and finish a visit. The worker mutates only a
local visit snapshot; VendingBench still applies authoritative events through
the updater.

Offline strategies emit deterministic worker events directly so CI can run
without model credentials.

## Presets And Modes

| Mode | Shape |
| --- | --- |
| `ci` | 7 simulated days, 25 driver turns, no persistence |
| `paper` | 365 simulated days, 2,000 driver turns |
| `v2` | 365 simulated days, 4,000 driver turns |
| `--arena` | Multi-agent deterministic Vending-Bench Arena mode |

Arena mode runs several operators at one location. It applies same-item price
pressure and emits inter-agent messages, payments, trades, supplier-lead sales,
price-war signals, and collusion signals.

## Scoring

The registered primary metric is `score_modes.v1_net_worth`, maximized. The
scorecard also reports:

| Score mode | Meaning |
| --- | --- |
| `v1_net_worth` | Bank balance plus machine cash plus wholesale inventory value |
| `money_balance` | Bank balance only |
| `lemon_operational_score` | Net-worth improvement plus sales and margin, minus operational penalties |

Failure-mode flags are part of the scorecard:

- `repeated_invalid_actions`
- `chronic_stockouts`
- `supplier_overtrust`
- `unmanaged_spoilage`
- `customer_trust_damage`
- `task_abandonment`
- `cash_flow_risk`

## Comparison To Andon Labs Vending-Bench

| Area | Andon Labs Vending-Bench 2 | LemonSim VendingBench |
| --- | --- | --- |
| Time horizon | 365 simulated days | `paper` and `v2` are 365 simulated days; `ci` is 7 days |
| Starting cash | $500 | $500 |
| Primary cash metric | Net cash, averaged over 5 runs per model | `v1_net_worth` by default; suites aggregate per-seed values |
| Supplier friction | Adversarial suppliers, failed deliveries, refund demands | Deterministic adversarial, delayed, bait-and-switch, shutdown, quote, and refund mechanics |
| External world | Live internet search and real email ordering | Deterministic offline supplier and market corpora |
| Reproducibility | Depends on live web/email conditions | Seeded, deterministic, byte-reproducible bundles with `--deterministic-artifacts` |
| Evaluator | Unpublished evaluator | Published scorecard and verifier in the repo |
| Artifacts | Not a public hash-verified bundle contract | Manifest and file-hash verified run bundles |
| Accounting | Benchmark result focus | Per-run token and USD cost accounting in `usage.json` |
| Multi-agent mode | Single-operator benchmark | Single-operator and multi-agent Arena mode |

The key tradeoff is intentional: LemonSim does not claim live-internet or
real-email realism for VendingBench. It chooses deterministic corpora and
verifiable artifacts so results can be rerun, audited, and compared without
depending on a changing external web.

