# Control-plane system methods

Connect to the authenticated `/ws` endpoint and discover supported methods in
`hello-ok.features.methods`. See the [control-plane guide](../../apps/lemon_control_plane/README.md)
for framing, authentication and the domain-specific method reference.

## HTTP and protocol errors

Non-`/v1` HTTP failures use `{"error":{"code":"UNAUTHORIZED","message":"..."}}`,
with the same string codes as WebSocket error frames. ACP HTTP authentication
failures use this HTTP envelope; authenticated ACP method replies retain JSON-RPC
framing and numeric method-error codes. `/v1/*` retains OpenAI-compatible errors
(`error.message` and `error.type`), and `/healthz` remains `{"ok":true}`.

HTTP authentication errors name `Authorization: Bearer <token>` and the server's
token configuration: `LEMON_ACP_API_TOKEN` for `/acp`,
`LEMON_OPENAI_COMPAT_API_TOKEN` for `/v1/*` (both also accept `x-api-key`), and
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` for `/acp/ws`. Managed launchers store the
operator token at `~/.lemon/run/control-plane-<port>.token`. Native `/ws` clients
send that token in `connect.params.auth.token`, not an HTTP header.
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
  and `timeUntilRecoveryMs`. Polling never starts a breaker; unavailable counters
  are null. Existing breakers have a bounded 100 ms read timeout and process
  exits report `unknown`. TUI `/status` includes each provider's circuit state.
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
`LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT`, `LEMON_SIM_UI_PORT`, pid/log overrides,
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
themselves. RPC cannot restart an offline runtime or promise survival across
host/service-manager termination of the entire process group.

`system.stop` always remains available and calls graceful `System.stop(0)`;
it does not require a launcher. Stopping a remotely controlled runtime cannot
subsequently start it: use a local launcher or external service manager.

Tests can replace the side-effect module with application env
`:lemon_control_plane, :lifecycle_driver`, implementing
`LemonControlPlane.Lifecycle.Driver`'s `restart/1` and `stop/0` callbacks. This
does not change availability or authorization, and production uses the real
detached launcher / graceful VM shutdown driver.

