# LemonSim Vending-Bench 2 Arena Goal

Status: complete

Owner: codex

Worktree: `/home/z80/dev/lemon/.worktrees/vendingbench-2-main`

Branch: `vendingbench-2-main`

Last reviewed: 2026-05-27

## Summary

Implement the Vending-Bench 2 follow-on surface in LemonSim as far as the local
benchmark harness can support it: a 365-day vending business scored by money
balance, plus an Arena mode where multiple agents run independent vending
machines in the same location with shared demand pressure, individual scoring,
inter-agent messages, and trades.

## Source Bar

- Andon Labs Vending-Bench 2 page: https://andonlabs.com/evals/vending-bench-2
- Andon Labs Vending-Bench Arena page: https://andonlabs.com/evals/vending-bench-arena

## Acceptance

- `mix lemon.sim.vending_bench --preset v2` runs the Vending-Bench 2 horizon
  with a 365-day configuration and money-balance scoring.
- `mix lemon.sim.vending_bench --preset v2 --arena --offline-strategy baseline`
  runs a deterministic multi-agent Arena with configurable agent count.
- Arena state keeps each agent's machine, storage, scorecard, and world state
  separate while shared same-item pricing affects demand.
- Arena artifacts include `final_world.json`, `arena_world.json`,
  `arena_events.jsonl`, `arena_actions.jsonl`, `arena_scorecard.json`, and
  `arena_report.md`.
- The watch UI renders Arena worlds with a standings strip, message/trade
  counts, and the leading agent's vending machine broadcast.
- Focused LemonSim and LemonSimUI tests pass, followed by a deterministic
  browser-watchable proof run.

## Proof

- `MIX_ENV=test mix test apps/lemon_sim/test/lemon_sim/examples/vending_bench_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/components/board_components_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/spectator_live_test.exs apps/lemon_sim_ui/test/lemon_sim_ui/live/lobby_live_test.exs`
- `MIX_ENV=test mix lemon.sim.vending_bench --arena --preset v2 --seed 20260527 --sim-id vb_arena_v2_20260527 --offline-strategy baseline --arena-agents 5 --artifact-dir /tmp/lemon-vb-arena-v2`
- `scripts/test fast`
- `scripts/test quality`

The deterministic proof run wrote `/tmp/lemon-vb-arena-v2`, completed day 365,
and produced a five-agent leaderboard with recorded Arena messages and trades.
