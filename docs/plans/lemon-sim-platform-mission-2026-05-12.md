# LemonSim Platform Mission

Status: active product mission

Last reviewed: 2026-05-12

## Summary

Lemon should be more than "Hermes on BEAM." The agent runtime still needs
Hermes-class reliability, but Lemon should also become a mature platform for
running, watching, replaying, and benchmarking agent simulations through
`lemon_sim` and `lemon_sim_ui`.

The flagship simulation goals are:

- make Werewolf a proper social-deduction game that is fun to watch, not only a
  benchmark harness
- deliver a full Vending Bench 2.0 implementation that exercises nested
  operator/worker agents, business strategy, supplier negotiation, physical
  execution, and objective scoring

## Product Bar

LemonSim is mature when a viewer or operator can:

1. Start a simulation from a release runtime or admin UI.
2. Watch the game unfold live with understandable pacing and state.
3. Replay a completed run with the important hidden-information beats exposed
   where appropriate.
4. Compare model/player performance with objective metrics.
5. Diagnose failures from transcripts, event logs, support bundles, and saved
   world snapshots.
6. Add new simulation domains without modifying LemonSim core contracts.

This mission does not replace the Lemon 1.0 launch gate. It extends the product
direction: Lemon should compete with Hermes as an agent harness while also
being the stronger BEAM-native simulation platform.

## Current Assets

Existing useful foundation:

- `apps/lemon_sim` provides state, events, updater/action-space/projector
  contracts, tool-loop decisions, memory tools, persistence, and runner
  orchestration.
- `apps/lemon_sim_ui` provides admin start/stop flows, public watch pages, a
  lobby, domain summaries, and Werewolf playback pacing.
- Werewolf already has role logic, visibility boundaries, action spaces,
  updater tests, transcript logging, replay storyboard generation, video replay
  tooling, and role-aware performance summaries.
- Vending Bench already has a single-operator vending-machine business world,
  demand model, suppliers, updater/action-space modules, physical-worker
  subagent flow, performance summary code, and a runnable Mix task.

## Werewolf Mission

Werewolf should become the canonical watchable LemonSim game.

### Experience Requirements

- A viewer can open a public watch page and understand the current day/night
  phase, living players, roles when viewer-appropriate, claims, accusations,
  votes, night actions, and win condition pressure.
- The public timeline reads like a game broadcast: discussion beats, vote
  swings, night kills, seer checks, doctor saves, wolf coordination, and final
  reveals are all legible.
- Hidden information is handled intentionally: player/projector context stays
  private, while replay/spectator views may be audience-omniscient when the
  page is explicitly a replay or broadcast view.
- The game has enough pacing control to be fun to watch: no unreadable rapid
  bursts, no dead air, no infinite accusation loops, and no trivial opening
  configurations.
- The output is useful as a benchmark: vote accuracy, wolf kill conversion,
  seer check value, doctor save value, deception quality, and survival impact
  are recorded by role and model.

### Implementation Targets

- Tighten game mechanics around nominations, defense, vote runoff, night action
  ordering, doctor protection, seer checks, wolf coordination, tie handling,
  and win-condition checks.
- Improve character/lore generation so players have memorable voices without
  harming strategic clarity.
- Make the watch UI broadcast-first: readable phase banners, player cards,
  claim/vote panels, hidden-action reveal moments, and compressed event
  history.
- Make replay artifacts first-class: JSONL transcript, storyboard beats,
  optional video, metrics summary, and shareable watch URL.
- Add deterministic fixture games for key story arcs: quick wolf win, village
  comeback, seer reveal, doctor save, tie/runoff, and misdirection by a wolf.
- Add live multi-model dogfood runs as release-candidate evidence before
  marketing Werewolf as a showcase.

### Acceptance Criteria

- `mix test apps/lemon_sim` covers Werewolf rules, visibility, transcript,
  replay, and performance metrics.
- `mix test apps/lemon_sim_ui` covers public watcher rendering and readable
  playback behavior for representative Werewolf states.
- A release-runtime `sim_broadcast_platform` deployment can start a Werewolf
  game and expose a public `/watch/:sim_id` page.
- At least three saved example runs are documented: one entertaining replay,
  one model-comparison benchmark, and one failure/debug case.
- Website/demo docs link to a Werewolf replay and explain what LemonSim is
  measuring.

## Vending Bench 2.0 Mission

Vending Bench 2.0 should become the canonical business-operation simulation for
nested Lemon agents.

### Experience Requirements

- An operator agent runs a vending-machine business over a fixed season with
  money, inventory, customer demand, supplier constraints, and physical machine
  operations.
- A physical-worker subagent can be dispatched with instructions and limited
  situational awareness, then reports back through structured events.
- Supplier decisions matter: price, lead time, reliability, refund behavior,
  product mix, perishability, storage limits, and negotiation all affect
  outcomes.
- The machine itself is concrete: slots, capacity, restocking, pricing,
  spoilage, cash collection, maintenance, outages, and customer complaints are
  visible and actionable.
- The benchmark rewards robust operations, not lucky final balance only.

### Implementation Targets

- Define the Vending Bench 2.0 spec: world model, event schema, terminal
  actions, support tools, scoring, failure modes, and replay format.
- Expand the demand model with location/daypart/season/weather/product-fit
  effects and deterministic seeded variation.
- Expand suppliers with contracts, negotiation, substitutions, delivery
  failures, refunds, bulk discounts, and relationship effects.
- Expand physical work with travel time, task checklists, partial completion,
  mistakes, machine observations, and repair/restock/cash-collection reports.
- Add business constraints: spoilage, storage capacity, stockouts, price
  elasticity, maintenance, theft/loss, daily fees, and bankruptcy.
- Add objective performance metrics: net worth, service level, stockout rate,
  spoilage loss, gross margin, demand capture, complaint rate, worker
  efficiency, supplier reliability, and recovery from incidents.
- Add UI support in `lemon_sim_ui`: machine board, inventory/cash panels,
  supplier inbox, worker log, sales chart, and final scorecard.

### Acceptance Criteria

- `mix lemon.sim.vending_bench` can run a full deterministic 30-day game to a
  terminal score without manual intervention.
- `mix test apps/lemon_sim` includes Vending Bench 2.0 updater, action-space,
  demand, supplier, worker, and performance tests.
- `mix test apps/lemon_sim_ui` includes Vending Bench board/summary rendering.
- A saved Vending Bench 2.0 replay demonstrates a non-trivial strategy arc:
  product choice, supplier tradeoff, restock timing, pricing adjustment,
  incident recovery, and final score.
- The release site explains Vending Bench as a benchmark for nested
  operator/worker agents and practical business planning.

## Platform Workstream

These improvements support both games and future domains:

- Stable simulation run packaging: start, stop, resume, export, replay, and
  support-bundle commands for release runtimes.
- Spectator-grade event stream contracts: compact event types, stable domain
  summaries, replay-safe hidden-information markers, and deterministic
  timestamps or sequence numbers.
- Benchmark registry: each domain declares metrics, scorecards, fixture runs,
  and model comparison outputs.
- Demo asset pipeline: saved transcripts, screenshots, videos, and public watch
  links that can be used on the website.
- Domain authoring guide: how to build a new LemonSim game without changing the
  core harness.

## Relationship To 1.0

For Lemon 1.0 stable launch:

- The core agent runtime and channel reliability gates remain P0.
- LemonSim platform positioning should be public, but Werewolf and Vending
  Bench 2.0 should be marketed according to their actual evidence level.
- Werewolf may be a launch showcase only if watch/replay/demo evidence is fresh
  and reproducible.
- Vending Bench 2.0 is a product mission unless its full 30-day run, UI, tests,
  and replay artifacts are completed before release.

The mission is successful when Lemon is credible in both directions: a
Hermes-class BEAM agent runtime, and a simulation platform with games and
benchmarks people actually want to watch.
