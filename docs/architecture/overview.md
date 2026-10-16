# Architecture Overview

Lemon has two products in one Elixir umbrella: a multi-channel assistant and
LemonSim. Both use `lemon_agent` and `lemon_ai`; shared config, storage and
boundary contracts live in `lemon_core`. A session is a durable conversation;
a run is one submitted unit of work. A conversation key identifies work that
must be serialized, including requests resuming the same native session.

## Message journey

```text
Telegram / Discord / other adapters → lemon_channels ─┐
TUI / one-shot CLI → lemon_control_plane ──────────────┤
Phoenix assistant UI → lemon_web ─────────────────────┤
Cron / goal / kanban work → lemon_automation ──────────┤
                                                     ↓
                                                lemon_router
                                                     ↓
                                                lemon_gateway
                                                     ↓
                                           CodingAgent.Executor
                                                     ↓
                                      coding_agent → lemon_agent → lemon_ai
```

1. An ingress authorizes and normalizes input into shared request contracts.
   Messaging channels use `LemonCore.RouterBridge` without a compile dependency
   on the router. Acceptance requires a non-empty run ID; a lost acknowledgement
   is an unknown outcome, not permission to retry a possible side effect.
2. Router resolves session, policy, model, cwd and native resume state.
   `SessionCoordinator` serializes a conversation and owns collect/follow-up/
   steer/interrupt semantics. Gateway does not implement a second conversation
   queue policy.
3. Router submits `LemonCore.ExecutionCommand` through `LemonCore.EngineRuntime`.
   Gateway adapts it to private `ExecutionRequest`, grants a concurrency slot and
   owns worker/run/launch-lock lifecycle.
4. The configured `CodingAgent.Executor` starts/resumes a native session. The
   session composes bounded context and tools, the agent loop coordinates tool
   tasks/model turns, and `lemon_ai` handles provider protocols and streaming.
5. Gateway events flow through `LemonCore.Bus` to router and interested clients.
   Router coalesces semantic `DeliveryIntent` output; channels choose send/edit,
   truncation, buttons, media batching and platform message IDs through the outbox.
6. Completion persists history/resume state, releases owned resources and advances
   queued work. Public management projections are bounded/redacted, not raw events.

Plaintext transport data, tool output and external skill content are untrusted.
Authorization, tool policy/approvals and the pre-model trust boundary remain
separate layers; successful execution does not make content authoritative.

## Execution placement

All top-level runs use the native executor. `engine: "lemon"` in run history is
provenance, not an engine selector. Historical vendor resume tokens remain
readable but cannot select or resume top-level execution.

`task` and `@name` personas spawn native in-process child sessions through
`CodingAgent.Coordinator`. `agent` delegates through router and can name a live
execution node. Omitted node or `"local"` stays local. A named node runs the same
native executor on its destination through an authenticated control-plane socket.

Only JSON-safe request data crosses that boundary. Destination cwd and provider
credentials stay destination-local; callbacks, source credentials and process
state never cross. Names are durably unique and executable only while authenticated
and live. Cancellation and bounded steer/redirect bind the same invocation/run/
node session and require destination acknowledgement. Disconnects and stale
sessions fail closed. The destination strips the placement selector to prevent
recursive remote delegation.

A2A is a different seam: independently authenticated peer agents exchange durable
tasks through the optional separate listener. Peers are not execution nodes or
operator sockets. See [A2A](../user-guide/a2a-peers.md).

## Application responsibilities

| App(s) | Responsibility |
| --- | --- |
| `lemon_ai` | Provider APIs, model catalog, streaming and admission; no umbrella deps |
| `lemon_core` | Bus/events, Store, config/secrets and shared contracts; no umbrella deps |
| `lemon_agent` | Agent/tool loop, model runtime/credentials, workspace goal/kanban state |
| `coding_agent` | Native coding sessions, JSONL history, tools, compaction and delegation |
| `lemon_router` | Conversation queues, run orchestration and semantic delivery |
| `lemon_gateway` | Native execution lifecycle/slots and opt-in SMS/voice/webhook ingress |
| `lemon_channels` | Messaging adapters, platform authorization/rendering and outbox |
| `lemon_control_plane` | Authenticated client API, named-node transport and A2A listener |
| `lemon_cli` | Shared source/release command dispatch, setup and operator workflows |
| `lemon_web` | Assistant Phoenix chat and management interface |
| `lemon_memory` | Scoped durable memory, ingest/search and lifecycle management |
| `lemon_skills` | Skill catalog/install/audit/curation and assistant-platform tools |
| `lemon_automation` | Cron/reminders/heartbeat policy, goal loops, kanban and blueprints |
| `lemon_browser`, `lemon_media`, `lemon_lsp` | Supervised browser, media and language-server capabilities |
| `lemon_mcp` | Client library for external MCP tools/resources/prompts |
| `lemon_omp` | omp (oh-my-pi) delegate driver for external agent sessions; not an executor |
| `lemon_computer_use` | Native app control through LCU (`cua_js` tools): transport, approval routing, lifecycle |
| `lemon_honcho` | Optional satellite registering external memory/context/tools |
| `lemon_evals`, `lemon_platform_test` | Evaluation harness and extension contract tests |
| `lemon_sim`, `lemon_sim_ui` | Simulation kernel/scenarios/artifacts and Phoenix control room |

The Bun TUI and browser automation node live under `clients/`. The assistant Web
interface is Phoenix; it is not a separate React workspace.

Five packages are in the publish set: ai, core, agent, memory and platform-test.
They are published on Hex at 0.2.0; the old 0.1.0 tarballs are retired as
uninstallable. Everything else ships as the in-repository reference runtime
and products. See [platform status](../platform-split.md).

## Persistent state and configuration

- Generic Store backends support ephemeral ETS and durable SQLite/JSONL. Domain
  wrappers own tables; consumers use lifecycle services for operator mutations.
- Config provides defaults with environment > project > user precedence. Current
  per-session/route/chat overrides live in `PolicyStore`, not another config plane.
  Model resolution considers explicit/meta/session/profile/history/default policy;
  details belong in [model selection](../model-selection-decoupling.md).
- Native session history is JSONL with branching and compaction entries. Router
  run/session inventory and profile/memory stores have their own typed ownership;
  UI clients must not create competing stores.
- `remember` edits assistant workspace preferences/memory, while `recall` searches
  scoped historical runs and notes. Automatic recall is bounded local context on
  the current user turn, controlled by `[memory] auto_recall = true` and disabled
  when `session_search` is off. Durable ingest also uses that feature gate; unsafe
  secret-bearing ingest is withheld, not merely redacted and stored. See
  [memory](../user-guide/memory.md).
- Heartbeats are ordinary cron jobs distinguished by metadata; completed exact
  `HEARTBEAT_OK` output is suppressed but remains in history. Daily brief uses the
  same scheduler, not another heartbeat timer/store.
- Skills contribute stable bounded metadata; full content is explicitly loaded.
  Installation/learning uses audit and exact-confirmation boundaries. See
  [skills](../skills.md) and [source learning](../user-guide/learn-from-sources.md).

## Supervision and guarantees

BEAM processes isolate sessions and supervised tasks isolate model/tool work.
That does not make arbitrary retries safe, imply lossless subscriber replay or
make ETS durable. Owners reconcile durable state after restart and preserve
idempotency/lease boundaries for mutations. Direct event fanout is fire-and-forget;
bounded streams provide explicit overflow/timeout behavior. See
[BEAM invariants](../beam_agents.md) and [telemetry](../telemetry.md).

LemonSim keeps deterministic event updaters and RNG separate from LLM decisions.
Replay-verified bundles record setup/seed, input batches, events and final state.
The control room owns runner capacity, hosted-room privacy and presentation,
not game rules. Hosted ownership is single-node, not a horizontally replicated
service. Start with [benchmarks](../benchmarks/quickstart.md).

## Further reading

- [Exact dependency policy](../architecture_boundaries.md), derived from `mix.exs`
- [Config reference](../config.md), [context](../context.md) and [bootstrap](../assistant_bootstrap_contract.md)
- [Contributor/app guide index](../../AGENTS.md#ownership-and-app-guides)
- [Testing](../testing.md), [safety](../security/safety.md) and [backups](../user-guide/backups.md)
