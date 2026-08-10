# Lemon

[![Quality](https://github.com/z80dev/lemon/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/z80dev/lemon/actions/workflows/quality.yml)
[![Dialyzer](https://github.com/z80dev/lemon/actions/workflows/dialyzer.yml/badge.svg?branch=main)](https://github.com/z80dev/lemon/actions/workflows/dialyzer.yml)
[![Simulation Bench](https://github.com/z80dev/lemon/actions/workflows/sim-bench.yml/badge.svg?branch=main)](https://github.com/z80dev/lemon/actions/workflows/sim-bench.yml)
[![OSV Scanner](https://github.com/z80dev/lemon/actions/workflows/osv-scanner.yml/badge.svg?branch=main)](https://github.com/z80dev/lemon/actions/workflows/osv-scanner.yml)

Lemon is a platform for building agents on the BEAM: supervised per-run agent
processes, multi-channel ingress, pluggable execution engines, durable memory,
and a benchmark arena for scoring model behaviour. It is an Elixir umbrella
today and is mid-way through a split into a small set of semver'd Hex packages
plus a batteries-included reference runtime that wires them together.

Concretely, the tree contains:

- **Agent runtime** — agent loop, tool registry, subagents, model runtime,
  and workspace stores (`apps/agent_core`).
- **Channels** — Telegram, Discord, WhatsApp and XMTP adapters behind one
  `LemonChannels.Plugin` behaviour, plus outbox/dispatcher/presentation
  ([`plugin.ex`](apps/lemon_channels/lib/lemon_channels/plugin.ex)). Email is
  mid-port from the legacy gateway transport; see
  [`docs/platform/transport-unification.md`](docs/platform/transport-unification.md).
- **Engines** — one `LemonGateway.Engine` behaviour with an in-process
  implementation plus six CLI coding agents (Claude Code, Codex, Droid, Kimi,
  OpenCode, Pi) in [`apps/lemon_gateway/lib/lemon_gateway/engines`](apps/lemon_gateway/lib/lemon_gateway/engines).
- **Run lifecycle** — single-flight, queue/steer/coalesce, policy, watchdog,
  delivery routing (`apps/lemon_router`).
- **Providers** — a provider-agnostic LLM client with rate limiting, circuit
  breaking, compaction and token accounting, with zero umbrella dependencies
  (`apps/ai`).
- **Memory** — document schema, SQLite-backed store, a `Provider` behaviour
  with a fan-out registry, ingest pipeline and session search
  (`apps/lemon_memory`).
- **Arenas** — an event-sourced simulation kernel, 16 scored scenarios, and
  always-on model leagues (`apps/lemon_sim`, `apps/lemon_sim_ui`).

The premise: an LLM product is already a distributed system — conversations run
concurrently, tool calls block, providers fail, users interrupt, sessions
outlive requests — so it belongs on a runtime that supervises processes rather
than on queue glue wrapped around one. The full argument, costs included, is
[Agents Are a Concurrency Problem](docs/why-beam-for-agents.md); the invariants
that fall out of it are written down in [`docs/beam_agents.md`](docs/beam_agents.md).

## Architecture

The target shape is eight published packages, a reference runtime that stays
in this repo, and products that consume the packages exactly as a third party
would.

| Package | Contents |
| --- | --- |
| `lemon_ai` | Providers, registry, rate limiting, circuit breaker, compaction, tokens/text |
| `lemon_core` | Bus, `Event` envelope, `Store` + backends, secrets, config, boundary contracts, primitives |
| `lemon_agent` | Agent loop, tool registry, subagents, model runtime, CLI runners, workspace stores |
| `lemon_memory` | Document schema, store, `Provider` behaviour + registry, ingest, search |
| `lemon_router` | Run lifecycle and session orchestration |
| `lemon_gateway` | Engine execution runtime: `Engine` behaviour, registry, scheduler, locks |
| `lemon_channels` | Channel core, `Plugin` behaviour, built-in adapters |
| `lemon_platform_test` | Contract-test kit for `Plugin`/`Engine`/`Store.Backend`/`Memory.Provider` authors |

**Reference runtime** (in-repo, unpublished): control plane, CLI, web UI,
automation, skills, media, browser, LSP. **Products** (leaving for their own
repos): the coding agent, the sim arenas, the showcase site, the TS clients.
**Satellites** are the model for vendor integrations — `apps/x_api` carries the
X client, its channel adapter and its three tools, and self-registers at boot,
so the platform holds zero compile-time knowledge of X.

Dependencies flow one way, and the direction is enforced rather than
documented:

```
lemon_ai ← lemon_agent ← {router, gateway, channels, skills, products}
lemon_core ← everything
lemon_memory ← {router (ingest hook), skills, products}
router ⇄ gateway: ONLY via LemonCore.EngineRuntime behaviour (config-injected)
channels → router: ONLY via LemonCore.RouterBridge
router → channels: Dispatcher/Outbox facade only (the one allowed compile-time edge)
products/satellites → platform: hex deps; platform NEVER depends on a product
```

**State of the split.** Phase 1 (carving a product-free `lemon_core`) and
Phase 2 (inverting the wrong-direction dependencies) are complete except for
the email channel port; Phase 3 (contracts, docs, test kit) is in flight.
Nothing is on Hex yet. The plan of record is
[`docs/platform-split.md`](docs/platform-split.md) — a living document with the
evidence behind each decision, a numbered decision log, and work items checked
off in place. Per-package pages are in [`docs/platform/`](docs/platform).

## Engineering

Claims here are links, not adjectives.

**Boundaries are compiler-checked, and the allowlist is empty.**
[`architecture_rules_check.ex`](apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex)
resolves the dependency rules above from each file's AST, so aliases, calls and
dynamic `:"Elixir.Foo"` atoms all count while mentions in comments do not. It
started with a 29-entry shrink-only `@grandfathered` list grouped by the work
item that would retire each group; that list is now `[]`. A separate
[direct-dependency policy](docs/architecture_boundaries.md) is generated from
the actual `mix.exs` graph. Both run in `mix lemon.quality` on every push.

**Third parties can test their own implementations.**
[`apps/lemon_platform_test`](apps/lemon_platform_test/README.md) ships four
`ExUnit.CaseTemplate`s — `BackendCase`, `PluginCase`, `EngineCase`,
`ProviderCase` — used as `use LemonPlatformTest.PluginCase, adapter:
MyAdapter`. They are safe by default: nothing delivers a message, starts a run
or opens a socket without an explicit probe, because a compliance suite that
posts to a live bot is worse than none. Registration round-trips are included,
since "works standalone, invisible to the platform" is the common integration
failure. The kit was validated by running a deliberately-broken backend through
`BackendCase` to confirm it fails rather than passing vacuously, and by running
`XApi.ChannelAdapter` and `CodingAgent.GatewayEngine` through it *from their own
apps* — the dependency direction a third party has.

**Configuration is typed and owned by its reader.** 260 environment-variable
declarations live in 16 per-app registry modules aggregated through
`config :lemon_core, :env_registries`
([`config/config.exs`](config/config.exs)); registries missing from a given
build are skipped, so the aggregate always describes what the build can
actually read. Ownership is by reader, not by name prefix.

**Tests are deterministic and numerous.** 887 test files, ~318k lines under
`apps/*/test`. The runner (`scripts/test`) scrubs ambient provider credentials
and provisions per-invocation temp dirs so a lane cannot silently reach the
network or a developer's real store; CI re-runs the historically flaky suites
twice per build. Library-ification is proved by tests, not asserted:
[`store_instance_test.exs`](apps/lemon_core/test/lemon_core/store_instance_test.exs)
runs two independently-named stores with isolated caches in one node.

**Dependencies are scanned; work is not parked in comments.** OSV-Scanner runs
over the Elixir, Node and Python manifests on every lockfile change and again
weekly ([`osv-scanner.yml`](.github/workflows/osv-scanner.yml)). Grep `apps/`
for `TODO` and you get two hits, both string literals inside a truncation
heuristic rather than deferred work, and there are no `FIXME` markers at all
across ~425k lines of Elixir.

**The plan gets corrected by the code.** Two entries in the decision log are
reversals of my own earlier decisions after reading the source: **D2** —
"move all five gateway transports to the channel `Plugin` behaviour" was
abandoned because `Plugin.deliver/1` is fire-and-forget and cannot return a
synchronous HTTP response into the originating request; only email actually
fits, and the rest stay as non-channel ingress. **D11** — `chat_state` was
slated to move to the router as its sole owner, but `lemon_channels` turned out
to read *and* write it, and channels may not depend on the router, so moving it
would have encoded an accident as architecture. Both are written up with
evidence in [§8 of the plan](docs/platform-split.md).

## Quickstart

To build your own agent on the platform, `mix lemon.new` scaffolds a project
with one example tool and one channel wired:

```bash
# from a checkout of this repo; the subshell keeps the cd from leaking
(cd installer && MIX_ENV=prod mix archive.build && mix archive.install --force lemon_new-0.1.0.ez)

cd ~/code                              # anywhere outside this repo
mix lemon.new my_agent --channel --memory
cd my_agent && mix test
```

The generator lives in [`installer/`](installer/README.md) and is installed as
a Mix archive rather than fetched from Hex, because the platform packages are
not published yet — generated projects depend on them by path, baked in from
the checkout the archive was built from and overridable with `--lemon-path` or
`$LEMON_PATH`. Both flags are optional: a bare `mix lemon.new my_agent` gives a
working project too. The guides it is written against are in
[`docs/getting-started/`](docs/getting-started/build-your-first-agent.md):
build your first agent, add a tool, add a channel, persist memory.

Running the reference runtime from a source checkout works today. Requires
Elixir 1.19.5+ / OTP 28.5+ (pinned in `.tool-versions`) and a model provider
key:

```bash
git clone https://github.com/z80dev/lemon.git && cd lemon
mix deps.get && mix compile
mix lemon.secrets.set llm_anthropic_api_key_raw "sk-ant-..."
./bin/lemon doctor            # environment + config diagnostics
./bin/lemon                   # web console on :4080, ops dashboard at /ops
./bin/lemon-dev /path/to/repo # terminal UI
./bin/lemon-gateway           # Telegram/Discord gateway
```

Configuration lives in `~/.lemon/config.toml`; the full reference is
[`docs/config.md`](docs/config.md) and first-run setup, including the Telegram
bot walkthrough, is [`docs/user-guide/setup.md`](docs/user-guide/setup.md).

Any shell or CI job can push a message into a channel with
`./bin/lemon send --to telegram:<chat_id> "deploy finished"`, including file
attachments, thread/reply targeting, named targets and a credential-free
`--dry-run`. The full reference is in
[`apps/lemon_channels/README.md`](apps/lemon_channels/README.md#script-notifications).

## Arenas

The most visible thing the platform does is run models against each other. An
arena keeps a league game running continuously for one simulation domain,
samples a randomized model lineup per game, and records every finished game
into persistent standings, resuming games that die mid-flight and reconciling
unrecorded results on restart. Five domains are wired: werewolf, space station,
stock market, survivor, poker — served at `/arena/:domain`,
`/arena/:domain/leaderboard`, and a cross-domain `/leaderboards`, all in
`apps/lemon_sim_ui`. Enable one with `LEMON_ARENA_<DOMAIN>_ENABLED` and
`LEMON_ARENA_<DOMAIN>_MODELS`.

Results are meant to be checkable: every run writes a hash-manifested artifact
bundle, each scenario's scorecard is a pure function of final world state that
the verifier recomputes and diffs, and per-actor token and cost usage is
recorded alongside. On top of single runs sit benchmark suites (competitors ×
seeds matrices) and order-independent Bradley-Terry model ratings fit over
pairwise seed-level comparisons.

No API keys needed for a deterministic run:

```bash
mix lemon.sim.tic_tac_toe --offline-strategy random --seed 42 --no-persist --max-turns 10
mix lemon.sim.vending_bench --preset ci --offline-strategy baseline --sim-id vb_ci
mix lemon.sim.verify apps/lemon_sim/priv/game_logs/vending_bench/vb_ci
mix lemon.sim.score  apps/lemon_sim/priv/game_logs/vending_bench/vb_ci
```

The arena guide is [`apps/lemon_sim/README.md`](apps/lemon_sim/README.md).

## Repository map

Every app has its own README; these are the ones worth reading first.

| Layer | Apps |
| --- | --- |
| Platform | [`ai`](apps/ai/README.md), [`lemon_core`](apps/lemon_core/README.md), [`agent_core`](apps/agent_core/README.md), `lemon_memory`, [`lemon_router`](apps/lemon_router/README.md), [`lemon_gateway`](apps/lemon_gateway/README.md), [`lemon_channels`](apps/lemon_channels/README.md), [`lemon_platform_test`](apps/lemon_platform_test/README.md) |
| Reference runtime | [`lemon_control_plane`](apps/lemon_control_plane/README.md), [`lemon_cli`](apps/lemon_cli/README.md), [`lemon_web`](apps/lemon_web/README.md), [`lemon_automation`](apps/lemon_automation/README.md), [`lemon_skills`](apps/lemon_skills/README.md), [`lemon_media`](apps/lemon_media/README.md), [`lemon_browser`](apps/lemon_browser/README.md), [`lemon_lsp`](apps/lemon_lsp/README.md) |
| Products | [`coding_agent`](apps/coding_agent/README.md), [`coding_agent_ui`](apps/coding_agent_ui/README.md), [`lemon_mcp`](apps/lemon_mcp/README.md), [`lemon_evals`](apps/lemon_evals/README.md), [`lemon_sim`](apps/lemon_sim/README.md), [`lemon_sim_ui`](apps/lemon_sim_ui/README.md), [`lemon_tcg`](apps/lemon_tcg/README.md) |
| Satellite | [`x_api`](apps/x_api/README.md) |

Docs index: [`docs/README.md`](docs/README.md) · architecture overview:
[`docs/architecture/overview.md`](docs/architecture/overview.md) · config
reference: [`docs/config.md`](docs/config.md).

## Development

```bash
scripts/test fast      # compile --warnings-as-errors + ExUnit, excluding integration
scripts/test quality   # credo, doc freshness, architecture boundaries, duplicate tests
scripts/test path apps/lemon_core/test
```

[`docs/testing.md`](docs/testing.md) maps every local lane to its CI job.
Release profiles `lemon_runtime_min`, `lemon_runtime_full` and
`sim_broadcast_platform` are defined in [`mix.exs`](mix.exs):

```bash
MIX_ENV=prod mix release lemon_runtime_full
```

## Contributing

Start with [`CONTRIBUTING.md`](CONTRIBUTING.md); [`AGENTS.md`](AGENTS.md) is the
working agreement for both human and agent contributors. A new channel adapter
is the ideal first contribution — implement
[`LemonChannels.Plugin`](apps/lemon_channels/lib/lemon_channels/plugin.ex) and
run it against `LemonPlatformTest.PluginCase`. Vulnerability reports:
[`SECURITY.md`](SECURITY.md).

## License

MIT — see [`LICENSE`](LICENSE).

## Acknowledgments

Heavily inspired by [pi](https://github.com/badlogic/pi-mono) (Mario Zechner),
with architectural ideas from [Oh-My-Pi](https://github.com/can1357/oh-my-pi),
[takopi](https://github.com/banteg/takopi), OpenClaw and Ironclaw. The skill
library was bootstrapped from
[Hermes Agent](https://github.com/NousResearch/hermes-agent). Built with
[Elixir](https://elixir-lang.org/); the TUI is powered by
[@mariozechner/pi-tui](https://www.npmjs.com/package/@mariozechner/pi-tui).

Named after a very good cat.
