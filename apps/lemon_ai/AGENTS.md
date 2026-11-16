# LemonAi contributor guide

`lemon_ai` provides model catalogs, provider protocols, completion/stream APIs,
rate limiting and error classification. It has no umbrella dependencies.
Usage belongs in [README](README.md); Lemon-specific config and credential
resolution belong in `lemon_agent`, not provider implementations.

## Provider and model changes

- Implement `LemonAi.Provider` and register through the existing application /
  `ProviderRegistry` path. Preserve the common `LemonAi.Types` contract rather
  than leaking provider-shaped responses to consumers.
- Model data lives in `priv/models/<provider>.json`; its module loads through
  `LemonAi.Models.Catalog` with `@external_resource`. Register the catalog in
  `LemonAi.Models`. Add new API/provider/input strings to explicit allowlists;
  never create atoms from catalog or user input.
- Declare reasoning capabilities in catalog metadata (`adaptive_thinking`,
  `reasoning_efforts`). Do not infer request shape from model-ID substrings.
- Providers receive concrete auth through `StreamOptions`. OAuth helpers may
  refresh encoded credentials; the caller injects persistence. OpenAI-compatible
  integrations must resolve provider-specific credentials before generic OpenAI
  fallback, not accidentally send the wrong account's key.

## Streaming and concurrency

- Provider workers run under `LemonAi.StreamTaskSupervisor`. Complete or error
  the `EventStream` on every terminal path; owner death must cancel work.
- Queues are bounded. `push/2` reports overflow/backpressure; `push_async/2` is
  fire-and-forget. Preserve terminal delivery even when a consumer falls behind.
- `CallDispatcher` owns circuit-breaker, rate-limit and concurrency admission.
  At the cap, callers wait in a bounded per-provider FIFO; `:max_concurrency`
  means the wait timed out before the callback ran. `queue_timeout_ms: 0` is
  explicit fail-fast mode, not the ordinary path.
- Slot admission is **fail-closed**: an unavailable per-provider authority returns
  `{:error, :admission_unavailable}` (classified `:transient`) without running the
  callback. No caller contract relies on bypassing caps during a restart; allowing
  that bypass would overload providers precisely when the runtime is recovering.
  Independent provider authorities use leases/caps in root-supervisor-owned ETS,
  so restarting an authority or the dispatcher cannot forget live work. Rebuild
  owner monitors from those leases before admitting new calls; releases during
  downtime must remove the retained lease. This protects child-process restarts,
  not VM/application shutdown or a distributed/global provider quota.
  Queued callers interrupted by an authority restart receive the unavailable error;
  they are never replayed or granted a replacement slot implicitly.
  A request that finds a known authority missing is rejected even if rebuilding
  that authority succeeds; later attempts use the recovered leases and cap.
- Circuit admission/status reads use ETS snapshots, not breaker calls. Result
  recording and reset publish snapshots synchronously before returning.
- Admission must be released after streaming completion or owner failure, not
  merely when a stream handle is returned. Circuit success/failure reflects the
  completed stream.
- Every admitted model call emits one `[:lemon_ai, :model_call, :start]` and exactly
  one `:stop` or `:exception` (`LemonAi.ModelCallTelemetry`; catalogue in
  `docs/telemetry.md`). Streams stop from the existing `track_stream_result`
  tracker, never a second watcher. Keep prompts, messages, credentials, URLs and
  raw error terms out of its metadata; use bounded category atoms.
- Retry only the classified transient errors under `LemonAi.Retry`'s bounded
  policy. Respect capped server retry hints; longer waits surface to the session
  rather than creating an unbounded provider sleep. Never retry tool side effects
  by analogy with HTTP retries.
- Error classification should retain actionable provider details without leaking
  credentials. Test error maps, nested validation details and retry metadata at
  the public result boundary, not private parser wiring.

## Debugging and verification

`LemonAi.CallDispatcher.get_state/0` and `CircuitBreaker.get_state/1` expose
admission/circuit state. HTTP/SSE tracing may contain private content: enable it
only deliberately, keep output private, and do not paste raw traces into issues.
Prompt-size diagnostics are preferable when investigating context growth.

From the umbrella root:

```bash
mix test apps/lemon_ai/test
```

Use the existing local HTTP/provider fixtures and injectable retry sleep function.
Restore circuit, rate-limit and registry state when tests touch global resources.
Live credential tests belong in the opt-in integration lane.

This is one of five published Hex package targets. Admission changes extend the
public error surface: `dispatch/3`, `set_concurrency_cap/2`,
`get_concurrency_cap/1` and `get_active_requests/1` may return
`{:error, :admission_unavailable}`; `get_state/0` includes `:unavailable` providers.
Breaker result recording/reset retain their `:ok` result but now acknowledge
snapshot publication synchronously. `peek/1` can read a suspended breaker instead
of returning `:unknown` merely because it cannot process messages.
Keep `mix.exs` self-contained in tarballs and verify package changes with
`scripts/verify_packages`. See [publication status](../../docs/platform-split.md).
