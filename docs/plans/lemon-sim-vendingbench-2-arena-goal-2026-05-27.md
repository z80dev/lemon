# LemonSim Vending-Bench 2 Arena Goal

Status: complete

Owner: codex

Worktree: `/home/z80/dev/lemon/.worktrees/vendingbench-2-main`

Branch: `vendingbench-2-main`

Last reviewed: 2026-07-02

## Summary

Implement the Vending-Bench 2 follow-on surface in LemonSim as far as the local
benchmark harness can support it: a 365-day vending business scored by money
balance, plus an Arena mode where multiple agents run independent vending
machines in the same location with shared demand pressure, individual scoring,
inter-agent messages, payments, trades, supplier-lead sales, price-war signals,
and collusion signals.

## Source Bar

- Andon Labs Vending-Bench 2 page: https://andonlabs.com/evals/vending-bench-2
- Andon Labs Vending-Bench Arena page: https://andonlabs.com/evals/vending-bench-arena

## Acceptance

- `mix lemon.sim.vending_bench --preset v2` runs the Vending-Bench 2 horizon
  with a 365-day configuration, money-balance scoring, deterministic market
  research, and structured supplier quote ledgers.
- The deterministic `pressure` strategy exercises market research, structured
  quote history, adversarial suppliers, shutdowns, refunds, spoilage, and
  scorecard failure modes.
- `mix lemon.sim.vending_bench --preset v2 --arena --offline-strategy baseline`
  runs a deterministic multi-agent Arena with configurable agent count.
- Arena state keeps each agent's machine, storage, scorecard, and world state
  separate while distinct price postures and shared same-item pricing affect
  demand.
- Arena worlds expose competitor, direct-message, payment, and trade tools when
  run through the live VendingBench action space.
- Arena artifacts include `final_world.json`, `arena_world.json`,
  `arena_events.jsonl`, `arena_actions.jsonl`, `arena_scorecard.json`,
  standard `scorecard.json`/`manifest.json`/`hashes.json`, and
  `arena_report.md`.
- The watch UI renders Arena worlds with a standings strip, message/payment/trade
  counts, supplier-lead cards, price-war cards, collusion flags, and the leading
  agent's vending machine broadcast.
- Focused LemonSim and LemonSimUI tests pass, followed by a deterministic
  browser-watchable proof run.

## Proof

- `MIX_ENV=test mix test apps/lemon_sim/test/lemon_sim/examples/vending_bench_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/components/board_components_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/spectator_live_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/lobby_live_test.exs`
- `MIX_ENV=test LEMON_STORE_PATH=/tmp/lemon-vb-audit-store mix lemon.sim.vending_bench --preset v2 --offline-strategy pressure --seed 20260612 --sim-id vb_audit_v2_pressure_20260612 --artifact-dir /tmp/lemon-vb-audit-v2-pressure`
- `MIX_ENV=test LEMON_STORE_PATH=/tmp/lemon-vb-audit-store mix lemon.sim.vending_bench --arena --preset v2 --seed 20260613 --sim-id vb_audit_arena_20260613 --offline-strategy baseline --arena-agents 5 --artifact-dir /tmp/lemon-vb-audit-arena`
- `scripts/test fast` was attempted during the 2026-06-11 audit loop and
  remains blocked by unrelated existing non-VendingBench suite failures.

The deterministic pressure proof run writes market research and quote history
into the supplier artifact and scorecard. The deterministic Arena proof run
wrote `/tmp/lemon-vb-audit-arena`, completed day 365, and produced a five-agent
leaderboard with recorded Arena messages, payments, trades, supplier leads,
13 nonzero-spread price-war checkpoints, and a collusion signal.
