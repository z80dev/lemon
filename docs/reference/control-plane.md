# Control-plane system methods

Connect to the authenticated `/ws` endpoint and discover supported methods in
`hello-ok.features.methods`. See the [control-plane guide](../../apps/lemon_control_plane/README.md)
for framing, authentication and the domain-specific method reference.

## HTTP and protocol errors

Non-`/v1` HTTP failures use `{"error":{"code":"UNAUTHORIZED","message":"..."}}`,
with the same string codes as WebSocket error frames. ACP HTTP authentication
failures use this HTTP envelope; authenticated ACP method replies retain JSON-RPC
framing and numeric method-error codes. Local or explicitly enabled `/v1/*`
retains OpenAI-compatible errors (`error.message` and `error.type`); remote
hidden routes use the generic 404 envelope. `/healthz` remains `{"ok":true}`.

HTTP authentication errors name `Authorization: Bearer <token>` and the server's
token configuration: `LEMON_ACP_API_TOKEN` for `/acp`,
`LEMON_OPENAI_COMPAT_API_TOKEN` for `/v1/*` (both also accept `x-api-key`), and
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` for `/acp/ws`. Managed launchers store the
operator token at `~/.lemon/run/control-plane-<port>.token`. Native `/ws` clients
send that token in `connect.params.auth.token`, not an HTTP header.
OpenAI/ACP HTTP authentication falls back to that operator token when its
dedicated token is unset; both APIs require authentication by default.
Off-loopback main peers see only `/ws` and `/healthz` unless the corresponding
HTTP API is explicitly enabled with a dedicated token. See
[listener exposure](../config.md#listener-exposure-breaking-default-change).
The separate node gateway on `127.0.0.1:4044` is the forwarding target for remote
nodes: only node/enrollment `/ws` and `/healthz`, never operators.
Error `details` are optional JSON context; unsupported runtime terms are omitted,
never inspected into wire responses, so the original code and message survive.

## `setup.status`

Scope: `operator.read`. Parameters: `{}`. Wraps `LemonCore.Setup.Readiness`
without network calls or configuration changes. No caller-supplied config path
is accepted.

```json
{
  "ready": false,
  "pendingSteps": [
    {"id": "provider", "label": "Choose a default provider and model with usable credentials", "command": "lemon setup provider"}
  ]
}
```

`pendingSteps` is ordered: `config`, `secrets`, `provider`, omitting complete
steps. Configuration and secrets steps use `lemon setup`; the provider step uses
`lemon setup provider`. Ready responses have `ready: true` and an empty list.
Keyless local providers and environment-only credentials follow the shared
readiness rules. This is local readiness, not proof of provider connectivity.
The projection contains only the boolean and fixed step ids, labels and commands:
no paths, provider/model names, secret references, credentials or diagnostic text.
Clients should omit setup guidance silently when this optional method is absent.

## `runs.timeline.get`

Scope: `operator.read` (like `runs.recent.list`). Parameters:
`{"runId":"run_..."}`; the nonempty ID is limited to 256 bytes.

Returns `{"runId":"...","entries":[...],"truncated":false,"usage":{...}}`.
Each entry has `atMs`, `kind`, `label`, nullable `durationMs`, nullable `ok`, and
`status`. Entries are chronological; times are wall-clock milliseconds.
Lifecycle kinds retain the introspection names: `run_started`,
`agent_loop_started`, `agent_turn_observed`, `agent_loop_ended`,
`answer_finalize_started`, `answer_finalize_completed`, `run_completed`, and
`run_failed`. A failed run has status `crashed`; completed outcomes distinguish
`completed`, `aborted`, and `error`.

`tool_call` entries pair dispatch/completion by tool-call ID and sit at dispatch
time, with the completion's duration and outcome. Unmatched dispatches are
`pending` with null outcome/duration; a retained completion without its dispatch
is still shown at completion time. `subagent` entries come from the task store
used by `tasks.recent.list`, including queued/running children whose exact
`parentRunId` matches. Labels contain only lifecycle names, tool names or child
task IDs, never arguments, results, descriptions, prompts or exception text.
New tool completions persist content-free metadata and a bounded redacted error
classification; historical dispatches without completions remain pending.

The query examines the newest 1,000 introspection rows for the run and returns
the latest 500 projected entries in chronological order. `truncated` is true if
either bound is reached/exceeded (the 1,000-row source bound is conservative).
Introspection retention also applies. `usage` reuses the recent-runs bounded
ledger join: `tokens`, `costUsd`, `priceKnown`, `model`, and `provider` are nullable;
missing start times/records or an overflowing 500-occurrence window never invent
zero or partial totals. Mixed model/provider values are null.

An unknown or expired run returns `NOT_FOUND`, not a successful empty timeline.
Introspection, task lookup or usage storage failures return `INTERNAL_ERROR`
with “Run timeline is unavailable”, never an empty result. No provider is called.

## Content scope (`operator.content`)

`operator.read` is metadata-only. Transcript and content payloads need
`operator.content`: prompts, answers, reasoning, task descriptions/results/
errors, tool titles and arguments, event previews, raw events, run records,
cron output/meta and prompt/command text, background answers, session exports
and log messages. The configured operator token, the tokenless loopback
operator and in-process operator clients (web UI, CLI, TUI, ACP) receive it by
default; a connection that sends an explicit `scopes` list receives it only if
the list names `operator.content` (or `content`). ACP upgrades require it.

Without it the methods below return metadata only (ids, roles, status, counts,
sizes, token usage and timings), ignore include flags that would add content
(`includeFullText`, `includeRawEvents`, `includeRunRecord`, `includeEvents`,
`includeRecord`, `includeOutput`, `includeMeta`, `includeIntrospection`,
`includeTargetText`, `includeAnswer`) and report `contentWithheld: true`:

| Method | Read-only response |
|---|---|
| `tasks.active.list`, `tasks.recent.list` | No `description`, `result`, `error`, `latestReasoning`, `events` or `record`. |
| `session.detail` | Runs keep `ok`, `hasError`, counts, `tokens`; tool calls keep `kind`/`ok`/`phase`; event digests have no `preview`; no prompt, answer, error, raw maps, events or run record. |
| `cron.runs` | No `output`, `outputPreview`, `error`, `meta`, `runRecord` or `introspection`; byte counts remain. |
| `cron.list` | No `prompt`, `command` or `meta`; byte counts remain. |
| `chat.history` | Rows keep `id`, `role`, `timestampMs`, `ok`, `toolCallId`, `toolName`, `phase`, `cancelled`, `durationMs`. |
| `sessions.snapshot` | Same row fields for messages/actions; `answer.text`, child `answer`, todo `content` and plan `content` are null/absent. |
| `sessions.history` | Runs keep `run_id`, `started_at_ms`, `engine`, `ok`, `duration_ms`, `event_count`, `tool_count`. |
| `sessions.export` | No `content` or `sha256`; format, filename, bytes and run counts remain. |
| `agent.wait` | No `answer` or `error`; `summary.hasError`/`errorKind` remain. |
| `background.result` | No `answer`; `ready` and `answerBytes` remain. |
| `logs.tail` | Entries keep `level`, timestamp and `module`; no `message`. |
| `sessions.preview` | Rows keep `runId`, `ok`, `timestampMs`, `promptBytes`, `answerBytes`; no `prompt`, `answer` or `truncated`. |
| `sessions.list`, `sessions.stats` | A non-blank `query` (it matches prompt/answer text) is refused with `FORBIDDEN`; unfiltered results are unchanged. |
| `sessions.tree` | Entries keep ids, `type`, `role`, `timestamp`, flags and `textBytes`; no `text` or `label`. |
| `sessions.steer.pending` | Items keep `messageId`, `acceptedAfterTurn`, `previewBytes`; no `preview`. |
| `sessions.changes` | With `path`, `diff` has no `patch`; `patchBytes`, status and counts remain. |
| `subagents.list` | No `description` or `activity`. |
| `subagents.transcript` | No `text`; `status`, `truncated` and `textBytes` remain. |
| `runs.recent.list` | Free-text `error` becomes `"error_text_withheld"`; atom reasons remain. |
| `cron.audit` | Free-text `reason` is null; enumerated reasons remain. |
| `process.jobs.list`, `process.jobs.inspect` | No `command` or `output`; `commandBytes`, `outputBytes`, status, timing, `cwd` and `pids` remain. |
| `omp.sessions.list`, `omp.sessions.get` | Ids, `cwd`, `worktree`, model/thinking/approval mode, `status`, `lastTurn`, timestamps, counters, `usage`, `contextPercent`, tool ids/names/timings, todo `status` and subagent ids/status/usage remain; no `title`, `activity`, `lastText`, `result`, `error`, tool `intent`, todo text, subagent `description`/`activity`/`lastText`/`error`, approval `details` or `exit.reason`; `get` returns `summary: null`. |
| `omp.sessions.subagent` | Transcript messages keep `role` and `toolName`; no `text`; byte cursors remain. |
| `omp.sessions.discover` | No `title`; ids, `cwd`, timestamps, `model`, `lastStatus`, `interrupted`, `activeElsewhere` and `liveId` remain. |
| `memory.list`, `memory.get` | Items keep `id`, `kind`, `source`, timestamps and `textBytes`; no `text`; `memory.list` ignores `query`. |
| `memory.search` | Not run; returns empty `items`. |
| `agent.identity.list` | No `label`; `query` matches only `id`/`name`. |
| `agent.message.get` | No `response`; ids and `status` remain. |
| `agent.directory.list`, `agents.list` | Agents have no `description`; session identity (`peerLabel`, `topicName`, keys, counts) remains. |
| `learning.timeline` | Items keep `at`, `kind`, `action`, `id`; no `title` or `preview`. |
| `profiles.list`, `profiles.get` | Profiles keep ids, name, avatar, model, node, working directory, MCP servers (never headers), tool policy, status, timestamps, paths and MCP fingerprint; no `systemPrompt` or `description`. |
| `profiles.roster` | Entries have no `description`. |
| `nodes.list` | Pending pairings omit the verification `code` unless the caller holds `operator.pairing`. |
| `mcp.servers.list` | Without `operator.admin`, `projectTrust` servers keep `name`, `provider`, `transport` and `enabled` only: no command/URL `preview` (it carries every configured argument and URL paths); `previewsWithheld: true`. |
| `doctor.run` | Without `operator.admin`, checks keep `name` and `status` with fixed per-status `message`/`remediation`; counts and `overall` remain; `detailsWithheld: true`. Check text can quote invalid configuration values and exception messages. |

All other `operator.read` methods were audited and return metadata only:
`sessions.active`, `sessions.active.list`, `sessions.context`, `sessions.get`,
`runs.active.list`, `runs.receipt.get`, `runs.timeline.get`, `goal.status`,
`cron.status`, `background.list`, `background.status`, `omp.status`,
`omp.models`, `memory.transfer.status`, `usage.cost`, `usage.records`,
`usage.status`, `blueprints.*`, `mcp.execution_names`, `models.list`,
`profiles.sync.status`, `node.capabilities.get`, `node.host.info`,
`node.profile.paths`, `node.runtime.features`, `setup.status`, `status`,
`skills.hermes.catalog`, `skills.list` and `commands.catalog`.

Two deliberate distinctions:

- Published discovery descriptions stay readable: blueprint names and
  descriptions (bundle-authored catalog text), MCP tool descriptions (published
  by the server) and skill manifest descriptions are bounded discovery metadata,
  not transcripts. The exception covers only those fields; MCP command and
  configuration previews are gated as above.
- Session identity labels stay readable: user-set session titles
  (`sessions.patch`), chat peer labels and topic names come from route/channel
  identity, not from prompts or answers. Prompt-derived titles (omp session and
  discovery titles, session previews) are content and are withheld.

Content callers receive every stored term through `LemonCore.Redact.project/2`
(`operator/2`, with larger caps, for `includeFullText`): credential text and
sensitive-key values, including the value of a `{key, value}` pair at any
position, become `[REDACTED]`; depth, item counts and string bytes are bounded;
output is JSON-safe. Scrubbing only removes recognisable credentials; it is not
what keeps ordinary prose away from read-only callers. Task `cleanup` flags
report the content actually returned, not the options requested.

`config.get` returns, for read scope, only the public fields `logLevel`, `env`,
`maxPayload`, `tickIntervalMs`, `heartbeatEnabled`, `heartbeatIntervalMs`,
`cronEnabled`, `skillsPath`, `routerModel` and `routerThinkingLevel`, and only
scalar values. Any other key (stored through `config.set`) needs
`operator.admin` and is returned through `LemonCore.Redact.operator/2`; a
read-scope request for it returns `value: null` with `summary.adminRequired`.

WebSocket events are authorized per recipient (see `LemonControlPlane.EventBridge`):
approval events need `operator.approvals`, pairing events `operator.pairing`,
every other event `operator.read` or `operator.content`. A read-only recipient
receives only allowlisted management events reduced to metadata fields; `chat`
deltas and `omp.session` snapshots are not sent, `metrics` arrives without its
free-form `payload`, `goal` events carry `loopVerdict` reduced to `action`,
`source`, `atMs` and `runId` (never the judge's `reason`; `source`, here and as
`goal.status` `lastSource`, is shown only as a known provenance value — `judge`,
`manual`, `preview`, `judge_failure_policy`, `unknown`, with `judge:<model>`
reduced to `judge` — and omitted otherwise; the goal judge sets it server-side
and ignores any model-written `source`), and nested
`session.event` batches keep their cursor with each inner event projected the
same way. `sessions.events` replay applies the same rule using the connection's
current scopes.

## `subagents.list`, `subagents.transcript`, `subagents.send`, `subagents.cancel`

The TUI Agent Hub's session-scoped view of native `task` subagents. Every method
takes `{"sessionKey":"..."}` (≤1,024 bytes); the per-agent methods add
`"taskId"` (≤256 bytes). Membership is lineage, decided by the runtime: a direct
child was launched by one of the key's root native sessions under the same key,
and a nested child by an included child. Another session's task, an `agent`
delegation or a background run returns `NOT_FOUND` (`SUBAGENT_NOT_FOUND`) for
every per-agent method, exactly as an unknown ID does.

- `subagents.list` (`operator.read`) returns `{"sessionKey","agents","total"}`.
  Each agent has `taskId`, `status` (`queued`, `running`, `idle`, `parked`,
  `completed`, `failed`, `cancelled`), `depth`, `messaging`, `cancellable` and,
  when known, `parentTaskId`, `name`, `agent` (persona), `description`,
  `model`, `activity`, `createdAtMs`, `startedAtMs`, `completedAtMs`,
  `updatedAtMs`, `contextPercent` and `usage` (`tokens`, `costUsd`, `requests`,
  `input`, `output`). Live children report their session's cumulative usage;
  finished ones only what their result recorded. Labels are single-line and
  bounded; prompts, workspace and transcript paths are never included. Without
  `operator.content`, `description` and `activity` are omitted and the response
  carries `contentWithheld: true`.
- `subagents.transcript` (`operator.read`) returns
  `{"taskId","status","text","truncated","contentWithheld"}`; without
  `operator.content`, `text` is replaced by `textBytes`. The text is the bounded visible transcript that
  `history://<task_id>` gives the parent agent (status, assignment, the last ten
  visible updates and the result; no hidden reasoning). The text is untrusted
  child output.
- `subagents.send` (`operator.write`) takes `"message"` (non-blank, ≤32 KiB)
  and uses the task tool's delivery path: a running child is steered at its next
  turn boundary, an idle child is woken and a parked child revived from its
  persisted session; the reply follows up into the parent session as usual.
  Returns `{"taskId","accepted","delivery","retrySafe"}` with `delivery` one of
  `injected`, `woken`, `revived`, `failed` or `outcome_unknown`. An unknown
  outcome (including a runtime that failed mid-call) may already have been
  delivered and has `retrySafe: false`. Finished or untracked children return
  `CONFLICT` with `SUBAGENT_NOT_ACTIVE`, `SUBAGENT_NOT_RESUMABLE`,
  `SUBAGENT_NOT_MESSAGEABLE` or `SUBAGENT_QUEUE_FULL`.
- `subagents.cancel` (`operator.write`) returns `{"taskId","cancelled":true}`.
  Cancellation is terminal: the child stops (with its descendants) and cannot be
  revived; its transcript stays readable. A finished child returns
  `SUBAGENT_NOT_ACTIVE`.

A missing runtime is `UNAVAILABLE`, never an empty roster.

## Unreadable state

A read whose store or runtime cannot answer returns `UNAVAILABLE`; it never
reports empty, idle, disabled or not-found state it did not read. This covers
`exec.approvals.get`, `config.get`, `logs.tail`, `sessions.preview`,
`chat.history`, `session.detail`, `cron.runs`, `tasks.active.list` and
`tasks.recent.list`, ACP `session/list` and session lookup, and A2A task reads
(JSON-RPC `-32603`). An execution node whose durable registry entry cannot be
read gets `UNAVAILABLE` at `connect` and retries, rather than `UNAUTHORIZED`
with `node_not_found`, which would park it for re-authorization.

`cron.status` stays a status projection: each section it cannot read (`jobs`,
`runs`, `audit`) is listed in `unavailable`, its counters are `null` (unknown)
rather than zero, and `enabled` is `null` when the job list itself is unreadable.

## `status`

Scope: `operator.read`. Parameters: `{}`. Optional subsystem lookup failures do
not fail the request. `subsystems` maps `presence`, `router`, `channels`, `skills`, and
`providers` to `{"status":"available"}` or `{"status":"unavailable"}` for the
corresponding lookup. Stopped channels still return empty
configured/connected/details arrays and stopped skills retain zero counts for
existing clients; consult `subsystems` before interpreting these as real empty
results. Availability describes a local query, not adapter/provider connectivity.

`runs` contains `active`, `queued`, `completed_today`, and `failed_today`.
Each field is a nonnegative integer or JSON `null` when its source is unavailable;
clients display null as **unknown**, never zero. `subsystems.router.fields` maps
each run-count field to `"available"` or `"unavailable"`; the router section's
`status` is unavailable if any field is unknown. Coordinator reads time out after
100 ms rather than waiting for the default GenServer timeout.

Daily counts use **midnight UTC**, not the operator's local timezone.
`completed_today` counts distinct terminal run IDs (including failures), while
`failed_today` counts `run_failed` and `run_completed` with `ok: false`.
The tracker rebuilds from durable introspection events on restart and deduplicates
live telemetry/events by run ID. Provider UsageStore requests are not run completions.
When introspection persistence is disabled or unreadable during initialization,
daily totals are unknown because complete history cannot be established.
`lemon status` reports launcher health/context, not these run counters.

- `server.version` is the Lemon release CalVer, shared with `hello-ok`: packaged
  runtimes use `RELEASE_VSN`, source checkouts use the umbrella `mix.exs` version.
  It is not the control-plane OTP application's independent package version.
- `server.build` contains `runtimeMode` (`source-dev` or `release-runtime`),
  nullable `channel`, and nullable `commit`. Build metadata uses
  `LemonCore.BuildInfo`; status reads environment/stamped commit metadata only,
  never launches git on each poll.
- `channels.configured` and `channels.connected` retain their existing meanings
  (registered adapters and running adapter processes). `channels.details` adds
  one `{id,state,lastError}` per configured adapter. State is `connected`,
  `configured`, or `error`; Telegram polling, Discord READY/RESUMED events, and
  XMTP/WhatsApp bridge transitions distinguish an observed live connection from
  merely starting a process. Startup failures are retained too. Errors contain
  only a fixed sanitized `message` (at most 256 characters, no tokens or paths)
  and the observed wall-clock `atMs`. A successful connection/poll clears the
  error. Unobserved adapters remain `configured` in details even when a process
  is running; the legacy `connected` array keeps its process-running meaning.
- `providers` contains `{id,configured,credential,default,lastError,circuit}` for providers
  selected by the configured default provider/model, configured in Lemon, or
  known to the model registry with local credentials present. `credential` is
  `present`, `missing`, or `not_required` (keyless local/custom endpoints).
  Presence is configuration/environment/encrypted-store metadata only: it is not
  proof of a valid key or a successful model request. No secret values, OAuth
  refresh, external secret-source commands, network discovery, or provider calls
  occur. `lastError` retains the dispatcher's timestamped credential-free failure
  summary, or null if none has been observed. `circuit` contains `state`
  (`closed`, `open`, `half_open`, `not_started`, or `unknown`), `failureCount`
  and `timeUntilRecoveryMs`. Polling never starts a breaker: an absent breaker
  reports `not_started` with null counters. Existing breakers are read directly
  from their ETS snapshots, even while the process is suspended; no breaker
  request or read timeout is involved. A registered breaker without a readable
  snapshot (including one disappearing during the read) reports `unknown` with
  null counters. TUI `/status` includes each provider's circuit state.
- `lifecycle` contains `{restart,stop,reason}`. Restart requires a nonempty
  `LEMON_LAUNCHER`; graceful stop is always available. `reason` explains why
  restart is absent and is null for launcher-managed runtimes.
- `summary.version` matches `server.version`; `providerCount`,
  `providersMissingCredentials`, and `channelErrorCount` are counts only.

Example additions (other counters omitted):

```json
{
  "server": {"version":"2026.10.10","build":{"runtimeMode":"source-dev","channel":null,"commit":null}},
  "channels": {"configured":["telegram"],"connected":[],"details":[{"id":"telegram","state":"error","lastError":{"message":"Channel authentication was rejected. Check credentials on the Lemon host.","atMs":1792022400000}}]},
  "providers": [{"id":"openai","configured":true,"credential":"missing","default":true,"lastError":null}],
  "lifecycle": {"restart":true,"stop":true,"reason":null},
  "summary": {"version":"2026.10.10","providerCount":1,"providersMissingCredentials":1,"channelErrorCount":1}
}
```

## `browser.stop`

Scope: `operator.admin` only. Parameters: `{}` (unknown/nonempty parameters are
rejected). Stops the local browser driver behind the `local`, `relay` and `cdp`
providers, and the Chrome it launched; a browser it only attached to keeps
running. In-flight side-effecting browser actions report an unknown outcome. The
next browser request starts a fresh driver. `lemon browser stop` calls it.

```json
{"type":"req","id":"browser-stop-1","method":"browser.stop","params":{}}
```

The result is `{"stopped": true}`. If the driver does not confirm in time the
method fails with `TIMEOUT`; whether it stopped is then unknown.

## `secrets.set` and `secrets.delete`

Scope: `operator.admin` only. Write-only access to the runtime's encrypted
secret store for one-shot CLI clients: while a runtime owns the store,
`lemon secrets set|delete|import-env` and the bot-token step of
`lemon setup gateway` send their write here instead of writing the store from a
second VM. `secrets.set` takes `name` and `value` (non-empty strings, at most
256 bytes and 1 MiB) and optional `provider` and `expiresAt` (epoch ms);
`secrets.delete` takes `name`.

```json
{"type":"req","id":"secrets-set-1","method":"secrets.set","params":{"name":"GITHUB_TOKEN","value":"<value>"}}
```

`secrets.set` returns `{"name", "owner", "provider", "expiresAt"}` and never
the value; `secrets.delete` returns `{"name", "deleted": true}` (deleting an
absent secret succeeds). A store refusal is `UNAVAILABLE` (`INVALID_REQUEST`
for a bad name or value) with `details.reason` (`missing_master_key`,
`weak_master_key`, `keychain_failed`, `master_key_mismatch`,
`key_rotation_incomplete`, `secrets_locked`, `stale_revision`,
`secret_store_failed`, ...) and `mutationMayHaveApplied: false`. An error
without that flag, or no response, may have written: check before retrying.

## `system.restart` and `system.stop`

Scope: `operator.admin` only. Parameters: `{}` (unknown/nonempty parameters are
rejected). Read/write-only operators and execution nodes cannot invoke them.

```json
{"type":"req","id":"restart-1","method":"system.restart","params":{}}
```

Both return an ordinary correlated success response with:

```json
{"accepted":true,"action":"restart","acceptedAtMs":1792022400000}
```

Stop returns the same shape with `action:"stop"`. Acceptance is not completion.
The WebSocket writes that response before its next mailbox turn arms the action;
the coordinator waits a further 250 ms before dispatch. If the connection dies
before that post-reply turn, the unarmed reservation is cancelled. Both actions
are logged without credentials/argv and share a single in-flight reservation:
a second request returns `CONFLICT`, including after the action is dispatched.
Clients must observe controller reconnection/down state rather than retrying
an accepted request. Dispatch failures are logged and release the reservation.

`system.restart` returns `UNAVAILABLE` with the same reason as `status.lifecycle`
when `LEMON_LAUNCHER` is empty/unset. It runs that launcher with `restart` under
detached `nohup`, with stdin closed and stdout/stderr redirected to
`LEMON_RUNTIME_LOG_FILE` or `~/.lemon/run/lemon-<control-port>.log`. The short-lived
parent shell exits before the launcher stops the old VM, so the restart child
survives VM termination. The source and packaged launchers both implement
`restart`. Environment is inherited, including `HOME`,
`LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT`, pid/log overrides,
and release selection settings.

For the source launcher (`LEMON_CLI_LAUNCHER=source`), effective `--name` or
`--sname` and the live distribution cookie are reconstructed from the running
VM, or `--no-distribution` is passed when distribution is disabled. Cookies are
never included in responses or logs. Packaged releases accept no source-style
runtime flags; they retain `RELEASE_NODE`, `RELEASE_DISTRIBUTION`, `RELEASE_COOKIE`
and external VM-args configuration through their existing environment/release
launcher. Manually changed in-VM distribution settings that are absent from that
release environment are not reconstructed. Custom launchers receive only
`restart` and inherited environment; they must preserve any private options
themselves.

When Lemon is supervised by `launchd` or `systemd` (installed via `lemon service install controller`),
the launcher's `restart` hands off directly to the service manager (`launchctl kickstart -k` on macOS,
`systemctl --user --no-block restart` on Linux) after verifying the authenticated snapshot token and
confirming the target release root. Supervised restart eliminates stop/start races and avoids
process-group termination issues. For unsupervised runtimes, RPC stop followed by background daemon
boot remains the default path; RPC cannot restart an offline runtime.

`system.stop` always remains available and calls graceful `System.stop(0)`;
it does not require a launcher. Stopping a remotely controlled runtime cannot
subsequently start it: use a local launcher or external service manager.

Tests can replace the side-effect module with application env
`:lemon_control_plane, :lifecycle_driver`, implementing
`LemonControlPlane.Lifecycle.Driver`'s `restart/1` and `stop/0` callbacks. This
does not change availability or authorization, and production uses the real
detached launcher / graceful VM shutdown driver.

