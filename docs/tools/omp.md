# `omp` tool

The `omp` tool lets Lemon's agent delegate coding work to
[omp](https://github.com/can1357/oh-my-pi) sessions and report on them. It is
contributed by the `lemon_omp` app through the agent tool registry and is
present even when omp is not installed (calls then return “omp is not
installed”). For the workflow, see [Delegating to omp](../user-guide/omp.md).

## Actions

| Action | Parameters | Result |
| --- | --- | --- |
| `start` | `prompt`; optional `cwd` (default: the conversation's cwd), `model`, `thinking`, `approval_mode`, `wait` | Starts `omp --mode rpc` in `cwd` and returns once omp accepted the prompt. With `wait: true`, blocks and streams progress until the turn ends, including pending approvals. |
| `wait` | `id`; optional `timeout_seconds` (default 600, max 3600) | Blocks until the current turn ends, streaming progress. Returns a status report. Timeout or a Lemon abort stops waiting only; omp keeps working. |
| `status` | `id` | What the session is doing now: status, activity, running/recent tools, todos, subagents, usage and cost, latest output or last result. |
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
`{"action": "...", "session": {...}}` (or `"sessions": [...]` for `list` and
`discover`). The session object is the same snapshot the control plane returns
from `omp.sessions.get`: `id`, `ompSessionId`, `title`, `cwd`, `model`,
`thinking`, `approvalMode` (the requested override, or `null` for omp's own
configured mode), `status`, `lastTurn`, `activity`, `activeTools`, `recentTools`,
`todos`, `subagents`, `usage` (`input`, `output`, `cacheRead`, `cacheWrite`,
`totalTokens`, `cost`), `contextPercent`, `lastText`, `result`, `error`,
`declinedPrompts`, `pendingApprovals`, `approvals`, timestamps and `exit`.
All strings are bounded.

`pendingApprovals` lists `id` (Lemon's approval id), `tool`, sanitized `details`
(at most 2000 characters) and `requestedAt` (Unix milliseconds). Activity reads
`Waiting for approval: <tool>` while one is pending, and `wait` progress explains
where to resolve it. `approvals` counts `approved`, `denied` and `expired`
(timeouts/errors); abandoned dialogs are removed without counting a decision.
