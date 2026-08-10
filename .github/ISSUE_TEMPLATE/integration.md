---
name: Integration / extension
about: Propose or track a new channel, engine, storage backend, or memory provider
labels: integration
assignees: z80
---

## What are you adding

Which extension point does this integration implement?

- [ ] Channel adapter (`LemonChannels.Plugin`)
- [ ] Engine (`LemonGateway.Engine`)
- [ ] Storage backend (`LemonCore.Store.Backend`)
- [ ] Memory provider (`LemonMemory.Provider`)
- [ ] Other: ___

## The integration

What is it — Slack, an SMS provider, Postgres storage, a vector store — and what
does it connect Lemon to? A sentence or two.

## Where will it live

- [ ] In this repo (an app under `apps/` or a built-in adapter)
- [ ] In its own package that registers itself at boot (like the X integration)
- [ ] Not sure yet

## Compliance suite

The matching `lemon_platform_test` case is the contract. See
[CONTRIBUTING.md](../../CONTRIBUTING.md#running-the-contract-kit).

- [ ] I have run the compliance suite against my implementation
- [ ] It passes
- [ ] I need help getting it to pass (describe below)

## External requirements

Does this need API keys, a running service, or a paid account to test? How
should a reviewer exercise it without live credentials?

## Additional context

Prior art, links to the service's API docs, anything else worth knowing.
