# Delegating to omp

[omp](https://github.com/can1357/oh-my-pi) (oh-my-pi) is a separate coding
agent. Lemon can hand it work: start an omp session in a workspace, watch what
it is doing, steer or cancel it, and resume it later. You can drive this from
chat (“run this in omp”), from the TUI's `/omp` panel, or with `lemon omp`.

omp is a *delegate*, not Lemon's engine. Lemon's own conversations still run on
its native agent; omp runs as its own process with its own model, credentials,
settings and session history, and Lemon observes it through omp's structured
RPC protocol (`omp --mode rpc`).

## Requirements

- `omp` installed and on the `PATH` of the Lemon runtime (`which omp`), or
  `LEMON_OMP_BIN` pointing at it. Without it every surface says “omp is not
  installed” and nothing else changes.
- omp configured with a working model (its own `omp` setup, API keys in the
  environment, or `--model` per session). Lemon never passes its own provider
  credentials to omp.

`lemon omp status` (or `omp.status` in the control plane) reports whether omp
was found and its version.

## From chat

Ask in plain words; Lemon uses its `omp` tool:

> Run this in omp: add input validation to `lib/parser.ex` and its tests.

Lemon starts omp in the conversation's working directory and replies with the
session id (for example `omp_3f9a1c2b7d4e`). Then:

- “What's omp doing?” — Lemon reports the current activity, running tools,
  todo progress, token usage and cost, and the latest output.
- “What is its subagent doing?” — Lemon reports each task child's activity or
  result. “Show that subagent's transcript” reads a bounded message tail while
  the parent omp process is still open.
- “Wait for omp to finish” — Lemon blocks until the turn ends; the tool card
  streams progress while it waits.
- “Tell omp to skip the docs” — steers the running turn; “after that, also
  run the linter” queues a follow-up. A message to an idle session starts a
  new turn.
- “Stop that; instead, fix the parser” — redirects omp: aborts its current turn
  and starts over with the new message in one omp command. A wait already in
  progress follows the redirected turn, rather than ending at the aborted turn.
- “Move that worker to a cheaper model” — uses `models` and `configure` to
  change its model and/or thinking level without restarting it.
- “Cancel the omp run” — aborts the current turn; the session stays open.
- “Close it” — ends the omp process. Its history stays on disk.
- “Which omp sessions exist here?” / “resume the last one” — lists omp's stored
  sessions for the workspace and reopens one.

A conversation can only see and control the omp sessions it started. Sessions
you start from the TUI or CLI are operator sessions; manage those from the TUI
or CLI.

For `start` or `resume`, the agent tool (and `LemonOmp.start/2`) accepts
`approval_mode`: `always-ask` asks before writes and execution, `write` asks
before execution, and `yolo` auto-approves ordinary tool calls. Omitting it
leaves omp's own configured mode unchanged. Explicit omp tool policies still
apply. Lemon passes an explicit mode as `--approval-mode <mode>`.

### Continuing after a crash

For an interrupted session, explicitly request
`{"action":"resume","omp_session_id":"…","continue":true,"wait":true}`.
Elixir callers use `LemonOmp.start(%{cwd: cwd, resume: omp_id, continue: true})`.
`continue` is boolean, requires a resume id, and cannot accompany a prompt.
It reopens history with `--resume` and sends a fixed instruction to review the
conversation/workspace and finish unfinished work without redoing completed
steps. This is a new model turn, not replay of the interrupted OS command.
Nothing resumes automatically.

omp 18.11's `--restore` is **interactive-only**, rejects RPC mode and prompts,
and therefore cannot provide its interrupted-turn/subagent restoration here.
Lemon's explicit continuation does not revive subagents. Discovery's
`interrupted` hint identifies an unfinished last turn in the bounded file tail;
it is not proof of a crash (a live session can also have an unfinished turn).

## Choosing a model

Ask Lemon to list omp models (`{"action":"models","free_only":true}`), then
pass a returned `selector` as `model` on `start` or a `start_many` task.
For simple mechanical work, prefer cheap/free models unless you specified one.
Operators using Elixir can call `LemonOmp.models(free_only: true, limit: 30)`.
The catalog supports case-insensitive `query` (selector/name), `provider`,
`free_only`, and `limit` (default 30, maximum 200), sorted cheapest first.
It runs `omp models --json` with a 20-second timeout and caches results for ten
minutes per executable/mtime. Displayed costs are per million tokens.

Prices are omp's catalog data, not a guarantee: OpenRouter `:free` routes can
be withdrawn upstream; several have returned 404 “unavailable for free”.
Be ready to select a fallback. Listing models does not make a model call.

### Switching a live worker

Use `models` to choose a cheaper selector, then configure the existing worker:

```json
{"action":"configure","id":"omp_3f9a1c2b7d4e","model":"openrouter/nvidia/nemotron-3-super-120b-a12b:free","thinking":"low"}
```

Supply `model`, `thinking`, or both. `model` must be a full `provider/id`
selector, not a fuzzy name; model ids may contain further `/` characters.
Thinking levels are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`,
or `auto`. omp may clamp the level for the chosen model; the result reports
omp's actual model and effective thinking level, not just the requested values.

Switching is allowed while idle **or running**. It does not restart the
process or abort the current turn: the new settings apply from the next model
call, including later calls in the same turn. An already in-flight model call
is not restarted. A model switch may also change the effective thinking level;
if both are supplied, Lemon sets the model first and thinking second.

Elixir callers use
`LemonOmp.configure(id, %{model: selector, thinking: "low"}, owner: scope)`.
Success is `{:ok, refreshed_snapshot}` after correlated command success and
`get_state`. An omp rejection is `{:error, {:rejected, message}}`; silence is
`{:error, :outcome_unknown}`. If an acknowledged change precedes a later failure,
the error is
`{:error, {:partially_applied, applied_fields, failed_step, reason}}`, where
fields are strings such as `["model"]`, and the failed step is `"thinking"`
or `"snapshot"` (refresh). Earlier changes are not rolled back. Neither
mutations nor unknown outcomes are retried automatically.

Only live sessions can be configured, with the same ownership rules as sending
a message. This is available through the chat tool, Elixir API, control-plane
`omp.sessions.configure`, and CLI `lemon omp configure`.

## Parallel workers

Ask Lemon to split independent work across several omp workers. The `omp`
tool's `start_many` action accepts a `tasks` array; each task has a `prompt`
and optional `cwd`, `model`, `thinking`, `approval_mode`, and boolean `isolate`.
Omitted directories default to the conversation's cwd. Set `isolate: true`
to give each worker its own managed Git worktree instead of editing shared files.

```json
{
  "action": "start_many",
  "isolate": true,
  "tasks": [
    {"prompt": "Implement the parser", "cwd": "/src/app"},
    {"prompt": "Document the API", "cwd": "/src/app"}
  ],
  "wait": true
}
```

Starts run concurrently and return in task order. All task parameters are
validated before any process starts, and batches larger than the remaining
live-session capacity are rejected up front. Admission is still enforced for
each start if another caller uses a slot concurrently. Individual startup
failures are reported per task; successful workers keep running. An
“outcome unknown” error includes the session id: check it before retrying.

With `wait: true`, Lemon gathers all successful workers and streams combined
progress, including token usage and cost. To gather workers later, use
`{"action":"wait","ids":["omp_…","omp_…"],"wait_for":"all"}`.
Set `wait_for` to `"any"` to return when the first worker settles. Timeout
or abort stops only the wait, never the workers; cancel or close them
explicitly when no longer needed.

`isolate` is available on `start`, on each batch task (overriding the tool's
batch default), and in the Elixir facade's start/task maps. `cwd` must be inside
a Git work tree with a HEAD commit. Each isolated worker gets a fresh
`lemon-omp/<invocation id>` branch from that checkout's current HEAD, and runs
at the root of a worktree under
`<git common dir>/lemon-omp-worktrees/<invocation id>`. Lemon derives this path;
callers cannot supply it. Keeping it in Git's common directory avoids main
checkout status noise and temporary-directory cleanup. Uncommitted changes in
the original checkout are **not** copied to workers.

Snapshots include `worktree` (`path`, `branch`, `base`, `repo`), and reports
explain how to integrate the work. Inspect the worker directory first: omp may
leave changes uncommitted. Commit those changes there, then run
`git merge lemon-omp/<invocation id>` in the main checkout (or cherry-pick the
desired commits). Resolve conflicts normally; isolation does not merge for you.

On close, idle timeout, process exit or Session crash, Lemon removes a worktree
and its branch only if there are no uncommitted changes and no commits beyond
its base. Otherwise it keeps both and reports `kept: true`, `dirty`
(changed/untracked paths) and `commits` (commits beyond base). Cleanup is bounded;
if Git cannot establish safety, it keeps the work and unknown counts are `null`.
It never force-removes dirty worktrees. Only Lemon-created worktrees are eligible
for automatic cleanup. Remove kept work manually with `git worktree remove <path>`
and `git branch -d <branch>` once integrated.

Resume from the main checkout or any worktree in the same repository: Lemon
finds the stored session's recorded cwd and automatically reuses an existing,
registered Lemon worktree. Its snapshot carries `worktree` metadata again, so
the same conservative cleanup applies on close. Discovery includes these kept
workers and their branch names. No arbitrary session-header path is trusted:
the directory must be directly under this repository's managed worktree root
and registered with Git on its matching `lemon-omp/…` branch.

If the worktree was deleted or cannot be validated, resume uses the supplied
`cwd` instead; the agent tool reports this fallback. `isolate: true` still
explicitly creates a fresh worktree rather than reusing one. Discovery checks
at most 32 managed worktrees and 2,000 filenames per candidate session directory,
reading bounded headers/tails until the requested number of matching sessions is found.
If the original branch creation reflog is unavailable, the resumed snapshot's
base is `null` and cleanup keeps the worktree rather than guessing its base.


Elixir callers can use `LemonOmp.start_many(tasks, owner: owner)` and
`LemonOmp.wait_many(ids, timeout_ms, owner: scope, mode: :all)`. The latter
uses one Bus subscription and reports the full ordered snapshot list through
`on_update` at most about every 300 ms, plus an unconditional final update.
Ownership restrictions are identical to single-session access.

## Control-plane API

Authenticated operators can use these methods (parameters use camelCase):

| Method | Scope | Parameters / result |
| --- | --- | --- |
| `omp.sessions.start` | write | `cwd`, `prompt`; optional `model`, `thinking`, `approvalMode`, `isolate`. Returns `{session}`. |
| `omp.sessions.resume` | write | `cwd`, `ompSessionId`; optional `prompt`, `model`, `thinking`, `approvalMode`, `continue`. `continue: true` cannot accompany a prompt. Returns `{session}`. |
| `omp.sessions.startMany` | write | `tasks` (1–8 start maps), optional batch-default `isolate`. Returns ordered `{results: [{index, session} \| {index, error}]}`. Each task requires its own `cwd` and `prompt`; task isolation overrides the batch default. |
| `omp.models` | read | Optional `query`, `provider`, `freeOnly`, `limit` (1–200). Returns `{models}` cheapest first. |
| `omp.sessions.subagent` | read | `id`, `subagentId`, optional `limit` (1–50). Returns `{id, subagentId, transcript}` with sanitized messages and byte cursors. |
| `omp.sessions.configure` | write | `id`, at least one of `model`, `thinking`. Returns `{session}`. |
| `omp.sessions.send` | write | `id`, `message`, optional `mode`: `steer` (default), `followUp`, or `redirect`. Returns `{accepted: true, delivery}`; idle delivery is `prompt`. |

These methods dispatch asynchronously so approvals and `omp.session` events keep
flowing. Existing list/get/discover methods remain read-only. Discovery includes
`source`, `interrupted`, and worktree path/branch when present; snapshots and event
payloads retain the driver's approval, worktree and subagent details unchanged.
Prompts and messages are limited to 16 KiB, paths to 4096 bytes, and model selectors
to 128 bytes. Approval modes are `always-ask`, `write`, and `yolo`; thinking levels
are `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, and `auto`.

Errors carry a public `details.code`: `OMP_NOT_A_GIT_REPO` identifies `cwd`,
`OMP_WORKTREE_FAILED` and `OMP_CATALOG_FAILED` report unavailable operations,
and `OMP_INVALID_TASK` includes the zero-based failing task `index`. Whole-batch
validation finishes before workers start. Per-task errors retain their public
code and any uncertain invocation `id`. `OMP_PARTIALLY_APPLIED` includes `applied`,
`failedStep`, and `retrySafe: false`; earlier configuration changes are not rolled
back. Outcome-unknown errors also carry `retrySafe: false`: reconcile rather than
automatically retrying.

## From Lemon Web

Open `/omp` to start, inspect, resume and control delegate sessions. New sessions
offer an approval-mode override and **Isolate** (a managed Git worktree).
Leave approval mode at **omp default** to preserve omp's configured policy.
Session details show the mode, approval counters and pending tool approvals:
**Approve** approves that request once; **Deny** refuses it.

Use **Steer** for guidance, **Follow-up** to queue work, or **Redirect** to abort
the current turn and start the replacement message. Receipts report the actual
delivery returned by omp; an idle session can receive the message as a prompt.
An unconfirmed mutation is never retried automatically.

Resume discovery marks Lemon/omp sources, interrupted sessions and isolated
branches. For interrupted sessions, leave the message empty to offer **Continue
interrupted work**; this starts a new continuation turn, not an OS-command replay.
Resume can also override approval mode. Isolated-session details show the path,
branch, base and cleanup state, with a `git merge <branch>` hint. Inspect and
commit any worker changes before merging; Web does not merge automatically.
Delegate output is escaped plain text, never executable HTML.

For parallel work, enable **Start parallel workers** in New session and separate
one to eight prompts with blank lines. Workspace, model, thinking, approval mode
and isolation apply to every task. Ordered task receipts retain individual errors;
the worker grid follows live session events and combines token usage and cost.
An invalid-batch error identifies the zero-based task index; uncertain starts are
never replayed automatically.

**Browse omp models** searches the daemon's omp catalog, with a free-only filter,
FREE badges and input/output prices per million tokens. Choose a model for a new
session or open **Configure model / thinking** on a live session. Either setting
may be changed independently. Partial configuration explicitly lists applied
steps and the failed step: applied changes are not rolled back or retried.

Subagent rows include activity, tool calls and usage. **Transcript tail** loads
up to 50 messages as bounded escaped plain text, without exposing transcript paths.

## From the TUI

Agent `omp` tool cards show parallel starts and multi-worker waits as compact
worker rows with status, activity or result preview, todo progress, combined
tokens/cost and individual task errors. Session cards highlight pending tool
approvals and show isolated worktree branch/kept/dirty state and child activity.
Model catalog cards show context size and prices (or FREE); subagent reads show a
bounded transcript tail. Configuration and discovery receipts show the resulting
session and the discovery source/interrupted state. All delegate text is inert,
sanitized plain text; cards intentionally bound long output.

`/omp` (Alt+M, also in the command palette) opens the omp panel: live and
recent sessions with status, workspace, model, current activity, elapsed time
and tokens/cost. Select a session for its detail view — activity, running and
recent tools, todos, subagents, usage, latest output or result. Keys:

| Key | Action |
| --- | --- |
| Enter | open the detail view / back |
| `s` / `f` | steer the running turn / queue a follow-up |
| `R` | redirect: stop the current turn and start with a new message |
| `m` | choose an omp model (`[free]` marks free models) and configure the selected session |
| `[` / `]`, `a` / `n` | select a pending approval, then approve once / deny by its server ID |
| `{` / `}`, `v` | select a subagent, then inspect its bounded transcript tail |
| `c` | cancel the running turn |
| `x` | close the omp process |
| `d` | discover stored sessions, showing source and interrupted state; Enter resumes, `C` resumes an interrupted session with continue |
| `r` | refresh |
| Esc | close the panel |

Detail includes approval mode and counters, pending requests, and isolated
worktree path/branch, retained/dirty state, commit count and a merge hint.
Configuration failures report any partially applied settings explicitly; refresh
before deciding whether to change them again. Model selection and child transcripts
stay in the panel; Escape returns without changing the editor draft.

`/omp run [--approval-mode always-ask|write|yolo] [--isolate] <prompt>` starts a session in the TUI's working directory, and
`/omp status` prints a one-line summary of live sessions. The panel and the
status-bar badge (`omp N▶` while sessions run) update live from the runtime's
`omp.session` events. When Lemon's agent uses the `omp` tool, its card shows
the session's status, activity, todo progress and usage as they change.


## From the CLI

```bash
lemon omp status
lemon omp start --cwd ~/src/app "Add input validation to lib/parser.ex"
lemon omp start --cwd ~/src/app --approval-mode write --isolate "Fix the parser"
lemon omp start-many --cwd ~/src/app --isolate --task "Fix parser" --task "Document API"
lemon omp models --free --provider openrouter --limit 30
lemon omp configure omp_3f9a1c2b7d4e --model provider/model --thinking low
lemon omp subagent omp_3f9a1c2b7d4e CHILD-ID --limit 20
lemon omp list [--all]
lemon omp show omp_3f9a1c2b7d4e
lemon omp watch omp_3f9a1c2b7d4e
lemon omp send omp_3f9a1c2b7d4e "Skip the docs"
lemon omp send --follow-up omp_3f9a1c2b7d4e "Then run the linter"
lemon omp send --redirect omp_3f9a1c2b7d4e "Stop that; fix the parser instead"
lemon omp cancel omp_3f9a1c2b7d4e
lemon omp close omp_3f9a1c2b7d4e
lemon omp discover --cwd ~/src/app
lemon omp resume 01a137e9-baf8 --cwd ~/src/app "Continue with the tests"
lemon omp resume 01a137e9-baf8 --cwd ~/src/app --continue --approval-mode write
```

These talk to the running Lemon runtime; see [CLI](cli.md) for every option.

`--approval-mode` accepts `always-ask`, `write`, or `yolo`; omission preserves
omp's mode. `--continue` cannot accompany a prompt and does not restore
subagents. `start-many` accepts 1–8 repeated `--task` prompts; all use the shared
`--cwd`, `--model`, `--thinking`, `--approval-mode` and `--isolate` options.
It prints one indexed id/status or error code/message per task.

`models [query]` supports `--free`, `--provider` and `--limit` (max 200), and
prints context and prices per million tokens or FREE. `subagent` reads a
transcript tail with `--limit` up to 50. `configure` requires `--model` and/or
`--thinking` and prints effective settings. A partially-applied error says
which settings were acknowledged and which step failed; earlier changes
remain applied, without rollback or automatic retry.

`discover` shows the history source and marks interrupted turns (a hint, not
proof of a crash). `list` hides ended sessions unless `--all` is given. `watch`
follows one session's status changes until it is idle, closed or failed;
Ctrl-C stops watching and never cancels the turn. `show` includes approval mode
and pending approval ids, worktree path/branch and kept/dirty/commit state, and
subagent activity.
Resolve approvals through the TUI or control-plane `exec.approval.resolve`;
there is no CLI approval resolver. `send --redirect` and `--follow-up` are
mutually exclusive.

## What Lemon reports

For each session Lemon keeps a bounded snapshot: status (`starting`,
`running`, `idle`, `closed`, `failed`), the outcome of the last turn
(`completed`, `error`, `aborted`), current activity, active and recent tools,
todos, subagents, token usage and cost (omp's own totals), context use, pending
approvals and approval outcome counters, the latest assistant text and the last
turn's result. While approval is pending the activity says “Waiting for approval:
&lt;tool&gt;”. Text is clipped and stripped of control sequences. Ended sessions
stay listed until the runtime restarts.

### omp task subagents

These are children spawned by omp's own `task` tool, not Lemon's parallel
`start_many` workers. Lemon subscribes at omp's `progress` level: at most 20
children appear, each with its id, agent, status, description, current tool and
intent, tool-call count, available tokens/cost, model, elapsed duration, local
start/end timestamps, latest output head (500 characters), and retry errors
when supplied. Recent tool names are limited to eight. Children keep their final
summary after completion; task calls that reuse an index remain distinct by id.
Status reports and streamed tool progress text include a compact line per child.

Ask Lemon to use `{"action":"subagent","id":"omp_…","subagent_id":"…"}` to
read a child's transcript. Optional `limit` defaults to 20 messages and is capped
at 50; each message exposes only role, text (at most 2000 characters), and an
optional tool name. Thinking blocks, raw events, tool arguments, and session-file
paths are not exposed. Like all omp output, transcripts are sanitized, bounded,
and untrusted.

Elixir callers use `LemonOmp.subagent(id, subagent_id, owner: scope, limit: 20)`.
It returns `{:ok, %{"messages" => [...], "fromByte" => ..., "nextByte" => ...,
"reset" => ...}}`, retaining omp's cursor metadata. Ownership is identical to
`get/2`: foreign sessions read as not found; operator calls default to `:any`.
Unknown/unavailable children are rejected by omp; a closed parent returns
`:not_running` and a command timeout returns `:outcome_unknown` without retrying.

Progress is aggregate data: omp's `tokens` counts lifetime input, output and cache
writes, **excluding cache reads**, rather than parent-session `totalTokens`.
Optional values remain absent/null when omp does not provide them. At this
subscription level omp supplies retry state/failure errors, not every raw assistant or
tool error; use the transcript for more context. Lemon does not subscribe to the
higher-volume `events` level (raw per-child session events).

### Discovery

Discovery reads both Lemon's history and omp's own session files for a workspace
without writing, locking or migrating them. Each entry includes `source`
(`"lemon"` or `"omp"`), omp's session id, title, model, last outcome, whether
Lemon currently runs it, and whether it was written to in the last two minutes
without a clean exit (probably open in another omp). The agent tool text and
structured discovery results include source; the CLI/TUI discovery tables do
not yet display that field.

### Where omp history lives

New Lemon-run sessions live in `~/.lemon/omp/sessions` by default (more precisely,
`omp/sessions` under `LemonCore.Paths.home_state_dir()`). Lemon passes this
directory as `--session-dir`, creates it with private `0700` permissions before
starting omp, and leaves interactive omp history alone. omp 18.11 uses an
explicit session directory **flat**, without encoded per-cwd subdirectories;
Lemon filters each file's header cwd when discovering a workspace.

Set `LEMON_OMP_SESSION_DIR` (or `config :lemon_omp, :session_dir`) to a custom
path; `~` and relative paths are expanded to an absolute path. The environment
overrides app config. Set it to **`omp`** to opt out: new sessions omit the
`--session-dir` flag and use omp's own default layout under
`~/.omp/agent/sessions`, or `$PI_CODING_AGENT_DIR/sessions`
(`PI_CONFIG_DIR` changes `.omp`). Empty or invalid values fall back to valid
app config, then Lemon's private default; an empty value is not the opt-out.

Older Lemon sessions and interactive omp sessions stay discoverable from omp's
default directory alongside Lemon's history. Resume resolves an id or unique
case-insensitive prefix across both sources, then passes the actual containing
directory to omp; it continues the original file **in place**, never moves,
copies or migrates history. Exact ids take precedence over longer prefix matches;
ambiguous matches are rejected before spawning. Lookup is bounded like discovery,
but filters by id before applying the result limit. If no match is found,
omp searches the configured new-session directory (or its own default on opt-out).
Changing the custom directory does not search previous custom directories.

## Safety and lifecycle

- **omp output is untrusted.** Everything quoted from omp — its replies,
  errors, todo text — reaches Lemon's model fenced as external data, never as
  instructions.
- **Approvals bridge.** omp's tool approval prompts appear in the owning
  conversation's Lemon approval prompts and channel buttons (Telegram/Discord),
  including native coding-session approval UI when the session identity is
  available. Operators can resolve them with `exec.approval.resolve` using the
  approval id in the snapshot's `pendingApprovals`. Session-scoped grants for
  operator sessions apply only to that omp session, never another invocation.
  The session stays responsive while it waits. Approve/deny decisions return to
  omp; expiry cancels the prompt. Cancelling an omp dialog or closing/exiting its
  session removes the corresponding Lemon approval too.
  `LEMON_OMP_APPROVALS=decline` restores headless cancellation of tool approvals.
  Other blocking dialogs (confirm, input, editor, unrelated selects) are still
  declined and counted in `declinedPrompts`.
- **Control fails closed.** Steering, follow-ups, redirects and cancellation go
  to one process invocation and are acknowledged only after omp accepts them. A
  closed or crashed session refuses them; resume it to continue (resuming is a
  new invocation with a new id). If omp does not answer in time the result is
  “outcome unknown” — check the status before retrying, because the request
  may already have taken effect.
- **No orphans.** omp exits when its input closes, aborting the running turn
  and its shell commands. Lemon holds that input, so stopping, crashing or
  killing the Lemon runtime ends every omp it started; on a normal stop Lemon
  also escalates to SIGTERM and SIGKILL if omp lingers.
- **Bounded.** At most `LEMON_OMP_MAX_SESSIONS` (default 4) live omp
  processes; an idle process closes after `LEMON_OMP_IDLE_TIMEOUT_MS`
  (default 30 minutes, `0` disables) and stays resumable. Lemon's own
  `LEMON_*` environment variables (including control-plane tokens) are removed
  from omp's environment.

## Settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `LEMON_OMP_BIN` | first `omp` on `PATH` | omp executable |
| `LEMON_OMP_SESSION_DIR` | `<Lemon state dir>/omp/sessions` (normally `~/.lemon/omp/sessions`) | private flat history directory; `omp` uses omp's own default for new sessions |
| `LEMON_OMP_MAX_SESSIONS` | `4` | live omp processes |
| `LEMON_OMP_IDLE_TIMEOUT_MS` | `1800000` | close idle processes (0 = never) |
| `LEMON_OMP_APPROVALS` | `bridge` | route omp tool approvals to Lemon; `decline` cancels them |
| `LEMON_OMP_APPROVAL_TIMEOUT_MS` | `600000` | maximum approval wait in ms, capped by omp's dialog timeout |
| `PI_CODING_AGENT_DIR` / `PI_CONFIG_DIR` | omp's defaults | omp's credentials/settings and original history source; also the new-session history on opt-out |

See also the [`omp` tool reference](../tools/omp.md).
