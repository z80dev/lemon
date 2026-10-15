# Control-plane system methods

Connect to the authenticated `/ws` endpoint and discover supported methods in
`hello-ok.features.methods`. See the [control-plane guide](../../apps/lemon_control_plane/README.md)
for framing, authentication and the domain-specific method reference.

## `status`

Scope: `operator.read`. Parameters: `{}`. Existing runtime, connection, run and
skill counters remain unchanged. Optional subsystem lookup failures do not fail
the request; stopped channels return empty configured/connected/details arrays.

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
- `providers` contains `{id,configured,credential,default,lastError}` for providers
  selected by the configured default provider/model, configured in Lemon, or
  known to the model registry with local credentials present. `credential` is
  `present`, `missing`, or `not_required` (keyless local/custom endpoints).
  Presence is configuration/environment/encrypted-store metadata only: it is not
  proof of a valid key or a successful model request. No secret values, OAuth
  refresh, external secret-source commands, network discovery, or provider calls
  occur. `lastError` is null because this projection has no retained provider
  error with a wall-clock observation time.
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

