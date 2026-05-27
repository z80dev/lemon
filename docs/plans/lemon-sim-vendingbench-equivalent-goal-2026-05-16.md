# LemonSim Vending-Bench 1.0 Equivalent Goal

Status: active

Owner: codex

Worktree: `/home/z80/dev/lemon/.worktrees/vendingbench-1-main`

Branch: `vendingbench-1-main`

Last reviewed: 2026-05-27

## Summary

Implement and merge a LemonSim equivalent of the original Vending-Bench
benchmark. The official evaluator is not published as a runnable package, so
the Lemon target is a paper-grounded equivalent that preserves the benchmark
shape: a long-horizon vending machine business, tool-first operator decisions,
physical-worker subagent execution, supplier ordering, daily sales, operating
fees, bankruptcy, and net-worth scoring.

## Source Bar

- Original Vending-Bench paper: https://arxiv.org/html/2502.15840
- Andon Labs Vending-Bench page: https://andonlabs.com/evals/vending-bench

The 1.0 target is the original single-agent vending-machine operation. Vending
Bench 2 and Arena are separate follow-on targets and are not part of this merge.

## Acceptance

- `mix lemon.sim.vending_bench --preset paper` runs a benchmark-length
  365-day, 2,000-driver-turn configuration.
- `mix lemon.sim.vending_bench --preset ci --offline-strategy baseline` runs a
  deterministic short fixture path without model credentials.
- The simulation models a 4 x 3 machine with small top rows and large bottom
  rows, 10-day unpaid-fee bankruptcy, supplier email/research behavior,
  delivery delays, storage capacity, spoilage, refunds, daily demand, and
  physical-worker-only machine mutations.
- Scoring reports Vending-Bench 1.0 net worth as the primary score, plus
  supporting money balance, operational score, and failure-mode flags.
- Runs with `--artifact-dir` write `final_world.json`, `events.jsonl`,
  `actions.jsonl`, `supplier_messages.json`, `worker_history.json`,
  `operator_transcript.json`, `reminders.json`, `scorecard.json`, `report.md`,
  `replay.json`, and `replay.html`.
- The web spectator surface renders VendingBench as a watchable operations
  broadcast with machine slots, sales, supplier messages, deliveries, refunds,
  worker reports, progress, story beats, and scorecard signals.
- Focused LemonSim and LemonSimUI tests pass, followed by repo quality checks.

## Merge Plan

1. Port the prior VendingBench implementation from the parked worktree onto a
   fresh branch from current `main`.
2. Remove V2/Arena public surface from this branch and align mechanics/docs to
   Vending-Bench 1.0.
3. Polish the VendingBench board for a sleek, fun watch experience.
4. Regenerate deterministic fixture artifacts.
5. Run focused tests, format, quality, then merge the branch into local `main`.
