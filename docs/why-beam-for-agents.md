# Agents Are a Concurrency Problem

*Why Lemon is written in Elixir, what the BEAM actually pays for, and what it costs.*

I did not pick the BEAM because I like Elixir. I picked it because every agent system I
had built before was slowly growing a worse copy of OTP inside it, and I got tired of
maintaining the copy.

## The problem, in the terms you already know

If you build agents in Python or TypeScript, four things have probably hurt you.

**Many long-lived, stateful conversations.** You have one OS process, an event loop, and
a dict of session objects keyed by ID. State lives in the dict, concurrency lives in
`asyncio`, and failure lives nowhere in particular. The moment you need two machines, the
dict becomes Redis and every piece of session state becomes a serialization problem — not
because the state got more complicated, but because the runtime never gave you a unit of
isolation smaller than the whole process.

**Partial failure.** A tool call raises. A provider closes the stream at token 4,000. What
should die: the tool call, the turn, the conversation, the worker? In a single-process
runtime the blast radius is whatever your `try/except` happens to cover, and the default
when you get it wrong is that one bad tool takes down a request handler serving 200 other
users.

**Retries that duplicate side effects.** Your queue redelivers. Your HTTP client retries.
The agent sends the same message to the user twice, or books the same meeting twice. The
retry lives in a library that has no idea whether the operation it is retrying was
observable from outside.

**Observability of emergent behavior.** Two agents wait on each other. A run hangs for
forty minutes. "Which of my three hundred conversations is stuck, and on what?" is a
question logs answer badly, because the thing you want to inspect — a live, in-flight unit
of work — is not addressable in the first place.

None of these are LLM problems. They are the problems of a system made of many
independent, long-lived, failure-prone units of work that talk to unreliable things. That
is the system Ericsson built the BEAM for, and the whole argument of this document is that
agent runtimes have quietly become that system.

## What the runtime gives you, and where it shows up here

### A conversation is a process, not a dict entry

`LemonRouter.RunProcess` is a GenServer that owns exactly one run
([`run_process.ex:42`](../apps/lemon_router/lib/lemon_router/run_process.ex)), addressed
by `{:via, Registry, {LemonRouter.RunRegistry, run_id}}`. Abort state, the watchdog timer,
the metadata snapshot, the Bus subscription — all of it is ordinary process state. There is
no serialization, no lock, and no "who owns this session" question, because a process is
the answer to all three. When the run finishes the process exits and the state is gone;
there is no cache eviction policy because there is no cache.

Three properties follow, and they are the actual reason this matters:

- *Preemptive scheduling per process.* A run that spends ninety seconds parsing a 5MB tool
  result does not stall the other 499. There is no `await` I can forget to write.
- *A heap per process.* A conversation carrying a 200k-token history garbage-collects on
  its own heap. Nothing stops the world.
- *Admission control instead of degradation.* `RunSupervisor` caps concurrent runs
  ([`run_supervisor.ex:15`](../apps/lemon_router/lib/lemon_router/run_supervisor.ex),
  default 500) and returns `{:error, :max_children}` at the limit rather than accepting
  work it will serve badly.

### Supervision is a retry policy you can read

The interesting question is never "restart on crash." It is *what* to restart, and the
BEAM makes you answer it in one visible line.

Run processes are started `restart: :temporary`
([`run_supervisor.ex:54`](../apps/lemon_router/lib/lemon_router/run_supervisor.ex)). A
crashed run is deliberately *not* restarted, because replaying an LLM turn replays its
tool calls, and those wrote files and sent messages. The supervisor still receives the
exit, the Registry entry still disappears, monitors still fire — I get the cleanup without
the duplication. Compare channel adapters, which run `:one_for_one` under a
DynamicSupervisor ([`lemon_channels/application.ex:24`](../apps/lemon_channels/lib/lemon_channels/application.ex)):
a dropped Telegram connection *should* come back, because reconnecting is idempotent. The
idempotency argument lives in the supervision strategy, where a reviewer can find it.

One level down, each tool call runs as a supervised task with a monitor
([`loop/tool_calls.ex:63,569`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex)). If
it crashes, the `:DOWN` message is converted into a tool result the model can read —
`"Tool task crashed: ..."` at
[`tool_calls.ex:1027`](../apps/lemon_agent/lib/lemon_agent/loop/tool_calls.ex) — and the
other tools in the same parallel batch keep running. That is a `receive` block, not a
framework.

### Backpressure and at-most-once are process-shaped

The outbound path is a bounded queue with an explicit rejection: 5,000 messages
([`outbox.ex:22`](../apps/lemon_channels/lib/lemon_channels/outbox.ex)), and past that,
`{:error, :queue_full}` plus a telemetry event carrying the depth
([`outbox.ex:94`](../apps/lemon_channels/lib/lemon_channels/outbox.ex)). Rate limiting and
deduplication are separate processes, so a wedged delivery cannot take the accounting with
it. Delivery is keyed by an idempotency key, and repeat sends return `{:error, :duplicate}`
rather than a second message to the user.

The comment at [`outbox.ex:42-53`](../apps/lemon_channels/lib/lemon_channels/outbox.ex) is
the part I would point at in an interview. When `enqueue` times out, the message may still
be in the GenServer's mailbox and may still be delivered — so the caller gets
`:enqueue_timeout`, named to mean *ambiguous*, not *failed*. You can only write that
comment in a runtime where you know exactly where the message is.

Single-flight per session is a unique-key Registry
([`lemon_router/application.ex:18`](../apps/lemon_router/lib/lemon_router/application.ex)):
at most one active run per session key, enforced by the fact that two processes cannot hold
the same registry name. It is not a lock with a TTL and a recovery story. It is a name, and
it is released when the process dies, for any reason, including the node being killed.

What happens to the second message instead of being dropped is the job of
`LemonRouter.SessionCoordinator` — one process per conversation — which interprets queue
modes (`:steer`, `:steer_backlog`, `:collect`, `:interrupt`). The decisions themselves live
in [`session_transitions.ex`](../apps/lemon_router/lib/lemon_router/session_transitions.ex)
as a pure reducer; the process only performs the I/O the reducer asks for.

Provider failure is isolated the same way: a circuit breaker and a concurrency cap per
provider, each a process ([`ai/circuit_breaker.ex`](../apps/lemon_ai/lib/lemon_ai/circuit_breaker.ex),
[`ai/call_dispatcher.ex`](../apps/lemon_ai/lib/lemon_ai/call_dispatcher.ex)), so an Anthropic outage
returns `{:error, :circuit_open}` in microseconds instead of consuming every worker that
would otherwise have served OpenAI traffic.

### Live systems are inspectable

Because every run and every conversation is a named process, a stuck agent is a thing you
can attach to: `:observer`, `Process.info/2`, a remote shell into production, message-queue
depth per conversation. The idle watchdog
([`run_process/watchdog.ex:15`](../apps/lemon_router/lib/lemon_router/run_process/watchdog.ex))
and the bounded, drop-strategy-configurable event stream
([`event_stream.ex:64,95`](../apps/lemon_agent/lib/lemon_agent/event_stream.ex)) are cheap to
build on top of that, but the inspectability is the primitive.

## What it costs

If I only wrote the section above, you should not believe me.

**There is no ML ecosystem.** [`LemonAi.Tokens`](../apps/lemon_ai/lib/lemon_ai/tokens.ex) is a
four-characters-per-token heuristic, and its moduledoc says outright that it is not a
tokenizer. That is not laziness; there is no maintained BPE tokenizer for Elixir I would
take a NIF dependency on. Nx and Bumblebee are real and good, and they are not PyTorch. If
your agent needs local inference, embeddings, or reranking, that work happens somewhere
else.

**Anything with a native or JS-only SDK becomes an OS process boundary.** WASM extensions
run in a sidecar over a port protocol
([`wasm/sidecar_session.ex`](../apps/coding_agent/lib/coding_agent/wasm/sidecar_session.ex));
browser automation shells out; the TypeScript packages under `clients/` exist because the
browser is the browser. Ports are the correct answer — a crashing sidecar cannot corrupt
the VM — but you pay a serialization boundary and a supervision tree for what Python would
have solved with an import.

**NIFs are where the guarantees stop.** A NIF can crash the whole VM and can block a
scheduler thread. Every isolation property above is a property of Erlang code, not of the
process boundary in general.

**The hiring pool is small.** This is a real cost and I will not argue it away. The
mitigation I believe in is that the concepts transfer: someone who has reasoned about
actors, mailboxes, or Go channels can read this code in an afternoon.

**Distribution is not free, and "distributed by default" is oversold.** The Bus is a thin
wrapper over `Phoenix.PubSub` when that optional dependency is present and a local-only
Registry when it is not, and its moduledoc
([`bus.ex`](../apps/lemon_core/lib/lemon_core/bus.ex)) says exactly that, because a fallback
that silently stops crossing node boundaries is worse than no fallback.

**Not everything wants to be a process.** LemonSim's simulation kernel is a pure reducer
([`kernel/runner.ex`](../apps/lemon_sim/lib/lemon_sim/kernel/runner.ex)) specifically so
that a run is reproducible from a seed and a scorecard is a function of final state. That
is not just asserted: a test runs the same seed twice and checks the final world state and
every artifact hash are byte-identical
([`determinism_test.exs`](../apps/lemon_sim/test/lemon_sim/determinism_test.exs)).
Processes wrap it — `Task.async_stream` for suite concurrency
([`bench/suite.ex:237`](../apps/lemon_sim/lib/lemon_sim/bench/suite.ex), one always-on
GenServer per arena domain in [`arena.ex`](../apps/lemon_sim_ui/lib/lemon_sim_ui/arena.ex))
— but they stay out of the state machine. Determinism and concurrency want opposite things,
and nothing in the runtime draws that line for you.

## What this repo is evidence of

The claims above are checkable, which is the point of publishing them:

- **Boundaries are enforced, not asserted.** `@grandfathered` in
  [`architecture_rules_check.ex:584`](../apps/lemon_core/lib/lemon_core/quality/architecture_rules_check.ex)
  is an empty list. It held 29 authorized cross-boundary references when the check was
  added, and the policy was shrink-only: entries could be retired, never added. Now that it
  is empty, any cross-boundary reference at all fails CI. A companion test also rejects
  entries whose underlying reference no longer exists, so the list cannot rot into
  decoration.
- **Extension points ship with compliance suites.**
  [`lemon_platform_test`](../apps/lemon_platform_test) provides `ExUnit` case templates for
  the channel, engine, store-backend, and memory-provider behaviours, so a third party can
  run the platform's own contract tests against their implementation. The suites were
  validated by running a deliberately broken backend through them and confirming they fail.
- **The plan records its own reversals.** The Decision Log in
  [`platform-split.md`](platform-split.md) contains D2 and D11 — two decisions overturned
  after the code disagreed with them — with the evidence that overturned each.
- **The concurrency story has a demo.** [LemonSim](../apps/lemon_sim) runs deterministic,
  seeded, replay-verifiable multi-model games; the always-on arenas keep them running and
  score them continuously.

Deeper invariants and the supervision-tree diagrams are in
[beam_agents.md](beam_agents.md), including its list of known limitations — event fan-out
is still fire-and-forget `send/2`, and tool abort is best-effort. Those are honest gaps in
a runtime that makes it unusually easy to see that they are gaps.
