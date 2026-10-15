# `omp` tool

The `omp` tool lets Lemon's agent delegate coding work to
[omp](https://github.com/can1357/oh-my-pi) sessions and report on them. It is
contributed by the `lemon_omp` app through the agent tool registry and is
present even when omp is not installed (calls then return “omp is not
installed”). For the workflow, see [Delegating to omp](../user-guide/omp.md).

## Actions

| Action | Parameters | Result |
| --- | --- | --- |
| `models` | optional `query` (case-insensitive selector/name substring), `provider`, `free_only`, `limit` (default 30, max 200) | Cheapest-first catalog: selector, name, context window and input/output cost per million tokens or FREE. Pass a selector as `model` on start/start_many; prefer cheap/free models for simple tasks unless the user specified one. Prices are omp catalog data; OpenRouter `:free` routes may be withdrawn (404 “unavailable for free”), so be ready to fall back. |
| `start` | `prompt`; optional `cwd` (default: the conversation's cwd), `model`, `thinking`, `approval_mode`, `isolate` (boolean, default false), `wait` | Starts `omp --mode rpc` and returns once omp accepted the prompt. `isolate: true` creates a managed Git worktree/branch from HEAD; requires a Git cwd. With `wait: true`, blocks and streams progress until the turn ends, including pending approvals. |
| `start_many` | `tasks` (array of start maps); optional `cwd`, `isolate` (batch defaults, each task can override), `wait`, `timeout_seconds` | Validates all tasks before creating any worktrees, then starts workers concurrently. Returns ordered sessions and per-task errors. With `wait: true`, gathers all successful workers and streams combined progress. |
| `wait` | `id` or `ids` (array); optional `wait_for` (`all` default, `any`, for `ids`), `timeout_seconds` (default 600, max 3600) | Blocks until the current turn ends, or all/any selected workers settle, streaming progress. Timeout or a Lemon abort stops waiting only; omp keeps working. |
| `status` | `id` | What the session is doing now: status, activity, running/recent tools, todos, subagents, usage and cost, latest output or last result. |
| `subagent` | `id`, `subagent_id`; optional `limit` (default 20, max 50) | Sanitized transcript tail for an omp task child, while its parent process is open. Each message has role, text (max 2000 characters), and optional tool name; cursor metadata is retained. |
| `list` | – | Sessions this conversation started (live and recently ended). |
| `send` | `id`, `message`; optional `mode` (`steer` default, or `follow_up`) | Steers the running turn or queues a follow-up; an idle session starts a new turn with the message. |
| `cancel` | `id` | Aborts the running turn; the process stays open. |
| `close` | `id` | Ends the omp process; its session can be resumed. |
| `discover` | optional `cwd` | omp's stored sessions for the workspace (read-only). |
| `resume` | `omp_session_id` (id or unique prefix from `discover`); optional `prompt`, `cwd`, `model`, `thinking`, `approval_mode`, `wait` | Reopens a stored omp session as a new invocation. |

`id` is Lemon's invocation id (`omp_…`); `omp_session_id` is omp's own
session id.

`approval_mode` is `always-ask` (ask before writes and execution), `write`
(ask before execution), or `yolo` (auto-approve ordinary tool calls). It overrides
omp's mode for this invocation; omitting it preserves omp's configured mode.
omp's explicit per-tool policies still apply. Approval selects bridge to Lemon's
conversation approval prompts/channel buttons by default; operators can use
`exec.approval.resolve`. `LEMON_OMP_APPROVALS=decline` instead cancels them.
Other blocking UI dialogs remain declined.

`start_many` task directories default to the batch cwd or conversation cwd.
Workers sharing one cwd can conflict; set `isolate: true` to give each a fresh
managed worktree. A batch larger than the remaining capacity is rejected up front.
Concurrent callers may still win slots during admission; those failures are
reported per task. Partial startup failure is not a tool error unless every
task fails. “Outcome unknown” retains the invocation id for reconciliation.
Multi-worker reports include a line per worker and combined tokens/cost.
`wait_for` applies only to multi-worker waits; `mode` remains the send mode.

Isolated workers run in `<git common dir>/lemon-omp-worktrees/<id>` on branch
`lemon-omp/<id>`. Reports include the path and merge/cherry-pick instructions.
Closing removes only worktrees with no uncommitted changes and no new commits;
others remain available with `worktree.kept`, `dirty` and `commits` counts
(`null` if Git could not determine a count within the cleanup budget). Inspect
and commit uncommitted work before merging. Resume uses the supplied `cwd`;
to reuse kept work, pass its path without `isolate`. See
[Parallel workers](../user-guide/omp.md#parallel-workers).

## Scope and trust

- A conversation sees and controls only sessions it started; any other id is
  reported as not found.
- Results are marked untrusted: omp text is fenced as external data before it
  reaches the model and is never followed as instructions.
- Control is acknowledged only after omp accepts it and fails closed for a
  closed or crashed session. “Outcome unknown” means omp did not answer in
  time and the request may have taken effect; check `status` before retrying.

## Result details

Tool cards receive `details` of the form
`{"action": "...", "session": {...}}` (or `"sessions": [...]` for `list`,
`discover`, `start_many`, and multi-worker `wait`). Combined progress is
throttled to about one update per 300 ms, with a final update always sent.
Multi-worker results include combined `usage`; `start_many` also includes
`errors` with a zero-based task index and safe error message. The session
object is the same snapshot the control plane returns
from `omp.sessions.get`: `id`, `ompSessionId`, `title`, `cwd`, `model`,
`worktree` (null or `path`, `branch`, `base` short SHA, `repo` main checkout root;
after cleanup also `kept`, `dirty`, `commits`),
`thinking`, `approvalMode` (the requested override, or `null` for omp's own
configured mode), `status`, `lastTurn`, `activity`, `activeTools`, `recentTools`,
`todos`, `subagents`, `usage` (`input`, `output`, `cacheRead`, `cacheWrite`,
`totalTokens`, `cost`), `contextPercent`, `lastText`, `result`, `error`,
`declinedPrompts`, `pendingApprovals`, `approvals`, timestamps and `exit`.
All strings are bounded.

Each `subagents` entry retains the existing `id`, `agent`, `status`, `description`
and adds `index`, `parentToolCallId`, `activity` (current tool and intent),
`toolCalls`, `recentTools` (up to eight name/endedAt pairs), `usage`, `model`,
`startedAt`, `endedAt` (local Unix milliseconds), `durationMs` (omp's elapsed time),
`lastText` (latest output/result head, max 500 characters), and `error` (retry
state/failure when provided). There are at most 20 entries, keyed by child id rather
than task-local index. Status and wait progress include compact per-child lines.
Child `usage` contains only supplied `tokens`, `cost`, `contextTokens`,
`contextWindow`; `tokens` excludes cache reads and is not parent `totalTokens`.
Lemon uses omp's aggregated `progress` subscription, not raw `subagent_event`
streaming. General tool/assistant errors are not supplied at this level.

`subagent` results carry `details` with `action`, `id`, `subagentId`, and
`transcript` (`messages`, `fromByte`, `nextByte`, `reset`), not a session snapshot.
Only role/text/toolName are retained from messages; thinking and non-text content,
raw session entries and paths are omitted. Elixir callers can use
`LemonOmp.subagent(id, subagent_id, owner: scope, limit: 20)` with the same
ownership rules as `get/2`. omp errors become `{:rejected, message}`, closed
sessions return `:not_running`, and silence returns `:outcome_unknown` without
automatic retry. A completed child remains readable until its parent is closed,
provided omp still retains its transcript reference.

`pendingApprovals` lists `id` (Lemon's approval id), `tool`, sanitized `details`
(at most 2000 characters) and `requestedAt` (Unix milliseconds). Activity reads
`Waiting for approval: <tool>` while one is pending, and `wait` progress explains
where to resolve it. `approvals` counts `approved`, `denied` and `expired`
(timeouts/errors); abandoned dialogs are removed without counting a decision.
