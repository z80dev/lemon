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
  `configured`, or `error`; Telegram polling and XMTP/WhatsApp bridge transitions
  distinguish a live connection from merely starting a process. Startup failures
  are retained too. Errors contain only a fixed sanitized `message` (at most 256
  characters, no tokens or paths) and the observed wall-clock `atMs`. A successful
  connection/poll clears the error. Uninstrumented adapters retain the existing
  process-running connection indication, not a fabricated network probe.
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
