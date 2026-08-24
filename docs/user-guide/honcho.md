# Honcho Memory User Guide

[Honcho](https://honcho.dev) is a memory service that reads a conversation and keeps a
model of the people in it — preferences, working style, goals, decisions — and hands
that model back as text an agent can read before it answers.

Lemon integrates it as an optional satellite app, `lemon_honcho`. It is **off unless
you configure it**, it runs alongside the built-in memory rather than replacing it,
and nothing in the platform depends on it: an install without Honcho is a supported
install, and every failure Honcho can have costs a turn its recalled context and
nothing else.

---

## What Honcho Adds

Lemon's built-in memory (see [`docs/user-guide/memory.md`](memory.md)) records *what
happened*: one document per run, summarized and searchable. Honcho models *who you
are*.

| Capability | Built-in memory | Honcho |
|---|---|---|
| Cross-session persistence | Local SQLite store | Server-side, per workspace |
| Search | FTS keyword search over run documents | Semantic search over stored messages |
| User profile | Agent-curated notes (`USER.md`, `MEMORY.md`) | Derived automatically from conversation |
| Peer card | — | A short, editable profile Honcho maintains per peer |
| Session summary | — | A rolling summary injected into the prompt |
| Reasoned recall | — | The dialectic: an answer synthesized on demand |
| Conclusions | — | Explicit facts, stored and semantically searchable |
| Multiple assistants | Shared store | Separate peers, each with its own representation |

Honcho registers as an additional memory provider, so `search_memory` results can come
from both at once. Its recalled context reaches the model in two places rather than one:
the part that holds still for a session is a section of the system prompt, and the part
that is written fresh for the turn is attached to your own message on the way out —
labelled as system-supplied, and taken off again before the conversation is stored or
shown to you. [Where the block goes](#where-the-block-goes) says exactly what lands
where.

---

## Setup

Get an API key at [honcho.dev](https://honcho.dev) and export it:

```bash
export HONCHO_API_KEY="hk-..."
```

Or point Lemon at a self-hosted deployment (the server is open source at
[plastic-labs/honcho](https://github.com/plastic-labs/honcho)):

```bash
export HONCHO_BASE_URL="http://honcho.internal:8000"
```

Either one is enough — a key alone uses the hosted deployment, a base URL alone works
against a self-hosted server that runs without authentication. Set both when your
self-hosted server does require a key.

**Exporting the key is the whole of the opt-in.** There is no second switch to flip:
`LEMON_HONCHO_ENABLED` defaults to true, so a shell (or a systemd unit, or a release
env file) that exports `HONCHO_API_KEY` has Honcho active for every Lemon run started
from it. If you keep the key exported for another tool and do not want Lemon using it,
set `LEMON_HONCHO_ENABLED=false`, which wins over the key. Lemon's own test suite is
pinned off — and pinned off a second time at the transport, so that even a shell which
forces the integration on cannot make `mix test` reach a real workspace.

Uploads travel over Lemon's built-in memory ingest, and that pipeline sits behind the
`session_search` feature flag, which now defaults to **default-on** — so once the key
is exported, per-run uploads happen without any further switch. If you want Honcho's
injected context, tools, and search without the automatic per-run upload, use the
kill switch — with it set, Honcho has nothing new to build a picture of you from, so a
fresh workspace stays empty. (Facts the assistant writes deliberately with
`honcho_conclude` or `honcho_profile` are stored either way; it is the automatic
per-run upload that is gated.)

```bash
export LEMON_FEATURE_SESSION_SEARCH=off     # or [features] session_search = "off"
```

Check it:

```bash
mix lemon.honcho status
```

`status` prints the resolved configuration and then probes whether Honcho answers, so
"misconfigured" and "configured but the service is down" read differently. It exits 0
when Honcho is not configured at all and tells you which variables to set — running
without Honcho is not a failure.

Two things about that command are worth knowing before you lean on it, because both
change what its answer means.

**It boots its own Lemon.** Every subcommand starts the umbrella in the mix task's own
node before it does anything else. That means the HTTP listeners try to bind, a
configured Discord bot connects a second shard, and start-up work like the X API token
refresh runs — as a side effect of asking for status. On a machine where Lemon is
already running, the ports are taken and the command dies with `:eaddrinuse` before
printing a line, which is exactly the machine you are on when you most want to check.
Stop the running Lemon and run it, or run it from the same shell environment on a host
that is not currently serving.

**It reports on that node, not on your running one.** `status` and `ping` are still
useful there, because what they answer is node-independent: `status` resolves your
configuration out of the environment the command inherits — the same environment a
Lemon started from that shell would inherit — and `ping` makes one real request to
Honcho, so it proves the key, the base URL, and the network. `sessions` and `context`
are not: they read the session manager *inside the task's node*, which has never served
a turn, so on a perfectly healthy install `mix lemon.honcho sessions` prints "No
sessions tracked yet" every time. It is not telling you anything about your running
Lemon's memory. See [Command Line](#command-line).

**What actually checks a live install** is the assistant. Ask a running Lemon something
only memory would know — "what do you already know about how I work?" — and see whether
the answer is grounded. If Honcho is inert the answer is generic and nothing breaks,
which is the same shape every other Honcho failure has.

---

## The Two-Layer Context Model

When Honcho is active, every turn gets a labelled block of recalled context, assembled
from two layers with very different costs:

1. **Base layer** — the session summary, what Honcho knows about you, your peer card,
   and what it knows about the assistant. Ordinary reads. Refreshed every
   `LEMON_HONCHO_CONTEXT_CADENCE` turns.
2. **Dialectic supplement** — one synthesized answer to "of everything you know about
   this person, what matters right now?". Refreshed every
   `LEMON_HONCHO_DIALECTIC_CADENCE` turns.

Both are presented as *recalled background* rather than instructions: when memory
disagrees with what you are saying now, the live conversation wins, and the text says so
in its own preamble.

Neither layer is fetched while you wait. Lemon keeps the rendered block per session,
hands back the cached one immediately, and refreshes in the background.

The single exception is a session's **cold first turn** — the one where there is no
cached block yet and no conversation to fall back on. That turn holds the prompt open
waiting for the first fetch, then proceeds without it if nothing has landed. Every
later turn is served from cache in microseconds and never waits, however stale the
block is: stale memory beats a stalled turn.

`LEMON_HONCHO_FIRST_TURN_WAIT_MS` (3 seconds by default) sets that wait, and it lands
inside a ceiling it does not control. Lemon's prompt assembly gives any one contributor
at most 3 seconds; Honcho asks for your value plus a 200 ms margin and takes whichever
is smaller, then answers just inside that so the prompt builder never cuts it off
holding an answer. Two things follow. Setting the variable above **2,800** buys no more
time — the sum is already at the ceiling, and a fetch that has not landed by then is
cached for the next turn instead, which is exactly what a shorter wait would have
produced one turn earlier. And setting it to `0` removes the wait entirely, so memory
appears from turn two onward.

**Cold and warm queries.** The dialectic asks a different question depending on what
is already known. With no context yet it asks the general one — who is this person,
how do they work, what do they want. Once there is context it asks the scoped one —
given this session and this message, what is relevant right now. That switch is
automatic.

### Where the block goes

Recalled context is not delivered in one piece, and which piece goes where is decided
by a single rule:

> **Anything whose text can differ between two consecutive turns rides your message.
> Anything that is the same for the whole session stays in the system prompt.**

The reason is cost and nothing else — see [the pricing note below](#the-three-knobs) —
but the consequence is worth stating plainly, because half of what memory sends is
machine-generated text travelling inside your own turn.

**The durable half is a section of the system prompt.** It appears as an ordinary
markdown heading among the rest of Lemon's instructions, in the same place a section of
the prompt has always been.

**The volatile half is appended to the message you just sent**, wrapped in a
`<recalled-context>` block, as that message goes to the model. Three things are true of
it, and all three are deliberate:

- **It says what it is.** The block opens with a system note stating that Lemon supplied
  the text, that you did not write it and cannot see it, that it is background rather
  than instruction — where it disagrees with what you actually said, what you said
  wins — and that the model should answer your message rather than reply to the block or
  thank you for information you never gave.
- **It is not stored in your transcript.** The attachment is removed again on the way
  back in. What Lemon saves, replays in the UI, hands to extension hooks, and returns
  from its own message API is the message you typed. Scrolling back through a
  conversation never shows recalled memory attributed to you as something you said.
- **It does stay in what the model is shown on later turns.** Provider caches match on
  an exact prefix, so a turn's bytes have to be replayed verbatim next turn or
  everything after them is re-processed at full price. Each turn's block is therefore
  written once, where it was written, and never rewritten or removed. Replayed history
  is billed at the cache-read rate, a tenth of input.

Nothing here is hidden from the model — it can see both halves and is told where they
came from. What is easy to miss, and is the reason this section exists, is that memory
does not all live in the system prompt: some of it is attached to your turn, and that is
worth knowing whether or not it changes anything you do.

---

## The Three Knobs

Cost and depth are controlled by three settings that do not interact:

| Setting | Controls | Default |
|---|---|---|
| `LEMON_HONCHO_CONTEXT_CADENCE` | Turns between base-layer refreshes | `1` (every turn) |
| `LEMON_HONCHO_DIALECTIC_CADENCE` | Turns between dialectic calls | `2` |
| `LEMON_HONCHO_CONTEXT_TOKENS` | Token budget for the injected block | unset (Honcho decides) |

You can refresh the cheap layer often and the expensive one rarely, or cap the size of
what lands in the prompt without changing either cadence.

> **The dialectic costs money.** It is an LLM call **on Honcho's side**, billed by
> Honcho rather than by your model provider, and it is the only part of this
> integration that reasons rather than reads. `LEMON_HONCHO_DIALECTIC_CADENCE` is the
> gate: at the default of `2` it runs on every second turn; set it to `5` or `10` on a
> chatty session, or set it very high while leaving `LEMON_HONCHO_CONTEXT_CADENCE` at
> `1` if you want the cheap layer on every turn and almost none of the expensive one.
> `honcho_reasoning` hits the same endpoint, so a model calling that tool is spending
> the same way — `LEMON_HONCHO_RECALL_MODE=context` takes that decision away from it.

A refresh counts as spent when it *starts*, not when it succeeds. An endpoint that is
failing every call therefore costs one attempt per cadence window, not one per turn.

> **The other bill is your model provider's, and placement is what decides it.** Lemon
> recomposes the system prompt on every user message, and any byte that differs replaces
> it. On Anthropic the whole system prompt is sent as one cached block — the *prefix* of
> the prompt cache — and a second cache breakpoint sits on the last user message, whose
> prefix contains the system prompt. A cache entry is matched on exact bytes, so one
> changed byte in the system prompt misses both: the system prompt, the tool schemas and
> the conversation so far are all re-processed and re-cached instead of being read from
> cache. Cached reads are priced at a tenth of input; a cache write is priced above it.
> On Claude Sonnet 4's pricing that is `$0.30` versus `$3.75` per million tokens, so one
> changed byte costs about **`$0.17` on a 50,000-token conversation and `$0.35` on a
> 100,000-token one** — once per turn where it changes, not once per request.
>
> **This is why the block is split rather than injected whole.** Memory that is written
> fresh for the turn — the dialectic answer, and anything else whose text depends on
> what you just typed — is attached to your message instead, *after* the last cache
> breakpoint, where changing it costs its own few hundred tokens and nothing else. Only
> material that is expected to be the same bytes next turn belongs in the system prompt.
> See [Where the block goes](#where-the-block-goes).
>
> **What the cadences still buy is how often the system half moves.** Every refresh that
> lands with different text in that half is one full prefix miss, at the prices above;
> the block itself is small, a few hundred tokens, and the cost is not the block but what
> changing it invalidates. `LEMON_HONCHO_CONTEXT_CADENCE=10` moves it about twice in a
> twenty-turn session, and the default of `1` lets it move whenever a refresh brings back
> something new. `LEMON_HONCHO_DIALECTIC_CADENCE` is now a question about Honcho's bill
> rather than your provider's — the dialectic rides your message either way — so the two
> knobs no longer have to be raised together.
>
> `LEMON_HONCHO_RECALL_MODE=tools` avoids all of it in a different way: nothing is
> injected anywhere, so neither half exists, and memory arrives only when the model asks
> for it.

`LEMON_HONCHO_REASONING_LEVEL` (`minimal`, `low`, `medium`, `high`, `max`; default
`low`) sets how hard Honcho reasons on each dialectic call, and
`LEMON_HONCHO_DIALECTIC_MAX_CHARS` (default 600) caps how much of the answer is
spliced into the recalled block — the volatile half of it, which is the one attached to
your message.

---

## Recall Modes

`LEMON_HONCHO_RECALL_MODE` decides how memory reaches the model.

| Mode | Injected context | Memory tools | Use when |
|---|---|---|---|
| `hybrid` (default) | yes | active | You want background on every turn, and explicit lookups when the model wants more |
| `context` | yes | inactive | You want memory to arrive as background only, at a predictable cost per turn |
| `tools` | no | active | You want memory only when the model asks for it |

The mode gates both directions. In `context` mode the five `honcho_*` tools are still
registered, but each one answers a call by saying Honcho is in context-only mode and
makes no request — memory already arrives with the turn, in the two places [Where the
block goes](#where-the-block-goes) describes, and a tool call that also fetched it would
be paying twice for the same material. In `tools` mode nothing is injected in either
place, so the cadence and budget settings do nothing and Honcho is read only when the
model decides to read it.

Two things are outside the mode. Writes are unaffected: a finished run's summaries are
uploaded in every mode unless `LEMON_HONCHO_SAVE_MESSAGES` is false. And Honcho's
registration as a *memory provider* is unaffected too, so `search_memory` still returns
Honcho hits alongside local ones in all three modes.

---

## Session Strategies

A Honcho *session* is the container messages, summaries, and conclusions hang off.
`LEMON_HONCHO_SESSION_STRATEGY` decides which of your runs share one.

| Strategy | One session per | Effect |
|---|---|---|
| `per-directory` (default) | working directory | Every run in a project accumulates into the same memory |
| `per-repo` | git repository | Worktrees and subdirectories of one project share memory instead of fragmenting it |
| `per-session` | Lemon session | Nothing is shared; each conversation starts clean |
| `global` | everything | One session named after the workspace |

Session ids are sanitized to `[A-Za-z0-9_-]` and capped at 100 characters; an
over-long id keeps a readable prefix and gains a short hash, so two long keys that
share a leading segment never collide into one memory.

`mix lemon.honcho sessions` shows the mappings held by *the node the command itself
starts* — not by a Lemon you have running, which is a separate node the command cannot
see. On a normal install it therefore prints nothing at all; see [Command
Line](#command-line).

**How many sessions a node holds is capped.** Lemon keeps a cached memory block per
session in the running process, and that set is bounded: at most **500 sessions**, and
any session untouched for **two hours** is dropped before the cap has to bite. It
matters on a long-lived install — a gateway serving many people — which no longer grows
in memory for every conversation it has ever seen.

Nothing stored in Honcho is affected by this. What is dropped is a local cache, so a
conversation that comes back after its entry was evicted simply starts as a cold
session again: it re-does the one-time setup and pays one cold first turn, and from the
second turn on it is indistinguishable. Because eviction takes the least recently used
first, and 500 is far more conversations than a node runs at once, an active session is
not a realistic candidate.

Eviction is *not* the usual reason a conversation is missing from `mix lemon.honcho
sessions`. That command lists the sessions held by the node it starts, and that node is
never the one that served your turns, so the list is empty whether or not anything was
ever evicted. Read an empty or short list as "this is a different node", not as "my
memory was dropped".

---

## Observation Modes

Honcho models a conversation as two peers exchanging messages — you
(`HONCHO_PEER`, defaulting to your `$USER`) and the assistant (`HONCHO_AI_PEER`,
`lemon`). Each peer has two switches: whether Honcho models it from its own messages,
and whether it observes the other side. `LEMON_HONCHO_OBSERVATION_MODE` picks a preset:

| Preset | You | Assistant | Semantics |
|---|---|---|---|
| `directional` (default) | observes itself and you | observes itself and you | Full mutual observation. Honcho builds a model of you *and* of how the assistant behaves, which is what makes cross-peer questions answerable |
| `unified` | observes itself only | observes you only | A single model of you. Cheaper, and the right choice when one workspace is shared by several assistants |

The presets are the whole of it in Lemon — the four flags cannot be set individually.

---

## Tools

Five tools are registered whenever the app is installed. They report "Honcho is not
configured" as an ordinary result rather than an error, so they are harmless on a host
without a key.

| Tool | What it asks Honcho for |
|---|---|
| `honcho_reasoning` | A synthesized answer about the user — the dialectic endpoint, the expensive one |
| `honcho_search` | Semantic search over stored messages, in this session or across the workspace |
| `honcho_context` | The assembled context: session summary, representation, peer card |
| `honcho_profile` | Read the profile card, or replace it wholesale |
| `honcho_conclude` | One of three exclusive actions: `conclusion` records a fact, `query` searches stored conclusions, `delete_id` removes one |

A conclusion is a fact stated outright rather than inferred — the thing to reach for
when you tell the assistant something it should still know next month. `honcho_conclude`
takes exactly one of its three parameters per call; passing none or several is reported
back to the model as invalid input rather than guessed at.

All five go quiet in two situations, and in both the model is told why as a normal
result: on a host with no key or base URL, and in `context` recall mode, where memory
is meant to arrive through the prompt instead. `LEMON_HONCHO_SAVE_MESSAGES=false`
additionally refuses the three actions that write — see [Read-Only
Mode](#read-only-mode). And a call whose text looks like it carries a credential is
refused before anything is sent — see [The Secret Screen](#the-secret-screen).

---

## Command Line

```bash
mix lemon.honcho status                    # Resolved config, then a short reachability probe
mix lemon.honcho sessions                  # Session keys the task's own node has mapped
mix lemon.honcho ping                      # One round trip with a latency figure; non-zero exit on failure
mix lemon.honcho context                   # What the task's own node holds for a session
mix lemon.honcho context --live --session KEY --query "why is the build slow?"
```

**Read this before trusting an answer: the task is its own node.** Every subcommand
starts the umbrella in the node `mix` is running, and that node is never the Lemon
serving your conversations. Two consequences, and the second is the one that misleads.

*It has to boot a whole Lemon to answer.* Listeners bind, a configured Discord bot
connects a second shard, start-up work such as the X API token refresh runs. If Lemon
is already running on the machine, the ports are taken, and the command exits with
`:eaddrinuse` without printing anything. There is no flag that skips this. Stop the
running Lemon first, or run the command from a host that is not serving with the same
`HONCHO_*` variables exported.

*Only two of the four say anything about your install.* `status` and `ping` do, because
both answer node-independent questions — how your environment resolves into a config,
and whether Honcho answers a real request from here. `sessions` and `context` do not:
they read the session manager inside the task's node, which has served no turns, so
`sessions` prints "No sessions tracked yet" and `context` reports an untracked session
however healthy the running install is. They are honest about *that* node; they are not
a window into another one. Use them when the task itself served the turns — a
`--live` assembly, or a script that drives the manager in-process — and use the
assistant's own answers to check a live install.

**How long they can take.** `status` and `ping` make exactly one request and never
retry it, so the worst case is a number you can read off the command line: `--timeout`
if you pass one, otherwise `HONCHO_TIMEOUT_MS` (30 seconds) for `ping` and 5 seconds
for `status`. `status` is meant as a glance and `ping` as the real bound — a wedged
endpoint should tell you it is unreachable in seconds, and `ping` is where you go for
the honest latency. Normal turns still retry a transient failure; only these two are
capped. `sessions` makes no request at all.

**`context` shows what a block looks like**, and it is read-only by default: it tells
you whether the session is tracked in the task's own node, which Honcho session it maps
to, how many turns it has served there, and when its block was last refreshed, without
touching the network or the session. On a fresh node — which is every invocation — that
is "untracked", so the read-only mode is mostly a statement of what `--live` would do.

Add `--live` to assemble the block for real and print it. That is the one subcommand
that produces a block you can read, because the task's own node then serves the turn:
it counts a turn against the session, may start a background refresh, moves the
dialectic cadence window, and can therefore bill a dialectic call. A `--session` key
that node has never served is created as a new tracked session. The command says so
before it does it. What it prints is the block *your* configuration and *your* Honcho
workspace produce for that session key — which is the useful thing — and not a copy of
what some other running Lemon injected.

The API key is never printed by any of these, not even as a prefix, and errors are
scrubbed of it before being shown.

---

## Configuration Reference

| Variable | Default | Purpose |
|---|---|---|
| `HONCHO_API_KEY` | — | API key for the hosted deployment |
| `HONCHO_BASE_URL` | — | Base URL of a self-hosted deployment |
| `HONCHO_ENVIRONMENT` | `production` | Deployment used when no base URL is set: `production`, `demo`, `local` |
| `HONCHO_WORKSPACE` | `lemon` | Workspace owning every peer, session, and conclusion |
| `HONCHO_PEER` | `$USER` | Peer id representing you |
| `HONCHO_AI_PEER` | `lemon` | Peer id representing the assistant |
| `HONCHO_TIMEOUT_MS` | `30000` | Timeout for one attempt at a request; a turn-path call may retry a transient failure twice, `mix lemon.honcho ping` never does |
| `LEMON_HONCHO_ENABLED` | `true` | Master switch; still inert without a key or base URL. Set `false` to ignore a key that stays exported |
| `LEMON_HONCHO_RECALL_MODE` | `hybrid` | `hybrid` (inject + tools), `context` (inject only), `tools` (tools only) |
| `LEMON_HONCHO_SESSION_STRATEGY` | `per-directory` | `per-session`, `per-directory`, `per-repo`, `global` |
| `LEMON_HONCHO_CONTEXT_CADENCE` | `1` | Turns between base-layer refreshes |
| `LEMON_HONCHO_DIALECTIC_CADENCE` | `2` | Turns between dialectic calls |
| `LEMON_HONCHO_CONTEXT_TOKENS` | unset | Token budget for the injected block |
| `LEMON_HONCHO_DIALECTIC_MAX_CHARS` | `600` | Cap on the dialectic answer in the prompt |
| `LEMON_HONCHO_REASONING_LEVEL` | `low` | `minimal`, `low`, `medium`, `high`, `max` |
| `LEMON_HONCHO_OBSERVATION_MODE` | `directional` | `directional` or `unified` |
| `LEMON_HONCHO_SAVE_MESSAGES` | `true` | Set `false` to read memory without writing any: no uploads, and the profile-write and conclusion create/delete actions are refused |
| `LEMON_HONCHO_INJECT_IN_SUBAGENTS` | `false` | Whether subagent runs also get memory injected |
| `LEMON_HONCHO_FIRST_TURN_WAIT_MS` | `3000` | How long a cold first turn may wait for memory. Prompt assembly caps any contributor at 3,000 ms, so values above 2,800 make no difference; `0` disables the wait |
| `LEMON_HONCHO_MESSAGE_MAX_CHARS` | `25000` | Per-message truncation before upload |

One more flag lives outside this table: `LEMON_FEATURE_SESSION_SEARCH` (or `[features]
session_search` in `~/.lemon/config.toml`) gates Lemon's memory ingest, which is the
path uploads travel. It defaults to `default-on`, so run summaries are written to
Honcho unless you set it to `off`.

---

## What Leaves Your Machine

Honcho is a remote service, so this is the section to read closely. Four kinds of text
reach it, and nothing else does.

**1. Run summaries — written by the summarizer, not by you.** When a run finishes,
Honcho receives the run's condensed prompt and answer — the same `prompt_summary` and
`answer_summary` the built-in memory stores, each already capped at 2,000 bytes — one
attributed to your peer and one to the assistant's. Three things all have to be true
for that to happen: `LEMON_HONCHO_SAVE_MESSAGES` is true (the default), the
`session_search` feature is enabled (it defaults to **default-on**, so on a stock
install this is true; `LEMON_FEATURE_SESSION_SEARCH=off` is the kill switch), and the
summaries pass Lemon's secret screen — a run whose summaries look like they carry a
credential is dropped entirely, never redacted, and never handed to any memory
provider.

**2. Your current message, as a retrieval query.** This one is verbatim text you typed,
not a summary. It is sent with each background refresh so that what Honcho returns is
about what you are actually asking, and it goes two ways: as a `search_query` parameter
on the base-layer read, and embedded in the dialectic's question when the session is
warm. The base-layer read is a `GET`, which means the query is also a line in Honcho's
access log.

**3. Whatever a memory tool call passes.** When the model calls `honcho_search` or
`honcho_reasoning`, its query is sent; `honcho_conclude` sends the conclusion it was
asked to record or the query it was asked to search; `honcho_profile` sends the profile
lines it was asked to store. An ordinary `search_memory` call reaches Honcho too, since
Honcho is a registered memory provider, and sends it the search query. That text is the
model's own wording rather than yours, though in practice it is often a verbatim quote
of what you just said. Setting `LEMON_HONCHO_SAVE_MESSAGES=false` stops the two that
write.

**4. Identifiers.** Your workspace name, the two peer ids, and the session id derived
from your working directory, git repository, or session key — sanitized, and hashed
when over-long.

**What is never sent:** tool call arguments and results, file contents, diffs, command
output, and the full transcript of a run. Nothing in Lemon hands that material to this
integration in the first place; the only run content it ever sees is the two summaries.

That last point is worth remembering when a representation seems to have missed
something: the detail may never have been uploaded. To read memory without writing any,
set `LEMON_HONCHO_SAVE_MESSAGES=false` — [Read-Only Mode](#read-only-mode) lists exactly
what that turns off.

### The Secret Screen

Everything under 2 and 3 above passes one gate before it leaves. Two rules, in this
order:

- **Clipped.** Each path has its own size, listed below, and the cut lands on a
  character boundary, so a pasted wall of text becomes its first N characters and no
  more — never half a character.
- **Screened for secrets.** The clipped text — what would actually be sent — is checked
  with the same pattern set Lemon uses to decide whether a memory document is safe to
  store: `password:`/`token=`-style assignments, `sk-…` keys, AWS access-key ids, PEM
  private-key headers, JWTs. Text that trips it is **withheld whole**, never partly
  redacted, because redacting part of it is a guess about where the secret ends. The
  withheld text is not logged anywhere, not even at debug.

| What is sent | Clipped to | If it is withheld |
|---|---|---|
| Your message, as the retrieval query | 1,500 characters | The refresh is made with no query at all, returning a broader, less focused block. You see nothing; nothing fails |
| `honcho_search` / `honcho_reasoning` query | 1,500 characters | The call is refused, and the model is told why |
| `honcho_conclude` conclusion / query | 2,000 / 1,500 characters | The call is refused; nothing is recorded or searched |
| `honcho_profile` card lines | 500 characters per line, 50 lines | The entire write is refused; your stored card is untouched |
| A `search_memory` query, on its way to Honcho | 2,000 characters | Honcho contributes no results to that search; local results are unaffected |

The split is deliberate. Where the text only *narrows* a read, Lemon reads on without
it — losing focus is cheaper than losing the turn. Where the text **is** the request, the
call is refused instead, because a search of nothing reported back as a search of
something would be a wrong answer rather than an empty one. `honcho_profile` refuses
hardest: writing a card replaces it, so sending the surviving lines would delete the
withheld one as a side effect of a safety check.

A refusal is an ordinary tool result, so nothing crashes and the turn continues. The
model is told which parameter tripped the screen, that nothing was sent, stored, or
logged, and to rephrase — and the message never repeats the offending text, since your
transcript is the one place it has not reached.

Two things are left out on purpose. `honcho_context` sends no text of yours at all,
only an optional size budget, so there is nothing to screen. And `honcho_conclude`'s
`delete_id` is an opaque id the model read back from a search; clipping an identifier
would delete the wrong row rather than protect anything.

The screen is pattern matching, not comprehension. It catches credentials in their
common shapes; it will not catch a secret you describe in prose, and it does not make
pasting a key into a prompt safe. It is the last line, not the first.

---

## Read-Only Mode

`LEMON_HONCHO_SAVE_MESSAGES=false` makes the whole integration read-only, not just the
message upload it is named after.

| Still works | Refused |
|---|---|
| The injected context block, on every turn | Uploading a finished run's summaries |
| `honcho_reasoning`, `honcho_search`, `honcho_context` | `honcho_profile` with a `card` (writing the profile) |
| `honcho_profile` with no arguments (reading the card) | `honcho_conclude` with `conclusion` (recording one) |
| `honcho_conclude` with `query` (searching conclusions) | `honcho_conclude` with `delete_id` (removing one) |

Deleting counts as a write — it changes Honcho's store just as much as creating does.
A refused call is an ordinary tool result that says uploads are disabled and names the
variable, so the model can tell you rather than retrying; nothing in Honcho's store
changes and no request is made.

---

## Current Limits

Worth knowing before you go looking for them:

- **Authentication is an API key or nothing.** There is no browser login flow and no
  token refresh.
- **The dialectic is a single pass.** One call at a fixed reasoning level per refresh;
  no self-audit or reconciliation passes, and the level does not scale with the length
  of your message.
- **One peer per install.** Messages arriving through a channel (Telegram, Discord)
  are all attributed to `HONCHO_PEER`; there is no mapping from a platform user id to
  a distinct Honcho peer.
- **Summaries only, no transcript sync.** There is no mode in which the full
  conversation is uploaded — the two per-run summaries are the whole of what Honcho
  models. See [What Leaves Your Machine](#what-leaves-your-machine).
- **Nothing is fetched before you speak.** There is no session-start prewarm; the cold
  first turn's bounded wait is the whole of the warm-up.
- **Observation is preset-only.** `directional` or `unified`; the four underlying
  flags are not individually settable from Lemon.
- **Search returns messages, not runs.** A Honcho result is one utterance, so it fills
  the answer half of a memory document and leaves the run fields empty. Honcho also has
  no partition matching a Lemon agent or workspace, so those scopes search the whole
  workspace rather than narrowing.

---

## Further Reading

- [`docs/user-guide/memory.md`](memory.md) — the built-in memory documents and session search
- [`docs/user-guide/setup.md`](setup.md) — installing and configuring Lemon
- [`apps/lemon_honcho/README.md`](../../apps/lemon_honcho/README.md) — the package, its modules, and its current limits

*Last reviewed: 2026-08-12*
