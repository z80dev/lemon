# LemonHoncho

Long-term memory for agents, backed by [Honcho](https://honcho.dev): a service that
reads a conversation and keeps a model of the people in it.

`lemon_honcho` is a **satellite** of the [Lemon](https://github.com/z80dev/lemon)
agent platform. Nothing in the platform names it. The app contributes itself on the
way up — it registers a `LemonMemory.Provider`, a `LemonAgent.ContextRegistry`
contributor, and its agent tools — so removing it from a build leaves the platform
unchanged, and adding it without credentials leaves it inert.

The built-in memory in `lemon_memory` records *what happened*: a document per run,
searchable later. Honcho models *who you are*: preferences, working style, goals,
accumulated across sessions and summarized back into the turn — part of it into the
system prompt and part of it onto the user's own message, for reasons that are entirely
about the prompt cache and are set out under
[**Where the block goes**](#where-the-block-goes). The two run side by side; Honcho is an
additional provider, never a replacement.

## What is in it

| Module | Purpose |
|---|---|
| `LemonHoncho` | The public face: `config/0`, `configured?/0`, `enabled?/0`, and a redaction-safe `status/0` |
| `LemonHoncho.Config` | Every knob resolved into one struct; never raises, degrades a bad value to its default |
| `LemonHoncho.Client` | The only module that talks HTTP to Honcho; returns `{:ok, term}` / `{:error, term}` and never raises |
| `LemonHoncho.Client.Tripwire` | A client stand-in that refuses every request and names it; what the test environment is pinned to |
| `LemonHoncho.SessionName` | Maps a run to the Honcho session id its memory belongs to, per `session_strategy` |
| `LemonHoncho.SessionManager` | The single process that talks to Honcho: caches the context block per session, refreshes on a cadence, uploads finished runs, and keeps the set of tracked sessions bounded |
| `LemonHoncho.Egress` | The one gate every piece of user-derived text passes on its way out: clip to the caller's budget, then withhold entirely if the clipped text looks like it carries a secret |
| `LemonHoncho.Context` | Pure rendering: turns what Honcho returned into the labelled block a model reads, within budget, and `split/1` divides that block into its stable and volatile halves |
| `LemonHoncho.MemoryProvider` | The `LemonMemory.Provider` implementation registered under the id `"honcho"` |
| `LemonHoncho.ContextContributor` | The `LemonAgent.ContextRegistry` contributor registered under `:honcho`, contributing each half at its own placement |
| `LemonHoncho.Tools.*` | The five agent tools: `Reasoning`, `Search`, `Context`, `Profile`, `Conclude` |

`LemonHoncho.Application` starts `SessionManager` and performs the registrations.
Set `config :lemon_honcho, :start_session_manager, false` to bring the app up
without the process — that is a test affordance, not a supported deployment.

`mix lemon.honcho` inspects the integration from the command line: `status` for the
resolved configuration plus a short reachability probe, `sessions` for the session
mappings held by the node the task starts, `ping` for a scripted round trip that exits
non-zero when Honcho does not answer, and `context` for what that same node would
inject for a session.

**Every subcommand boots the umbrella in its own node**, and that node is never a Lemon
already running on the machine. Two things follow. It cannot start at all where the
listeners are already bound — the command exits with `:eaddrinuse` before printing —
and `sessions` and `context` read the session manager it just started, which has served
no turns, so they report an empty node no matter how healthy the running install is.
`status` and `ping` are the two that transfer, because config resolution and
reachability do not depend on which node asks.

`status` and `ping` each make exactly one request with retries switched off, so the
worst case is a number you can read off the command line: `--timeout` when you pass
one, otherwise `HONCHO_TIMEOUT_MS` for `ping` and 5 seconds for `status` — the shorter
cap being why `status` is a glance and `ping` is the real bound. Ordinary requests on
the turn path still retry a transient failure; only the diagnostic path is capped.
`sessions` touches no network at all. `context` is read-only by
default — it reports the session's tracked state and stops short of the block itself —
and `--live` assembles the block through the production turn path, which counts a turn
against that session and may bill a dialectic call. Nothing any of them prints contains
the API key, and every error they render is scrubbed of the configured key first.

## Activation

The app is part of the umbrella and is named in both runtime releases
(`lemon_runtime_min` and `lemon_runtime_full` in the root `mix.exs`), because every
registration a satellite performs happens in its `start/2` — a release that does not
list it simply never starts it, and the omission would be silent. It is not published
to Hex; there is no `{:lemon_honcho, "~> 0.1"}` to add to an outside project.

So activation is one variable:

```bash
export HONCHO_API_KEY="hk-..."          # hosted Honcho, or
export HONCHO_BASE_URL="http://honcho.internal:8000"   # a self-hosted deployment
```

Either one is enough, and either one is **sufficient on its own**: `LEMON_HONCHO_ENABLED`
defaults to true, so in dev and in a release an exported `HONCHO_API_KEY` turns the
integration on with no second opt-in. Turn it off explicitly with
`LEMON_HONCHO_ENABLED=false` (or `config :lemon_honcho, enabled: false`), which wins
over a key that is still exported.

`mix test` is pinned off twice over, because one pin is defeatable.
`config/test.exs` sets `enabled: false` and `start_session_manager: false`, so nothing
registers and the manager stays out of the tree. But `LemonHoncho.Config` reads the OS
environment ahead of application env, so `LEMON_HONCHO_ENABLED=true` in a developer's
shell wins that argument and switches the suite back on. So the test environment also
pins `config :lemon_honcho, :client` to `LemonHoncho.Client.Tripwire`, which has no
environment fallback and raises — naming the call — instead of opening a socket.
Whatever activates the integration under `mix test`, no request reaches a real
workspace.

Everything the integration would otherwise cost — a registered provider that searches,
a contributor that runs on the turn path — is registered only when
`LemonHoncho.configured?/0` is true, so an unconfigured build pays nothing.

## Configuration

Two prefixes, and the split is deliberate. `HONCHO_*` addresses the service and
matches the spelling Honcho's own SDKs use, so an operator who already exports them
for another client gets a working integration for free. `LEMON_HONCHO_*` names the
knobs that are ours: whether the integration runs, how memory reaches the model, and
how much of a turn it may spend.

| Variable | Default | Purpose |
|---|---|---|
| `HONCHO_API_KEY` | — | API key. Presence of this (or a base URL) enables the integration |
| `HONCHO_BASE_URL` | — | Base URL of a self-hosted deployment. A trailing `/v3` is stripped |
| `HONCHO_ENVIRONMENT` | `production` | Deployment used when no base URL is set: `production`, `demo`, `local` |
| `HONCHO_WORKSPACE` | `lemon` | Workspace owning every peer, session, and conclusion Lemon writes |
| `HONCHO_PEER` | `$USER`, then `user` | Peer id representing the human; sanitized to `[A-Za-z0-9_-]` |
| `HONCHO_AI_PEER` | `lemon` | Peer id representing the assistant |
| `HONCHO_TIMEOUT_MS` | `30000` | Timeout for one attempt at an HTTP call. A turn-path call may retry twice; `mix lemon.honcho`'s probes do not |
| `LEMON_HONCHO_ENABLED` | `true` | Master switch. Still inert without a key or base URL |
| `LEMON_HONCHO_RECALL_MODE` | `hybrid` | How memory reaches the model: `hybrid` (both), `context` (injection only, tools inactive), `tools` (tools only, nothing injected) |
| `LEMON_HONCHO_SESSION_STRATEGY` | `per-directory` | What a session maps to: `per-session`, `per-directory`, `per-repo`, `global` |
| `LEMON_HONCHO_CONTEXT_CADENCE` | `1` | Refresh the base layer every N turns |
| `LEMON_HONCHO_DIALECTIC_CADENCE` | `2` | Run the dialectic (an LLM call on Honcho's side) every N turns |
| `LEMON_HONCHO_CONTEXT_TOKENS` | unset | Soft token budget for the injected block. Unset lets Honcho decide |
| `LEMON_HONCHO_DIALECTIC_MAX_CHARS` | `600` | Hard cap on the dialectic answer spliced into the prompt |
| `LEMON_HONCHO_REASONING_LEVEL` | `low` | Reasoning Honcho spends per dialectic query: `minimal`…`max` |
| `LEMON_HONCHO_OBSERVATION_MODE` | `directional` | Peer observation preset: `directional` or `unified` |
| `LEMON_HONCHO_SAVE_MESSAGES` | `true` | `false` makes the integration read-only: no run uploads, and `honcho_profile`'s write and `honcho_conclude`'s create/delete are refused |
| `LEMON_HONCHO_INJECT_IN_SUBAGENTS` | `false` | Whether subagent runs also get memory injected |
| `LEMON_HONCHO_FIRST_TURN_WAIT_MS` | `3000` | How long a session's cold first turn may block waiting for memory. The value plus a 200 ms margin is clamped to the prompt registry's 3,000 ms contributor ceiling, so anything above 2,800 resolves to the same wait; `0` removes the wait |
| `LEMON_HONCHO_MESSAGE_MAX_CHARS` | `25000` | Per-message truncation applied before upload |

Every variable is declared in `LemonHoncho.Env` and aggregated by `LemonCore.Env`
through the `:env_registries` list, so `LemonCore.Env.by_area(:honcho)` documents them
alongside the rest of the platform's configuration. Each also has an application-env twin — `config :lemon_honcho, recall_mode: :context`
— which `LemonHoncho.Config` consults after the environment and before the default.
A value that is present but unusable (a misspelled enum, a non-numeric integer) is
treated as absent, because a config read on the way up must never take a node down.

## How it plugs into the platform

**Memory provider.** When configured, `LemonHoncho.Application` registers
`LemonHoncho.MemoryProvider` with `LemonMemory.Providers` under the id `"honcho"`,
label `"Honcho"`, source `"satellite"`, scopes `[:session, :agent, :workspace, :all]`,
and a timeout of `HONCHO_TIMEOUT_MS` capped at 5 seconds — search runs on the agent's
path, and a slow provider is a slow turn. Failures are isolated by
`LemonMemory.Providers`, so a Honcho outage narrows results rather than failing a
search.

**Context contributor.** `LemonHoncho.ContextContributor` registers with
`LemonAgent.ContextRegistry` under `:honcho`, which is how a satellite gets text into a
turn without `CodingAgent.SystemPrompt` naming it. It contributes two sections with
different placements — see [**Where the block goes**](#where-the-block-goes) — and the
registry bounds what any contributor may return: eight sections totalling 16 KB per
turn, and 250 ms to produce them. So the contributor returns a value it already has:
`LemonHoncho.SessionManager` hands back the cached block immediately and refreshes in
the background, and `LemonHoncho.Context` budgets that block's size itself rather than
being cut off at the registry's backstop.

The one turn that waits is a session's *cold first turn*, and it takes two halves to
get there. The contributor exports the registry's optional `timeout_ms/1` and asks for
`SessionManager.first_turn_budget_ms/1` — but only when the integration is configured,
the mode injects at all, the wait is switched on, and the manager reports this session
key cold (`SessionManager.cold?/1`, one map lookup inside the manager); every other
turn gets the 250 ms default back, because a raised budget on a warm turn is pure
latency. The manager, for its part, replies `{:wait, …}` only on turn zero and only
while that turn's refresh is genuinely in flight, parks the caller in the session's
waiter list, and answers it the moment the refresh lands, expires, or dies.

The budget is `first_turn_wait_ms + 200 ms`, clamped to the registry's own hard
ceiling of 3,000 ms, and the manager then waits for strictly *less* than that: it
subtracts the time the first call already spent plus 50 ms of headroom, so the reply is
travelling back before the registry's deadline rather than racing it. Two consequences
worth knowing before setting the knob. Raising `LEMON_HONCHO_FIRST_TURN_WAIT_MS` above
2,800 buys nothing — the sum saturates at the ceiling, and a refresh that has not
landed by then is cached for the next turn instead, which is what a shorter wait would
have produced one turn earlier. And budgets are per contributor, so Honcho's cold turn
never extends anyone else's 250 ms.

**Tools.** The five tools register with `LemonAgent.ToolRegistry` unconditionally,
because a model that asks for memory on an unconfigured host should be told so rather
than handed an error:

| Tool | Honcho capability it exposes | Refused when |
|---|---|---|
| `honcho_reasoning` | The dialectic: a synthesized answer about a peer, an LLM call on Honcho's side | — |
| `honcho_search` | Semantic search over stored messages, in one session or across the workspace | — |
| `honcho_context` | The assembled session and peer context: summary, representation, peer card | — |
| `honcho_profile` | Reading a peer card, or replacing it wholesale | writes, when `save_messages?` is false |
| `honcho_conclude` | Three exclusive actions: `conclusion` creates, `query` searches, `delete_id` deletes | create and delete, when `save_messages?` is false |

Two gates sit in front of all five, and both answer as ordinary tool results rather
than errors. An unconfigured host says so and names the variable to set. And
`recall_mode: :context` makes every one of them inactive — that mode means "memory
reaches the model through the prompt, not through tool calls", so a call in that mode
is answered with a statement to that effect and no request is made.
`recall_mode: :tools` is the mirror image: the tools work, and nothing is injected.

**Writes.** A finished run reaches Honcho as two messages — the run's
`prompt_summary` and `answer_summary` — attributed to the user and assistant peers.
Uploads are fire-and-forget and never block finalization. Three conditions all have to
hold for one to happen:

* `LEMON_HONCHO_SAVE_MESSAGES` is true (the default). When it is false the upload is
  dropped in `SessionManager`, and the two write actions the tools expose are refused
  as well — reads keep working, which is what read-only means.
* The `session_search` feature is on. Uploads ride the built-in ingest pipeline
  (`LemonMemory.Ingest` → `LemonMemory.Providers.put/1` → this provider), and that
  pipeline is gated by a flag that defaults to `off`. Turn it on with
  `LEMON_FEATURE_SESSION_SEARCH=on` or `[features] session_search = "on"` in
  `~/.lemon/config.toml`.
* The document passes `LemonMemory.Safety.safe_document?/1`. A run whose summaries look
  like they carry a credential is never handed to any provider, Honcho included.

## Bounded session state

The manager keeps one entry per session key — the assembled block plus the halves it
was assembled from — and the map they live in is capped at **500 keys** and swept by a
**two-hour idle TTL**. A long-lived gateway therefore stops growing rather than
accumulating an entry for every conversation it ever served. The sweep runs when a key
is *added*, which is the only moment the map can grow, so a session pays for it once in
its life; it sheds idle entries before the cap has to, and takes the least recently
touched first. Serving a turn and uploading a finished run both count as touching a
session, so a deployment in `recall_mode: :tools` — where uploads are the only thing
creating entries — is bounded on the same terms.

Eviction is safe because an entry is a cache and nothing else. Nothing stored in Honcho
is affected, and the next turn for an evicted key re-initialises it exactly as a key
this node has never seen. What that costs is one cold turn: the get-or-create setup
round trips run again, and that turn waits like any other first turn. 500 is far more
concurrent conversations than a node serves inside the window a session stays warm, so
a live session is not a realistic candidate for eviction. An entry with a refresh in
flight or a caller parked on it is skipped rather than evicted — dropping it would
orphan a worker and strand a waiter — which is why the cap can be exceeded briefly, by
at most the number of refreshes running.

`mix lemon.honcho sessions` lists what is *tracked*, so a session that ended hours ago,
or that lost its slot to the cap, is absent there even though Honcho still holds its
record. It also lists what is tracked *in the node the task starts*, which is not the
node that served those turns, so on a running install the list is empty for that reason
long before eviction is the reason.

## What leaves the machine

Honcho is a remote service, so this is a list worth being exact about. Four kinds of
text reach it, and nothing else does:

1. **Run summaries.** The `prompt_summary` and `answer_summary` of a finished run,
   each written by the summarizer rather than by the user, each already capped by
   `LemonMemory.Document` at 2,000 bytes and clipped again to
   `LEMON_HONCHO_MESSAGE_MAX_CHARS`, and each screened by `LemonMemory.Ingest` before
   it reaches this app at all. Subject to the three conditions under **Writes** above.
2. **The retrieval query.** The user's current message, sent with the base-layer read
   so that the representation Honcho returns is focused on what is being asked, and
   embedded in the dialectic's warm question for the same reason. This is verbatim
   user text — not a summary — and on the base-layer read it travels as a URL query
   parameter on a `GET`, which means it is also a line in the far side's access log.
   Both halves of a refresh take their text from one already-screened value, so
   neither can reach the wire by a route the screen does not cover.
3. **Whatever a tool call passes.** `honcho_search` and `honcho_reasoning` send the
   model's query; `honcho_conclude` sends the conclusion text it was asked to record or
   the query it was asked to search; `honcho_profile` sends the peer-card lines it was
   asked to store. A `search_memory` call reaches Honcho the same way, through
   `LemonHoncho.MemoryProvider`, and sends its query. This material is the model's own
   words — often a verbatim paste of what the user just said — and is sent only when the
   model calls the tool. `LEMON_HONCHO_SAVE_MESSAGES=false` stops the two that write.
4. **Identifiers.** The workspace name, the two peer ids, and the derived session id —
   which is built from the working directory, git repository, or session key that
   `LEMON_HONCHO_SESSION_STRATEGY` selects, sanitized and possibly hashed.

Tool call arguments and results, file contents, diffs, and the full transcript of a run
are not sent, because nothing in this app ever receives them: the only run material it
sees is the two summaries.

### The egress screen

Every path above that carries user-derived text — everything under items 2 and 3 —
goes through `LemonHoncho.Egress.screen/2` first, and the
policy is two steps in a fixed order. **Clip** to the caller's budget, counted in
graphemes so a cut never splits a character. Then **screen the clipped text** — the
bytes that would actually travel — with `LemonMemory.Safety.contains_secret?/1`, the
same check `LemonMemory.Ingest` runs over a summary before any provider sees it. Text
that trips the screen is withheld *whole* rather than partly redacted: a partial
redaction is a guess about where the secret ends, and the cost of guessing wrong is a
credential in someone's access log. The withheld text is never logged, not even at
debug.

The budget belongs to the call site, and so does what withholding means there:

| Path | Text | Clipped to | Withheld means |
|---|---|---|---|
| Base-layer read and dialectic (`SessionManager`) | the user's current message | 1,500 characters | the reads are made with no query at all — a broader, less focused block, and nothing the user sees |
| `honcho_search` `query` | the model's query | 1,500 characters | the call is **refused**; no search runs |
| `honcho_reasoning` `query` | the model's question | 1,500 characters | the call is **refused**; no question is asked |
| `honcho_conclude` `conclusion` | the fact to record | 2,000 characters (anything longer is rejected outright, so the clip never fires) | the call is **refused**; nothing is recorded |
| `honcho_conclude` `query` | the model's query | 1,500 characters | the call is **refused**; no search runs |
| `honcho_profile` `card` | each card line | 500 characters per line, at most 50 lines (over-long lines are rejected outright) | the **whole write** is refused; the stored card is untouched |
| `search_memory` via `LemonHoncho.MemoryProvider` | whatever the search was given | 2,000 characters | the search returns no Honcho results, with no explanation |

A refusal is an ordinary tool result, not an error: the turn continues, the model is
told which parameter tripped the screen and that nothing was sent, stored, or logged,
and it can rephrase and call again. The result never repeats the offending text — the
transcript is the one place it has not reached. A tool refuses rather than sending the
clipped remainder because there the text *is* the request, and a search of nothing
reported as a search of something is a wrong answer rather than an empty one;
`honcho_profile` refuses hardest, since a card write is a replace and sending the
surviving lines would delete the withheld one as a side effect of a safety check.

Neither of the two non-tool paths can report a withhold, and neither needs to fail over
it. The session manager reads on without a query, since there the query only focuses the
representation. The memory provider returns the same `[]` every other failure returns,
because `LemonMemory.Provider` gives `search/2` exactly one channel; a caller that needs
to know why asks a tool.

Two things are deliberately not screened. `honcho_context` sends no user-derived text
at all — only an optional token budget — so it has nothing to screen. And
`honcho_conclude`'s `delete_id` is an opaque id the model read back from a `query`;
clipping an identifier would address the wrong row rather than protect anything.

The screen is pattern matching, not comprehension: assignments like `password:` or
`token=`, `sk-…` keys, AWS access-key ids, PEM private-key headers, JWTs. It is the
last line, not the first.

## The two layers, and what they cost

Honcho's memory arrives in two layers with very different prices, gated by two
counters that never interact:

* The **base layer** — session summary, the user's representation and peer card, the
  assistant's own representation. Ordinary reads, refreshed every
  `LEMON_HONCHO_CONTEXT_CADENCE` turns.
* The **dialectic** — one synthesized answer to "what matters right now". This is an
  LLM call on Honcho's side and is the expensive part of the integration, refreshed
  every `LEMON_HONCHO_DIALECTIC_CADENCE` turns.

Cadence markers advance when a refresh is *started*, not when it succeeds, so an
endpoint failing every call costs one attempt per window rather than one per turn.

## Where the block goes

There is a third price, and it is not Honcho's — it is the prompt cache, and it is what
decides where each half of the block is placed.

`CodingAgent.Session` recomposes the system prompt on every user message, and
`LemonAi.Providers.Anthropic` sends the whole of it as one `cache_control: ephemeral`
block with a second breakpoint on the last user message, whose prefix *contains* the
system prompt. A cache entry is matched on exact bytes, so one changed byte in the system
prompt misses both breakpoints: the system prompt, the tool schemas and the entire
conversation behind them are re-processed and re-cached at the cache-write price instead
of being read at a tenth of input. On Claude Sonnet 4's entry in `LemonAi.Models` that is
`$3.75` against `$0.30` per million tokens — roughly `$0.17` at a 50,000-token prefix and
`$0.35` at 100,000, once per changed turn.

The rule that follows is the whole of the placement policy, and it is the registry's, not
this app's:

> **Anything whose text can differ between two consecutive turns rides the user message.
> Anything that is the same for the whole session belongs in the system prompt.**

So `ContextContributor` splits what the manager assembled and contributes it as two
sections with two placements. The durable material — peer card, representation, session
summary — goes at `:system` and is rendered as a heading in the system prompt. The
dialectic supplement, which is freshly generated prose answering a question that embeds
the user's current message, goes at `:user_message`: `CodingAgent.Session` appends it to
the outgoing message inside a `<recalled-context>` block, after the last cache
breakpoint, where rewriting it every turn costs its own few hundred tokens and nothing
else.

Three properties of that second half are worth knowing before changing anything near it.

*It is labelled as system-supplied.* The block opens with a note saying Lemon wrote it,
that the user did not and cannot see it, that it is background rather than instruction —
what the user actually said wins — and that the model should not reply to it or thank the
user for it. Text inside a user turn is otherwise read as the user's own words.

*It is not in the transcript.* `CodingAgent.Session` strips it from `get_messages/1`, from
broadcast events, and therefore from persistence, extension hooks and the UI. What a
person scrolls back through is what they typed.

*It stays in the agent's replayed history.* That is the cache working, not a leak: turn
N's bytes must be replayed verbatim on turn N+1 or the prefix diverges there and
everything after it re-prefills, which would give back exactly what the placement bought.

What the cadences still decide, in provider terms, is how often the **system** half moves;
each move is one full prefix miss at the prices above. `dialectic_cadence` is now a
question about Honcho's bill rather than the model provider's, since the dialectic rides
the user message either way. The corollary for anyone touching `LemonHoncho.Context`:
stability of the stable half is a feature, and anything that makes the same underlying
facts render differently there — a timestamp, a non-deterministic ordering, a
query-dependent selection — costs a full cache miss per turn and buys nothing.

## What it does not do yet

Worth knowing before you go looking for it:

* **No OAuth.** Authentication is a bearer `HONCHO_API_KEY`, or none at all against a
  self-hosted endpoint. There is no browser login flow and no token refresh.
* **No multi-pass dialectic.** A refresh makes exactly one `chat` call at a fixed
  reasoning level. There is no self-audit or reconciliation pass, no per-pass
  reasoning levels, and no scaling of the reasoning level by query length.
* **No gateway peer mapping.** Every run resolves to the single `HONCHO_PEER`; there
  is no mapping from a channel's runtime identity (a Telegram user id, a Discord
  snowflake) to a distinct Honcho peer, and no per-peer aliases or prefixes.
* **Message sync is summaries, not transcripts.** What Honcho models is
  `LemonMemory.Document`'s `prompt_summary` and `answer_summary`, each already capped
  upstream at 2,000 bytes; there is no full-transcript sync and no upload of tool
  calls, tool results, or file contents. A representation that "missed" something
  usually never received it — see **What leaves the machine** for the complete list.
* **No per-peer observation override.** Only the two presets, `directional` and
  `unified`; there is no way to set the four observation flags individually.
* **No session-start prewarm.** The first turn's bounded wait is the whole of it —
  nothing is fetched before the user speaks.
* **Search results are messages, not runs.** A Honcho hit is one utterance by one
  peer, so `LemonHoncho.MemoryProvider` puts it in `answer_summary` and leaves
  `prompt_summary`, `run_id`, `tools_used`, and `model` empty. Honcho also has no
  partition matching a Lemon agent id or workspace key, so `:agent` and `:workspace`
  searches degrade to a workspace-wide semantic search rather than narrowing.
