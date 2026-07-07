# Dialyzer Warning Burn-down Plan

Status: initial triage complete (this document); no source fixes applied yet — see Phase 1+ below.

Last reviewed: 2026-07-07

## Summary

The advisory Dialyzer CI lane (`.github/workflows/dialyzer.yml`, `mix dialyzer
--format dialyzer`, `continue-on-error: true` at the job level) surfaces around
**1,599 warnings** as of this snapshot (2026-07-07, PLTs warm, umbrella HEAD —
see "A note on the count" below). This document categorizes them, names the
mechanical root cause and fix pattern for each category, lists concrete real
bugs found during spot-checking, explains the 18 `.dialyzer_ignore.exs`
entries added alongside this doc, and lays out a phased plan to make parts of
the lane blocking without a big-bang rewrite.

**No application code was changed in this pass.** The only code change is
`.dialyzer_ignore.exs`.

## A note on the count

This is a live, multi-agent umbrella under active refactoring. Between the
first pass of this triage and the final one (roughly 20 minutes apart, same
session), the total went from 1,340 to 1,599 raw warnings, almost entirely
because concurrent work in this same session (tasks unifying the
`lemon_sim` domain registry and decomposing several "god module" updaters)
temporarily left new functions unwired. Treat the exact numbers below as a
snapshot, not a stable baseline — re-run `mix dialyzer --format dialyzer` and
recount before using this as a regression gate (see Phase 4).

## Counts

### By category (1,599 total, after the 41 warnings suppressed by `.dialyzer_ignore.exs`)

| Category | Count | % |
|---|---:|---:|
| `unmatched_return` | 440 | 27.5% |
| `pattern_covered_by_prior_clauses` | 321 | 20.1% |
| `function_will_never_be_called` | 284 | 17.8% |
| `guard_never_succeed` | 147 | 9.2% |
| `pattern_cant_match_type` | 146 | 9.1% |
| `no_local_return` | 137 | 8.6% |
| `invalid_contract` | 54 | 3.4% |
| `callback_spec_mismatch` | 45 | 2.8% |
| `unknown_type` | 9 | 0.6% |
| `unknown_function` | 9 | 0.6% |
| `call_arg_mismatch` | 6 | 0.4% |
| `fun_app_mismatch` | 1 | 0.1% |

(Category names here are my own groupings by message shape for this report,
not raw Dialyzer/dialyxir warning-type atoms — those are noted per-category
below where relevant.)

### By app (post-ignore-file)

| App | Count |
|---|---:|
| lemon_sim | 334 |
| coding_agent | 284 |
| lemon_channels | 174 |
| lemon_core | 128 |
| agent_core | 119 |
| lemon_router | 108 |
| lemon_control_plane | 106 |
| lemon_gateway | 75 |
| lemon_sim_ui | 68 |
| lemon_skills | 43 |
| ai | 41 |
| lemon_automation | 37 |
| lemon_mcp | 20 |
| lemon_cli | 13 |
| x_api | 13 |
| lemon_tcg | 12 |
| lemon_evals | 9 |
| coding_agent_ui | 6 |
| lemon_lsp | 4 |
| lemon_media | 4 |
| lemon_browser | 1 |
| **lemon_web** | **0** |

`lemon_web` is the only app with zero warnings; every other app in the
umbrella has at least one.

## Category analysis

### `unmatched_return` (440, 27.5%) — mostly noise, but not uniformly safe

**Root cause:** the `:unmatched_returns` Dialyzer flag (enabled in root
`mix.exs`) flags any statement whose value (typically `:ok | {:error, _}`)
is discarded without being matched. This is idiomatic, common Elixir style
(`File.mkdir_p(dir)`, `EventStream.push(stream, event)`, telemetry emits) and
dialyxir's own docs call this flag noisy for exactly this reason.

**Bug risk vs. noise:** mostly noise, but not always safe to ignore blanket.
Spot-checked `agent_core/lib/agent_core/proxy.ex:303`
(`EventStream.push(stream, event)` return discarded) — this silently drops
the `{:error, :canceled | :overflow}` case, meaning an event can be dropped
during stream overflow with no log/backpressure signal. That's arguably
fine (fire-and-forget event streaming is a reasonable design), but it's the
kind of case worth a human's judgment call, not a blanket dismissal.

**Fix pattern:** either bind with `_ = expr` (documents "I know, and it's
fine") or handle the error explicitly. This is the category most likely to
need an explicit **policy decision** rather than mechanical fixing — see
Phase 3.

### `pattern_covered_by_prior_clauses` (321, 20.1%) + `pattern_cant_match_type` (146, 9.1%) + `guard_never_succeed` (147, 9.2%, includes `"The test ... can never evaluate to ..."` variants)

**Root cause (confirmed via spot-check):** these three are the same family —
Dialyzer thinks a clause/guard/pattern is unreachable given the *declared or
inferred* type of the value flowing in. Spot-checked
`apps/coding_agent/lib/coding_agent/rate_limit_healer.ex:313` (`:error ->`
branch in `handle_info(:probe, ...)`, paired with the `pattern_cant_match_type`
warning right below it): `execute_probe/1`'s `@type probe_result ::
:rate_limited | :recovered | :error` *does* include `:error`, and
`handle_info` correctly matches on it — but `do_probe_request/1`'s only
concrete implementation of `verify_provider_connectivity/1` unconditionally
returns `:ok`, so the `{:error, reason}` catch-all in `execute_probe/1` (and
therefore the whole `:error` branch downstream) is dead **today**, not
because the code is wrong, but because the extension point the doc comment
promises ("Providers can implement more sophisticated checks") was never
wired up. This is a real, if low-severity, finding — see "Real bugs found."

**Bug risk vs. noise:** mixed. Some are truly-defensive, harmless dead
branches (leftover `nil`-checks against values specs say can't be nil).
Others, like the above, reveal an incomplete feature or an inaccurate spec
elsewhere. A recurring **noise sub-pattern** worth calling out separately:
several `pattern_cant_match_type` warnings read `The pattern 'false' can
never match the type 'true'` and are all attributed to **line 1** of the
file (seen in `agent_core/model_runtime/model_catalog.ex`,
`ai/auth/github_copilot_oauth.ex`, `coding_agent/run_graph_server.ex`,
`coding_agent/session/compaction_manager.ex`). Line 1 is `defmodule Foo do`
in every case — this is very likely a macro-expansion/line-attribution
artifact (Dialyzer losing original source location for compiler-generated
code, most likely from an `if`/`unless`/`case` expansion whose one branch it
can prove unreachable). I did not fully pin down the generating macro in
this pass, so I did **not** add it to `.dialyzer_ignore.exs` — it needs one
more investigation pass before anyone blanket-ignores it.

**Fix pattern:** app-by-app spec tightening (widen specs that undersell
reality, like `probe_result`'s consumers) and targeted dead-code removal
(where the branch really is unreachable). No mechanical fix applies
across the board; this is the single largest chunk of *real* triage work.

### `function_will_never_be_called` (284, 17.8%) — dominated by one systemic false-positive, not dead code

**Root cause (confirmed via spot-check):** this category's per-file shape is
extremely regular — nearly every `lib/lemon_sim/examples/<domain>.ex` file
(auction, intel_network, courtroom, diplomacy, legislature, murder_mystery,
skirmish, startup_incubator, supply_chain, dungeon_crawl, pandemic,
tic_tac_toe — 10 to 13 warnings each) shows up, plus
`lemon_sim_ui/sim_manager.ex` (30, the single largest file in this category)
and several `coding_agent/tools/*.ex` files (`grep.ex` 23, `find.ex` 14,
`ls.ex` 14, `read.ex` 9) and `lemon_core/config.ex` (16). I traced one
concretely: `LemonSim.Examples.Auction.run/1` calls
`build_after_step_callback/1` in the same module (so the *local* call graph
is fine) — but Dialyzer still flags `build_after_step_callback/1` as
unreachable, meaning it believes `run/1` itself is never called. `run/1` is
in fact only invoked through the domain descriptor/registry that tasks in
this same session unified (`lemon_sim/bench/domains.ex`,
`lemon_sim/bench/domains/descriptor.ex`, `lemon_sim/kernel/runner.ex`) —
i.e., dynamic dispatch by domain atom, which Dialyzer's static call graph
cannot trace. `lemon_sim_ui/sim_manager.ex`'s `build_initial_state/3` shows
the same shape (one big function with a clause per domain atom, dispatched
generically). The `coding_agent/tools/*.ex` files are the same pattern one
level down: tools are looked up and invoked by name from a tool registry,
not called directly from Elixir source.

**Bug risk vs. noise:** mostly noise (registry/plugin dispatch is invisible
to Dialyzer, permanently, not a bug in the code), but this diagnosis is a
sample, not a full audit of all 37 files in this category — a small number
of genuinely dead functions could be hiding among them.

**Fix pattern:** two options, in order of preference:
1. If these entry-point functions are meant to satisfy a shared contract
   (domain modules, tool modules), formalize it as a `@behaviour` with
   `@callback`s and `@impl true` on the implementations. Dialyzer treats
   `@impl true` callback implementations as "used" by the behaviour's own
   dispatch, which fixes this structurally instead of per-function.
2. Where a shared behaviour doesn't fit, add `@dialyzer {:nowarn_function,
   [{:run, 1}, ...]}` at the top of each confirmed-dynamically-dispatched
   module, scoped to the actual entry points only (not blanket per-file).

### `no_local_return` (137, 8.6%) + `invalid_contract` (54, 3.4%) — correlated, not fully diagnosed

**Root cause:** these two overlap almost function-for-function in
`coding_agent` (`session.ex:542/544 init/1`, `session/lifecycle.ex:23/25
initialize/2`, `session_fork.ex:110/111 build_fork_message/3`,
`extension_lifecycle.ex`, `tools/file_validation.ex check_path_access/1`).
A function whose declared `@spec` promises a normal return, but whose
success typing shows it *always* raises/exits given how it's actually
called in this codebase, gets both warnings together (the spec becomes
"invalid" as a side effect of the no-local-return finding). I spot-checked
`check_path_access/1` — one of the auto-generated default-argument arities
of a function whose real 3-arity body is a plain, non-raising `File.stat`
dispatcher — and could not conclusively determine in this pass why the
1-arity wrapper specifically is flagged. **This cluster needs a dedicated
follow-up** rather than a guess here; I'm flagging it rather than
asserting a root cause I haven't verified.

**Fix pattern:** TBD pending the follow-up above. Possible causes to check
first: whether `init/1`/`initialize/2` etc. are GenServer-style callbacks
invoked reflectively (so Dialyzer only sees the raising branches actually
exercised by real callers in this app) vs. a genuine spec/body mismatch.

### `callback_spec_mismatch` (45, 2.8%)

**Root cause (confirmed via spot-check):** `coding_agent/session.ex:957`
calls `Notifier.broadcast_event(state, {:extension_status_report, report})`,
and `broadcast_event/2`'s declared parameter type
(`AgentCore.Types.agent_event()`) doesn't include
`{:extension_status_report, _}` in its union. Same shape as the
`rate_limit_healer` finding above — the event-type union is a maintained
list that didn't get updated when this event variant was added. Not a
runtime bug (Elixir doesn't enforce specs), but it does mean Dialyzer can't
verify anything downstream of `broadcast_event/2` for this event shape.

**Fix pattern:** add missing variants to the relevant `@type ... ::
element1 | element2 | ...` union each time a new event/callback shape is
introduced. Mechanical, low-risk, but requires touching the type definition
alongside the new variant (a habit/review-checklist item, not a one-time
fix).

### `unknown_type` (9, 0.6%) — all one bug class, all real (low-severity)

**Root cause (confirmed via spot-check, all 9):** every one of these is a
bare, unqualified type reference in a `@type`/`@spec`/`@callback` that
resolves to a **nonexistent top-level module** because the file never
established the alias the shorthand assumes:

- `agent_core.ex:178`: `@type agent :: AgentCore.Agent.t()` — but
  `AgentCore.Agent` doesn't define `@type t` at all.
- `agent_core.ex:256`: `Types.agent_message()` — only
  `alias AgentCore.Types.{AgentContext, AgentTool, AgentToolResult}` is in
  scope (destructuring an alias list does **not** alias `AgentCore.Types`
  itself to bare `Types`), so this resolves to nonexistent `Elixir.Types`.
- `agent_core/agent.ex:1218`: `AgentEvent.t()` — no alias for `AgentEvent`
  is in scope in this file at all (only `alias AgentCore.Types`,
  `alias AgentCore.Types.{AgentLoopConfig, AgentState}`); resolves to
  nonexistent `Elixir.AgentEvent`.
- `lemon_gateway/engine.ex:44-45`: `@callback format_resume(ResumeToken.t())
  :: String.t()` / `extract_resume(...) :: ResumeToken.t() | nil` — the file
  has `alias LemonGateway.Types.{Job, ResumeToken}`, but
  `LemonGateway.Types.ResumeToken` doesn't exist; resume-token handling
  appears to have moved to `LemonCore.ResumeToken`
  (`apps/lemon_core/lib/lemon_core/resume_token.ex` exists) without this
  alias/callback being updated.
- `ai/types.ex` (`AssistantMessage`'s nested `@type t`): `usage: Usage.t()`
  — `Usage` is a sibling nested module (`Ai.Types.Usage`, defined at
  `ai/types.ex:145`), but Elixir's automatic nested-module aliasing only
  applies to code written directly in the *outer* module's own body, not
  to a different nested submodule's body; resolves to nonexistent
  `Elixir.Usage`.

**Bug risk vs. noise:** real, but low severity — these break Dialyzer's
ability to verify anything using these types (silently disabling coverage
downstream), and they're wrong/confusing documentation, but Elixir doesn't
enforce `@spec`/`@type` at runtime, so nothing crashes.

**Fix pattern:** mechanical, one alias or type-target fix per site. Good
first blocking-readiness milestone — small, bounded, unambiguous.

### `unknown_function` (9, 0.6% — was 11 before `.dialyzer_ignore.exs`)

**Root cause:** two distinct causes bucketed under one Dialyzer warning
type:
1. **7 remaining, fixable via config — NOT ignored:** `Nostrum.Api.Message`,
   `Nostrum.Api.Thread`, `Nostrum.Api.Interaction`, `Nostrum.Api.Webhook`,
   `Nostrum.Api.ApplicationCommand` calls in
   `lemon_channels/adapters/discord/*.ex`, plus one *inside nostrum's own
   source* (`Nostrum.ConsumerGroup.join/1` called from
   `deps/nostrum/lib/nostrum/consumer.ex`). `apps/lemon_channels/mix.exs`
   declares `{:nostrum, "~> 0.9", runtime: false}` — the `runtime: false`
   means nostrum is never added to the `.app` resource's `applications`
   list, so dialyxir's automatic per-app PLT discovery never pulls
   nostrum's modules in, even though they compile and run fine. This is a
   **PLT configuration gap, not a real bug** — confirmed by the fact that
   even nostrum's own internal cross-module call trips the same warning.
2. **2, permanently unfixable — ignored in `.dialyzer_ignore.exs`:**
   `IEx.Helpers.recompile/0`, called from the Discord and Telegram `/reload`
   admin commands. `:iex` is intentionally never a production/release
   dependency, so it can never be in the PLT; this only works when the
   release is attached to a live IEx session. Permanent by design.

**Fix pattern:** add `:nostrum` to `plt_add_apps` in root `mix.exs`
`dialyzer/0` (Phase 1, below) — cheap, config-only, kills 7-8 warnings
(and probably the 1 stray `Nostrum.Consumer` `callback_info_missing`
warning noticed alongside it, which wasn't in the 1,599 count above because
it's a `[:unknown]`-flag warning suppressed by default flags — worth
re-checking once `:nostrum` is added).

### `call_arg_mismatch` (6, 0.4%) + `fun_app_mismatch` (1, 0.1%) — highest signal-to-noise; contains a real crash bug

**Root cause:** Dialyzer's strongest, most literal signal — an actual call
site whose argument types don't match the callee's inferred success typing,
meaning the call **will** crash if that code path executes.

**Real bug found (see below):** `apps/x_api/lib/x_api/client.ex:585`.

**Fix pattern:** these should be fixed one-by-one as found, not batched —
each is worth reading in full. Given the size of this category (7 total),
a full read-through is cheap.

## Real bugs found

Per instructions, none of these were fixed in this pass — flagging them
prominently for follow-up:

1. **`apps/x_api/lib/x_api/client.ex:584-594` `get_retry_after/1` — will
   crash every time it's actually exercised (HIGH severity).**
   ```elixir
   defp get_retry_after(headers) do
     case List.keyfind(headers, "x-rate-limit-reset", 0) do
       ...
   ```
   `headers` comes from `post_tweet/3`'s `{:ok, %{status: 429, headers:
   headers}}` match on `request/4`'s result, and `request/4` is a thin
   wrapper around `Req.request/1` — so `headers` is a `Req.Response`
   headers **map** (`binary() => [binary()]`), not a list of `{key, value}`
   tuples. `List.keyfind/3` requires a list and will raise whenever this
   function actually runs, i.e. every time X API returns HTTP 429 with
   `attempt < @max_retries`. The rate-limit backoff path for posting tweets
   is currently broken — it will crash instead of backing off. Fix:
   `Map.get(headers, "x-rate-limit-reset")` (returns a list per Req's
   convention; take the first element) instead of `List.keyfind/3`.

2. **9 stale/missing type aliases across `agent_core`, `lemon_gateway`, and
   `ai` — see the `unknown_type` section above for the full list and exact
   locations.** Low severity (no runtime crash), but genuinely wrong
   `@type`/`@spec` declarations, and each one silently disables Dialyzer
   coverage for code using that type.

3. **`apps/coding_agent/lib/coding_agent/rate_limit_healer.ex` — the
   provider-connectivity probe currently can't detect real connectivity
   failures, only local rate-limiter exhaustion (MEDIUM severity, design
   gap not crash).** `verify_provider_connectivity/1`'s only implementation
   unconditionally returns `:ok`; the doc comment ("Providers can implement
   more sophisticated checks") implies a per-provider override was
   intended but never wired up. Not urgent, but worth a ticket — the
   healer's "probe" is currently a no-op check beyond the rate limiter
   itself.

## `.dialyzer_ignore.exs` entries added

18 entries, all commented in-file with why. Two justified classes only —
nothing blanket:

- **16 entries for `call_with_opaque`/`call_without_opaque`** (MapSet, and
  structs holding a MapSet field, like `TermUI.Renderer.Style` and `URI`):
  a well-known, permanent Elixir+Dialyzer PLT limitation, not a real bug.
  Scoped per-file + per-warning-type (not blanket per-file), so a genuine
  `unmatched_return` or `pattern_covered` bug in the same file would still
  surface.
- **2 entries for `IEx.Helpers.recompile/0`** (Discord + Telegram `/reload`
  commands): permanent by design (`:iex` is never a release dependency).
  Scoped by exact short-description text (not `{file, warning_type}`), so
  it won't swallow a future genuine `unknown_function` typo elsewhere in
  these large, actively-edited transport files.

Verified via `mix dialyzer --format dialyzer` with `list_unused_filters:
true` (already set in `mix.exs`): "Total errors: 1642, Skipped: 41,
Unnecessary Skips: 0" — all 18 entries matched at least one real warning
(41 total warnings suppressed; several entries match more than one
occurrence in their file), none are stale/unused.

## Phased plan to blocking

The dialyzer job is currently advisory (`continue-on-error: true` at the
job level in `.github/workflows/dialyzer.yml`). Recommended path to make
parts of it blocking, without a big-bang "fix everything or nothing":

**Phase 1 — config + mechanical fixes (small, bounded, do first):**
- Add `:nostrum` to `plt_add_apps` in root `mix.exs` `dialyzer/0`
  (kills 7-8 `unknown_function` warnings; config-only).
- Fix the 9 `unknown_type` stale-alias bugs (mechanical, one alias/type
  target per site).
- Fix the `x_api/client.ex:585` crash bug (small, `Map.get` instead of
  `List.keyfind`).
- Investigate and resolve the "line 1: pattern false can never match true"
  artifact class (macro/compiler-expansion attribution issue) enough to
  either fix it or add it to `.dialyzer_ignore.exs` with a confirmed root
  cause — don't ignore it blind.

**Phase 2 — architectural, needs app-owner buy-in:**
- `function_will_never_be_called`: sample across the ~37 affected files to
  confirm the dynamic-dispatch shape holds everywhere (not just the two
  files verified in this pass), then apply `@behaviour`/`@impl true`
  formalization where a shared contract already exists (best fix), or
  targeted `@dialyzer {:nowarn_function, ...}` per confirmed entry point
  (fallback).
- `pattern_covered_by_prior_clauses` / `pattern_cant_match_type` /
  `guard_never_succeed` / `no_local_return` / `invalid_contract` /
  `callback_spec_mismatch` (~614 combined, ~46% of all warnings once
  `function_will_never_be_called` is excluded): app-by-app spec-tightening
  pass. Start with `agent_core` and `coding_agent` — they're the largest
  offenders by count *and* the most widely depended-on apps, so fixing
  their specs improves Dialyzer's inference accuracy for every downstream
  caller too, not just locally.

**Phase 3 — policy decision on `unmatched_return` (440, largest category):**
Decide, as a team, whether to keep chasing `:unmatched_returns` to zero
(idiomatic-but-noisy) or drop the flag from root `mix.exs` `dialyzer/0`.
Either is defensible; what's not defensible is leaving it in a permanent
"1,599 warnings, ignore the number" state. Don't gate this category on CI
until that decision is made.

**Phase 4 — incremental blocking, not a single flip:**
Flipping `continue-on-error` off for the whole job only makes sense once
essentially everything above is done, which is a long way off. Instead,
recommend a small `mix lemon.dialyzer_gate` task (or shell script) that:
1. Runs `mix dialyzer --format dialyzer` (or reuses its output).
2. Buckets warnings by the categories in this doc (same regex
   classification used here).
3. Compares each category's count against a checked-in baseline (e.g.
   `docs/plans/dialyzer-baseline.json`) and fails **only if a gated
   category's count goes up** — a regression gate, not a zero gate.
4. Gate categories incrementally as each is cleaned up: `unknown_type` +
   `unknown_function` + `call_arg_mismatch` + `fun_app_mismatch` first
   (smallest, highest-signal, ~25 total once Phase 1 lands), then
   `function_will_never_be_called` once Phase 2's registry work lands,
   then the spec-mismatch cluster app-by-app as each app's specs are
   tightened, and finally `unmatched_return` once Phase 3's policy call is
   made.

This task (task #36) did not implement the `mix lemon.dialyzer_gate` task
or the baseline file — that's the concrete next step once Phase 1 starts.
