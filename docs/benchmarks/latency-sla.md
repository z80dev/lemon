# Native harness latency budget

This lane measures infrastructure, not model intelligence. It uses the production
control-plane WebSocket, router, gateway, native session, dispatcher and ZAI
OpenAI-compatible parser with an in-memory Req Plug replay of
`apps/lemon_ai/test/fixtures/openai_completions/compatible_complete.sse`.
No provider socket, account, credential, tokenizer download or paid call is used.
Loopback WebSocket sockets are required; “offline” does not mean no local IPC.
An unexpected Req route or model switch fails closed.

## Run locally

Prepare dependencies and a **development** build once from the umbrella root.
The benchmark itself neither fetches dependencies nor compiles:

```bash
mix lemon.eval.latency --boots 5 --turns 20 \
  --revision FULL_40_CHARACTER_COMMIT_SHA --output /tmp/latency.json
# Compare the same machine/toolchain against an earlier retained report:
mix lemon.eval.latency --boots 5 --turns 20 \
  --revision FULL_40_CHARACTER_COMMIT_SHA --output /tmp/after.json \
  --baseline /tmp/before.json
```

Alternatively run `python3 -B apps/lemon_evals/priv/latency_benchmark.py` with the
same arguments. Python 3.11+ and prebuilt dev BEAMs are prerequisites. The task
boots no applications in the invoking VM. Each boot gets a private temporary
HOME, config, cwd, stores and randomly generated local operator token. Ambient
provider credentials, Lemon settings and proxy environment are not forwarded.
Only code-authored fixture text is submitted, and no tools are requested by the
fixture. Runtime output is private and discarded with the temporary state;
only the allowlisted report is uploaded. Subprocess groups are terminated in
`finally`, including on timeouts. The Req override and telemetry handlers live
only in that disposable VM; no user's runtime or provider registry is modified.

Every distribution prints nearest-rank p50/p99 in milliseconds and sample count.
Defaults produce five cold boots, five warm health requests and 100 pairs of
turns. Session-stage sample counts reflect actual session creation, **not an
assumption that a future persistent-session implementation creates two sessions
per pair**. Missing required boundaries, failed runs, missing deltas and negative
samples fail the lane instead of producing a false zero.

## Boundaries and stage breakdown

| Metric | Start → stop |
| --- | --- |
| `enter_to_provider` | Client submits `agent` through the real WebSocket → local mock Req handler receives the request |
| `provider_to_client` | Mock releases the first SSE text → WebSocket client receives and decodes its first nonempty `chat.delta` |
| `provider_to_gateway_token` | Same mock timestamp → synchronous gateway first-token telemetry handler |
| `gateway_token_to_client` | Gateway first-token timestamp → same decoded client delta |
| `completion_to_next_start` | Gateway `[:lemon, :run, :stop]` → next queued run's gateway `:start`, timestamped synchronously at emit sites |
| `cold_ready` | Python launches precompiled `mix run` VM → authenticated control-plane hello |
| `boot_to_ready` | Production `LemonCore.Runtime.Boot.start!(:runtime_full)` → authenticated hello |
| `warm_ready` | Existing authenticated socket sends `health` → successful response |
| `session_journal_load` | Lifecycle loads/creates journal → resolved header/cwd |
| `session_tool_registry` | Extension/tool lifecycle initialization → planning tools and tool names resolved |
| `session_environment_capture` | Environment capture call, or frozen-snapshot bypass |
| `session_prompt_composition` | Prompt sections, joining and planning prompt composition |

The four session stages break down per-turn initialization cost within
`enter_to_provider`; they exclude workspace creation, settings/model resolution,
execution-context journal writes, agent startup and transport/admission work.
They are not the entire request path and their percentiles must not be added
(the p99 observations can come from different turns). The token stages partition
each measured token path; queue handoff uses origin timestamps, not client event
arrival order. All within-VM timings use monotonic microseconds. The external
cold-start clock uses wall microseconds across Python/BEAM and must be discarded
if the host clock is stepped during measurement.

The first provider request is held behind a message barrier until the second
run's submission is acknowledged. Both share a fresh session key. Only then is
the provider released; this proves a real queued handoff without sleep races.
The hold is outside both request-arrival and first-token intervals.

**Client scope:** “Enter” is API submission, and “client token” is decoded
WebSocket delivery, not a terminal paint. This lane does not time Bun startup,
TUI keyboard handling, terminal rendering, or the shell launcher's compile/probe
branches. Cold/warm readiness above measures the shared production boot and
control protocol, not literal end-to-end `./bin/lemon` TUI readiness. Record a
separate terminal/launcher measurement before claiming those user-interface
budgets. These limitations are explicit rather than silently reporting an IPC
measurement as a pixel-render measurement.

## Targets and first measured evidence

Measured 2026-11-16 at `abc566dcdb83f35d311fb9c2c66b889e3b6fcc9d` on a
MacBook Pro (Mac15,9), Apple M3 Max, 128 GB RAM, macOS 15.6, OTP 29 /
ERTS 17.1.1, Elixir 1.20.5, two benchmark schedulers. Command:
`mix lemon.eval.latency --boots 5 --turns 20 --revision $(git rev-parse HEAD) --output /tmp/latency.json`.
The retained report has five boot/readiness observations and 100 turn/stage
observations. Targets below are initial same-machine warning budgets, set to
the first observation plus the existing regression policy's larger allowance
(25% or 2 ms); they are not production SLAs. Other host activity was not
controlled. The pre-epic `4d94b3c8e` checkout has no latency harness, so no
before/after improvement is established. Vendor nanocode figures are not a
comparable baseline.

| Budget | Current p50 / p99 | Target p50 / p99 | Source |
| --- | --- | --- | --- |
| Enter → mock request | 513.103 / 892.480 ms | 641.379 / 1115.600 ms | First local report, revision above |
| Mock token → WebSocket client | 1.068 / 6.671 ms | 3.068 / 8.671 ms | First local report, revision above |
| Completion → queued start | 30.042 / 52.982 ms | 37.553 / 66.228 ms | First local report, revision above |
| Cold ready | 1156.292 / 1382.840 ms | 1445.365 / 1728.550 ms | First local report, n=5 |
| Warm ready | 1.133 / 1.149 ms | 3.133 / 3.149 ms | First local report, n=5 |
| Journal load | 20.029 / 30.787 ms | 25.036 / 38.484 ms | First local report, n=100 |
| Environment capture | 77.494 / 129.851 ms | 96.868 / 162.314 ms | First local report, n=100 |
| Prompt composition | 2.777 / 10.915 ms | 4.777 / 13.644 ms | First local report, n=100 |
| Tool registry | 195.275 / 281.042 ms | 244.094 / 351.303 ms | First local report, n=100 |

Top three measured session-start contributors by p50: **tool registry
(195.275 ms), environment capture (77.494 ms), journal load (20.029 ms)**.
Production boot-to-ready was 575.901 / 743.024 ms p50/p99; mock-token to
gateway was 0.368 / 3.991 ms, and gateway-token to client 0.508 / 2.809 ms.
These stage percentiles are not additive. With only five boot samples p99
is the maximum; no terminal-render or literal launcher timing is claimed.

## Nightly regression policy

The `latency` job in `.github/workflows/nightly.yml` runs without provider secrets,
retains sanitized `latency.json` for 90 days even when comparison fails, and
participates in the existing `nightly-red` health report. It downloads the most
recent successful main Nightly's retained `latency-results` artifact. Missing or
expired evidence is explicitly reported as `bootstrap_no_baseline`, not “no
regression”; an actual download/API failure fails the job. Local comparisons
accept `--baseline` explicitly.

Each metric's p50 **and** p99 are checked. A regression is flagged only if it
exceeds **both 25% relative and 2 ms absolute** above that baseline. Equality is
not a regression. Schema, OS, architecture, OTP, Elixir and scheduler settings
must match; mismatches fail closed and require an intentional new baseline.
These are coarse shared-runner warning thresholds, not production SLAs or proof
of statistical significance. Confirm a flag with same-machine before/after
measurements before making an architectural claim. The initial fixed budgets
above come from the first local report.

Issues #547, #559, #564 and #567 must record before/after artifacts from this
command, exact revisions/settings and p50/p99 changes before claiming latency
improvements. Their future results cannot be supplied by this initial harness.
See also [primitive microbenchmarks](platform-microbenchmarks.md) and the
[telemetry catalogue](../telemetry.md).
