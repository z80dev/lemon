# LemonHoncho - AI Agent Context

## Quick Orientation

`lemon_honcho` adapts [Honcho](https://honcho.dev) — an external service that reads a
conversation and maintains a model of the people in it — into Lemon's memory and
prompt-context seams. It writes finished runs to Honcho as summary pairs — when the
memory ingest that carries them is enabled and `save_messages?` allows it — asks for
the resulting context on the way into a turn, and exposes the deeper queries as agent
tools.

**Core loop**: `LemonHoncho.SessionManager` holds a rendered context block per
session. A turn asks for it and gets the cached one immediately; the manager decides
from two independent cadence counters whether to refresh in the background. Uploads
go the other way and are fire-and-forget.

**Entry point**: `LemonHoncho` (config, `configured?/0`, `status/0`), then
`LemonHoncho.SessionManager` for the behaviour that matters.

## The satellite rule

This is the rule to internalize before touching anything: **the platform must never
reference `LemonHoncho`.** No app under `apps/` may name this module, alias it, add it
to a dependency list, or wire it in `config/config.exs` beyond the one
`LemonHoncho.Env` entry in `:env_registries`. `mix lemon.quality` enforces the
dependency direction, and the direction is satellite → platform only.

Two further places in the umbrella root name the *application* — not the module — and
neither is a platform app depending on this one, which is why they are allowed. The
root `mix.exs` lists `lemon_honcho: :permanent` in both runtime releases, because a
satellite performs its registrations in `start/2`: a release that omits it starts
nothing and says nothing about why. And `config/test.exs` pins the integration off, in
three settings that are one decision — see **The test environment is pinned off** below.
Those two places and the `:env_registries` entry are the complete list; keep them in
step when renaming anything.

The consequence is that everything this app contributes, it contributes *itself*, at
boot, from `LemonHoncho.Application`:

| Seam | How it is claimed | When |
|---|---|---|
| `LemonMemory.Providers` | `register_provider/1` with `LemonHoncho.MemoryProvider` under id `"honcho"` | Only when `Config.configured?/1` |
| `LemonAgent.ContextRegistry` | `register(:honcho, LemonHoncho.ContextContributor)` | Only when `Config.configured?/1` |
| `LemonAgent.ToolRegistry` | `register/2` for the five `honcho_*` tools | Always |

Provider and contributor registration are gated because an unregistered provider
costs nothing while a registered one that cannot answer adds its timeout to every
memory search. Tools register unconditionally because a model that asks for memory on
an unconfigured host should be told so as a normal tool result — the convention
`XApi.Tools.XSearch` set.

Every registration is individually guarded and every failure is swallowed at debug: a
partially-started runtime (a release without `lemon_memory`, a test that starts this
app alone) must still bring `lemon_honcho` up rather than take the node down.

### The test environment is pinned off

`config/test.exs` sets `enabled: false`, `start_session_manager: false`, **and**
`client: LemonHoncho.Client.Tripwire`. The third is not redundant. `LemonHoncho.Config`
resolves OS environment *ahead of* application env, so a developer with
`LEMON_HONCHO_ENABLED=true` in a shell rc — an entirely reasonable thing to have for a
real install — overrides the first two: the provider registers, the contributor
registers, and every memory search in the umbrella fans out to their live workspace
carrying the suite's queries. Application env has no environment fallback, so pinning
the transport is what closes that. `LemonHoncho.Client.Tripwire` raises from every
function in the client's surface, naming the call, so a suite that reaches for Honcho
fails where it is asserted instead of quietly succeeding over the network.

Two consequences for anyone writing tests here. A test that means to exercise the
client sets its own stub with `Application.put_env(:lemon_honcho, :client, MyStub)`.
And the tripwire raises rather than returning `{:error, _}` on purpose — every caller
in this app degrades quietly on an error tuple, which would hide the very thing the
tripwire exists to make visible. It lives in `lib/` rather than `test/support/` because
the hole it closes is umbrella-wide: `mix test` in any app that searches memory would
otherwise reach a live Honcho, and only a compiled module is resolvable from every
app's test run.

## Key files

| File | What it does | When to touch it |
|---|---|---|
| `lib/lemon_honcho.ex` | Public face: `config/0`, `configured?/0`, `enabled?/0`, `status/0` | Adding an operator-visible fact |
| `lib/lemon_honcho/application.ex` | Starts the manager, performs the three registrations | Changing what the satellite contributes |
| `lib/lemon_honcho/config.ex` | Resolves env → app env → default into one struct; never raises | Adding a knob (also add it to `env.ex`) |
| `lib/lemon_honcho/env.ex` | The declared env-var contract, aggregated by `LemonCore.Env` | Adding or renaming a variable |
| `lib/lemon_honcho/client.ex` | The only module that speaks HTTP to Honcho | Adding an endpoint |
| `lib/lemon_honcho/client/tripwire.ex` | The refuse-everything client the test environment is pinned to | Adding a client function (add it here too, or the pin has a hole) |
| `lib/lemon_honcho/egress.ex` | `screen/2`: the single clip-then-withhold gate for user-derived text on the wire | Adding a call site that sends user text — do not add a second gate |
| `lib/lemon_honcho/session_name.ex` | Run → Honcho session id, per `session_strategy` | Changing which runs share memory |
| `lib/lemon_honcho/session_manager.ex` | Caching, cadences, lazy init, uploads, the bounded session map | Changing when Honcho is called, or what is retained between calls |
| `lib/lemon_honcho/context.ex` | Pure rendering and budgeting of the injected block | Changing what the model reads |
| `lib/lemon_honcho/context_contributor.ex` | Thin, total adapter from the registry's `contribute/1` to the manager's cache: splits the block into a `:system` half and a `:user_message` half, plus the `timeout_ms/1` that buys the cold first turn its budget | Changing a section's title or placement, the skip rules, or the first-turn budget |
| `lib/lemon_honcho/memory_provider.ex` | `put/2` and `search/2`; maps Lemon scopes onto Honcho searches and messages onto documents | Changing how Honcho results appear in memory search |
| `lib/lemon_honcho/tools/*.ex` | The five `honcho_*` agent tools | Changing what the model can ask for explicitly |
| `lib/mix/tasks/lemon.honcho.ex` | `status`, `sessions`, `ping`, `context` — the operator surface, diagnostics bounded and `context` read-only unless `--live` | Changing what an operator can see |

## Where the seams are, and the rules they impose

**The turn path is the constraint.** `LemonAgent.ContextRegistry.collect/2` runs
contributors concurrently, each under its own deadline — 250 ms unless it asks for
more — on every user message. A contributor must return a value it *already has*.
Reading a cached string out of the manager is in-contract; issuing an HTTP request
from `contribute/1` is not, however tempting it looks.

The one sanctioned exception is a session's cold first turn, and it only works because
both halves agree:

* `ContextContributor.timeout_ms/1` asks the registry for
  `SessionManager.first_turn_budget_ms/1` and does so **only** on that turn —
  configured, not `:tools`, injecting for this scope, wait switched on, and
  `SessionManager.cold?/1` true for the key. Every other turn returns the 250 ms
  default. A contributor that returns a raised constant unconditionally has made every
  warm turn slower for nothing. Note that `cold?/1` is one map lookup inside the
  manager: this question is asked on every turn of a configured install, so it must
  stay O(1) rather than going back through `sessions/0`.
* `SessionManager` replies `{:wait, key, first_turn_budget_ms}` only on turn zero and
  only while that turn's refresh is in flight; the caller then re-enters through
  `{:await, key}` and is parked in the entry's `waiters` list until the refresh lands,
  expires, or dies. It is a waiter list, not a blocking call, and it is the only place
  a turn waits.

The arithmetic is the contract between the two halves, and all three terms matter.
`first_turn_budget_ms/1` is `first_turn_wait_ms + @first_turn_margin_ms` (200) clamped
to `@registry_max_timeout_ms` (3,000) — the registry's own `@max_timeout_ms`, restated
in both modules rather than imported. The manager then awaits that budget *minus* the
elapsed time of the `{:context, …}` call *minus* `@await_headroom_ms` (50), so it
answers strictly inside the registry's deadline instead of racing it: the failure it
prevents is the contributor being killed 50 ms before the manager hands back a block it
has already cached. Deriving the wait from the clamped budget rather than from
`first_turn_wait_ms` is what makes that hold for large values — the registry would clamp
silently, and the manager would be waiting past a deadline it cannot see. So raising
`first_turn_wait_ms` past 2,800 changes nothing at all, a non-positive remainder yields
`""` immediately, and budgets are per contributor, so this can never extend another
contributor's 250 ms.

Change either half and the wait silently stops working: without `timeout_ms/1` the
registry kills the contributor at 250 ms, and without the manager's `{:wait, …}` reply
there is nothing to wait on. The pair is covered in
`test/lemon_honcho/context_contributor_test.exs` and
`test/lemon_honcho/session_manager_test.exs`; keep it that way.

**Nothing may raise.** The client translates every remote failure mode into a value:
`{:error, :not_configured}`, `{:error, {:unauthorized, body}}`, `{:error, {:api_error,
status, body}}`, `{:error, {:transport, reason}}`. The manager degrades every failure
to `""`. New code inherits this: a Honcho outage must cost a turn its memory block and
nothing else.

**Every piece of user-derived text on the wire goes through one gate.** Uploads carry
summarizer output that `LemonMemory.Ingest` has already screened. Everything else —
the retrieval query, every tool parameter that carries prose, the memory provider's
recall query — goes through `LemonHoncho.Egress.screen/2`, and nowhere else. The policy
is clip to the caller's budget in graphemes, then run
`LemonMemory.Safety.contains_secret?/1` over the *clipped* text (the bytes that would
actually travel), and withhold whole on a match: `nil`, never logged, never partly
redacted. Order matters and so does that direction — do not "improve" the drop into a
redaction, and do not screen before clipping.

The budget is the call site's, and lives next to the call that spends it:
`SessionManager` 1,500 (`@search_query_max_chars`), `Tools.Search`, `Tools.Reasoning`
and `Tools.Conclude`'s `query` 1,500, `Tools.Conclude`'s `conclusion` 2,000,
`Tools.Profile` 500 per card line, `MemoryProvider` 2,000. What `nil` *means* is also
the call site's decision, and the split is the important part. `SessionManager` reads on
with no query — there the query only focuses a representation, so losing it costs
relevance and nothing else. `MemoryProvider` returns `[]`, the same value every other
failure yields, because the behaviour gives it no other channel. Every tool **refuses**,
because there the text *is* the request and a search of nothing reported as a search of
something is a wrong answer rather than an empty one; `Tools.Profile` refuses the whole
write on one bad line, since a card write is a replace and sending the survivors would
delete the withheld line as a side effect of a safety check.

A new call that puts a request field on the wire routes through `Egress` too. Screen at
the parameter, not at the call, so `details` and the result text echo exactly the string
that went out; and never put the withheld value in a refusal message, since the
transcript is the one place it has not reached.

**Two cadences, counted independently.** The base layer (summary, representations,
peer card) is gated by `context_cadence`; the dialectic — an LLM call on Honcho's
side, the expensive one — by `dialectic_cadence`. Markers advance when a refresh
*starts*, so a failing endpoint costs one attempt per window rather than one per turn.
Do not collapse the counters, and do not advance them on success only.

**What this block costs is decided downstream of it, in the prompt cache, and that is
why it is contributed in two halves.** `CodingAgent.Session` recomposes the system prompt
on every user message and pushes it when a single byte differs;
`LemonAi.Providers.Anthropic` sends the whole system prompt as one `cache_control:
ephemeral` block and puts a second breakpoint on the last user message, whose prefix
contains the first. A cache entry is matched on exact bytes, so a byte changing in the
system prompt misses both breakpoints and invalidates the system prompt, the tool schemas
and the whole conversation behind them — re-cached at the cache-write price instead of
read at a tenth of input (`$3.75` vs `$0.30` per million tokens on Claude Sonnet 4's entry
in `LemonAi.Models`, so ≈`$0.17` per changed turn at a 50,000-token prefix).

There *is* a seam for the second half, and this app uses it. A section carries a
`t:LemonAgent.ContextRegistry.placement/0`, and the rule for choosing one is:

> anything whose text can differ between two consecutive turns rides the user message;
> anything that is the same for the whole session stays in the system prompt.

`ContextContributor` therefore returns two specs. The durable material is `:system` and is
rendered into the prompt; the dialectic supplement is `:user_message`, and
`CodingAgent.Session.attach_recalled_context/2` appends it to the outgoing message inside
a `<recalled-context>` block, after the last breakpoint. Three facts about that half are
load-bearing and easy to break. It is labelled in its own first sentence as
system-supplied, unwritten and unseen by the user, background rather than instruction —
because text inside a user turn is otherwise read as the user's own words. It is stripped
back off in `handle_info({:agent_event, …})` and `get_messages/1`, so no transcript,
subscriber, hook or UI ever attributes it to the person. And it is *not* stripped from the
agent's replayed history, deliberately: turn N's bytes must replay verbatim on turn N+1 or
the prefix diverges there.

Two rules follow for anything touching `Context` or the cadences. Stability of the
`:system` half is a feature: a rendering change that makes the same underlying facts
render differently there (a timestamp, an ordering that is not deterministic, a counter,
anything selected by the current query) costs a full cache miss per turn and buys nothing
— and material that cannot be made stable belongs on the other side of the split rather
than in the prompt. And lowering a cadence default is still a spend decision, on Honcho's
bill for `dialectic_cadence` and on the user's model bill for `context_cadence`, so it
belongs in the docs that discuss cadence (`docs/user-guide/honcho.md`, this app's README)
rather than being changed quietly.

**The registry bounds size as well as time.** A contributor may return at most eight
sections totalling 16 KB of title and body per turn; the overflow is dropped from the end
with a warning. That is a backstop against a bug, not a budget — `LemonHoncho.Context`
budgets the block itself against `context_tokens`, which is where a size decision can be
made with knowledge of what the text means. A contribution arriving anywhere near either
limit is a bug here, not a limit to raise there.

**The session map is bounded, and the bound has a shape.** `@max_sessions` (500) plus
`@idle_ttl_ms` (two hours), swept in `track_entry/3` — the only path that can introduce
a new key, and therefore the only moment the map can grow. Hanging the O(N) sweep off
key creation rather than off every write is what keeps it once-per-session instead of
once-per-turn, so route a new writer through `track_entry/3` and not through
`put_entry/3`. Both serving and uploading count as touching an entry, or a
`sync_document/1`-heavy deployment would evict the sessions it is writing for. Eviction
is LRU by `last_touched_ms` and skips any entry with a refresh in flight or a waiter
parked on it: dropping one of those orphans a worker whose result has nowhere to land
and strands a caller nothing will ever reply to, which is why the cap can be exceeded
briefly by the number of concurrent refreshes. Everything in an entry is a cache, so an
evicted key simply re-initialises on its next turn; if you add a field that is *not*
reconstructible, this policy is no longer safe and the field is in the wrong place.

**Session ids are a correctness surface.** `SessionName` sanitizes to `[A-Za-z0-9_-]`
and, past Honcho's 100-character cap, keeps a prefix plus eight hex characters of the
SHA-256 of the *pre-sanitization* key. Truncating alone would merge the memories of
two long gateway keys that share a leading segment. Read that moduledoc before
touching it.

**Config never fails a boot.** `Config.load/0` is called on the way up. A misspelled
enum or non-numeric integer resolves to the default; it does not raise, and it does
not log at a level that would make a typo look like an outage.

**`search/2` returns a plain list or nothing.** `LemonMemory.Provider` gives failure
no channel: every error `LemonHoncho.MemoryProvider` can have — unconfigured, 401,
timeout, an unparseable response — is `[]` and a debug log. A scoped search arriving
without a `:scope_key` narrows to `[]` rather than widening to the workspace, and that
rule outranks the scope mapping.

**Secrets never reach the terminal.** `mix lemon.honcho` reports the API key as
present or absent, never as a value or a prefix, and scrubs the configured key out of
every rendered error before truncating it — an upstream that echoes an `Authorization`
header into a 4xx body must not turn a diagnostic into a leak.

**Diagnostics are bounded, and explain before they act.** `status` and `ping` call the
client with `max_retries: 0` and an explicit `total_timeout`, so the worst case is the
number the moduledoc states — `--timeout`, else `HONCHO_TIMEOUT_MS` for `ping` and 5 s
for `status`. The turn path keeps its retries; only the diagnostic path is capped,
because an operator watching a terminal needs an answer inside the stated time even
where a longer wait would have succeeded. And `context` reports a session's tracked
state without touching the network or the session, because assembling a block runs the
production turn path: a turn counter advances, a refresh may start, and the dialectic is
billed. That belongs behind `--live`, and `--live` prints what it is about to do before
it does it. A new subcommand inherits both rules.

## Honcho's API

Endpoints live under `/v3` and every route is workspace-scoped
(`/v3/workspaces/<workspace>/...`). The shapes this app depends on are documented in
`LemonHoncho.Client`'s moduledoc and function docs — read those first; they record
the parts that are easy to get wrong, including:

* a `base_url` ending in a version segment is stripped, because the routes already
  carry `/v3` and `/v3/v3/...` 404s on every call;
* authorization is sent only when a key is configured, since a self-hosted Honcho on
  a private or CGNAT address legitimately runs without auth;
* `chat` returning `{:ok, nil}` is normal — a fresh peer knows nothing — and is not an
  error.

The upstream service and its own docs are at [honcho.dev](https://honcho.dev); the
server is open source at
[plastic-labs/honcho](https://github.com/plastic-labs/honcho), which is what
`HONCHO_BASE_URL` points at for a self-hosted deployment.

## Testing

```bash
mix test apps/lemon_honcho
mix test apps/lemon_honcho/test/lemon_honcho/session_manager_test.exs
```

There is no network in the test suite and there must not be. Three seams make that
possible:

* **HTTP** — `LemonHoncho.Client` merges `Application.get_env(:lemon_honcho,
  :req_options, [])` into every request last, so a test injects a `Req.Test` plug (and
  disables retries) without any function growing a transport parameter.
* **The client module itself** — `SessionManager.start_link/1` accepts `:client`,
  `:config`, `:max_sessions` and `:idle_ttl_ms` overrides, and `init/1` otherwise reads
  `Application.get_env(:lemon_honcho, :client, LemonHoncho.Client)`. All are test-only:
  they exist so cadence arithmetic, degradation paths and the eviction policy can be
  driven against a stub without a network and without ten thousand session keys.
  Nothing in production sets them.
* **The pinned default** — with nothing overriding it, that same application-env read
  resolves to `LemonHoncho.Client.Tripwire` under `MIX_ENV=test`, so a suite that
  forgot to set a stub raises instead of dialling out. See **The test environment is
  pinned off** above.

Set `config :lemon_honcho, :start_session_manager, false` to start the app without the
process when a test wants the registrations but not the GenServer.

The memory provider is proven against the published contract kit the same way a
third-party integration would be:

```elixir
defmodule LemonHoncho.MemoryProviderTest do
  use LemonPlatformTest.ProviderCase, async: false, provider: LemonHoncho.MemoryProvider
end
```

## Verifying a change

From the umbrella root:

```bash
mix format
mix test apps/lemon_honcho
mix credo                  # non-strict is the gate; .credo.exs sets strict: false
mix lemon.quality          # architecture boundaries + docs catalog
```

`mix lemon.quality` is the one that catches a satellite-rule violation: if a platform
app has grown a reference to `LemonHoncho`, the architecture boundary check fails
there rather than here.

## Connections to other apps

### Dependencies (this app uses)

| App | What `lemon_honcho` uses from it |
|---|---|
| `lemon_core` | `LemonCore.Env.Registry` for the declared env contract, `LemonCore.Config.Helpers` for resolution |
| `lemon_memory` | `LemonMemory.Provider` (the behaviour), `LemonMemory.Providers` (registration), `LemonMemory.Document` (what a finished run looks like) |
| `lemon_agent` | `LemonAgent.ContextRegistry` for the prompt section, `LemonAgent.ToolRegistry` and the tool structs |
| `lemon_ai` | Tool result content types |
| `lemon_platform_test` | Test-only: the provider compliance case |

### Consumers (other apps use this)

None, and that is the point. The platform discovers this app through the registries
above, never by name.

## Gotchas

* **`enabled?` is not `configured?`.** `LEMON_HONCHO_ENABLED` defaults to true; the
  question everything else asks is `configured?/0`, which additionally requires an API
  key or a base URL. Use `enabled?/0` only when reporting *why* Honcho is inactive.
* **`recall_mode` gates both directions, oppositely.** `:tools` disables injection —
  the manager returns `""` for every context request, because the model asks for memory
  explicitly and injecting it too would pay twice. `:context` is the mirror: every one
  of the five tools returns a context-only result from its `gate/1` without calling
  Honcho, because in that mode memory reaches the model through the prompt. The
  registrations do not change either way; the tools are always registered, and the
  memory provider ignores `recall_mode` entirely, so `search_memory` still reaches
  Honcho in both modes.
* **Subagents get nothing by default.** `inject_in_subagents?` is false; a request with
  `session_scope: :subagent` is gated before any work happens.
* **`save_messages?: false` is enforced in three places, not one.** The name says
  messages, but the promise is read-only, so the upload path in `SessionManager` refuses
  and so do `Tools.Profile`'s write and `Tools.Conclude`'s `create` and `delete` —
  deleting changes their store just as much as creating does. Reads, including
  `honcho_conclude`'s `query`, keep working; a read-only integration that cannot read is
  not read-only, it is off. A new endpoint that writes inherits this check.
* **Uploads ride the built-in ingest, which is flag-gated.** The only caller of
  `MemoryProvider.put/2` is `LemonMemory.Ingest` via `LemonMemory.Providers.put/1`, and
  ingest runs only when the `session_search` feature is enabled — it defaults to `off`.
  Honcho reads working while nothing is ever stored is that flag, not a bug here.
* **What Honcho models is summaries, not transcripts.** Uploads carry
  `LemonMemory.Document`'s `prompt_summary` and `answer_summary`, already capped
  upstream at 2,000 bytes each. When a representation seems to have missed something,
  check whether it was ever sent before assuming the service lost it.
* **Init failure is sticky for 30 seconds.** An unreachable Honcho is six requests that
  all have to time out; re-dialling it every turn is both pointless and slow. The first
  failure per session logs at warning, the rest at debug.
* **"Tracked" is not "stored", and the mix task's node is not the user's.**
  `SessionManager.sessions/0` lists only what *this* node holds, which is capped and
  swept, so an absent row is never evidence that Honcho has nothing for that key. And
  `mix lemon.honcho sessions` / `context` call it inside the node the task starts with
  `Mix.Task.run("app.start")` — a node that has served no turns and is not the running
  Lemon — so on a working install they report an empty manager, every time. `status` and
  `ping` are the two subcommands whose answers transfer, because config resolution and
  reachability do not depend on which node asks. Anything new that reports per-session
  state inherits this limit; say so where it prints.
* **A withheld egress text is not an error.** `Egress.screen/2` returns `nil` for blank
  input, non-binary input and a bad budget as well as for a suspected credential, so
  every caller needs a working "no text" path regardless. Callers that treat `nil` as a
  failure to log or raise on have got it backwards.
