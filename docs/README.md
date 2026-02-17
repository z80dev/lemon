# Documentation Map

This folder is the canonical navigation map for Lemon runtime and harness behavior.

## Start Here

1. [`docs/architecture_boundaries.md`](architecture_boundaries.md) - dependency boundaries and enforcement policy.
2. [`docs/quality_harness.md`](quality_harness.md) - quality checks, evals, and cleanup routines.
3. [`docs/config.md`](config.md) - runtime configuration reference.
4. [`docs/extensions.md`](extensions.md) - extension/plugin API and conflict behavior.

## Runtime Core

- [`docs/assistant_bootstrap_contract.md`](assistant_bootstrap_contract.md)
- [`docs/context.md`](context.md)
- [`docs/telemetry.md`](telemetry.md)
- [`docs/beam_agents.md`](beam_agents.md)

## Product & Capability Docs

- [`docs/skills.md`](skills.md)
- [`docs/benchmarks.md`](benchmarks.md)
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)

## Continuous Improvement Loop

- [`docs/agent-loop/README.md`](agent-loop/README.md)
- [`docs/agent-loop/GOALS.md`](agent-loop/GOALS.md)
- [`docs/agent-loop/RUN_LOG.md`](agent-loop/RUN_LOG.md)

## Maintenance Rules

- Keep `AGENTS.md` short and operational; place durable implementation details in `docs/` files.
- Register every tracked docs file in [`docs/catalog.exs`](catalog.exs) with `owner`, `last_reviewed`, and `max_age_days`.
- Run `mix lemon.quality` after docs edits or app dependency changes.
