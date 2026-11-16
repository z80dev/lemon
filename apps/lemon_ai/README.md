# lemon_ai

A provider-agnostic LLM client for Elixir. Call **27 model providers** — Anthropic,
OpenAI, Google, AWS Bedrock, Azure, Groq, Mistral, xAI, DeepSeek, OpenRouter, and more —
through **one streaming API**, with a built-in model registry, per-provider circuit
breaking and rate limiting, and cost accounting. No web framework, no umbrella, no
runtime dependencies beyond [`req`](https://hex.pm/packages/req),
[`finch`](https://hex.pm/packages/finch),
[`jason`](https://hex.pm/packages/jason),
[`nimble_options`](https://hex.pm/packages/nimble_options), and
[`websockex`](https://hex.pm/packages/websockex).

The whole surface is `LemonAi.stream/3` and `LemonAi.complete/3` plus a handful of helpers. Point
a `%LemonAi.Types.Model{}` at any provider and the rest of your code stays identical.

## Install

```elixir
def deps do
  [
    {:lemon_ai, "~> 0.2"}
  ]
end
```

`0.2.0` is the first installable release line; the `0.1.0` release on Hex cannot be
installed and is retired. Until `0.2.0` is on Hex, depend on the repository instead:

```elixir
{:lemon_ai, github: "z80dev/lemon", sparse: "apps/lemon_ai"}
```

The OTP application is named `:lemon_ai`, so you call it as `LemonAi.*`. It starts its own
supervision tree (circuit breakers, rate limiters, the model cache) automatically.

## Quickstart

Set the API key for whichever provider you want (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GOOGLE_GENERATIVE_AI_API_KEY`, …) and make a blocking call:

```elixir
model = LemonAi.Models.get_model(:anthropic, "claude-haiku-4-5")

context =
  LemonAi.new_context(system_prompt: "You are a helpful assistant.")
  |> LemonAi.Types.Context.add_user_message("Explain OTP supervision in two sentences.")

{:ok, message} = LemonAi.complete(model, context)

IO.puts(LemonAi.get_text(message))
```

Switch providers by changing one line — the context, options, and result handling are
identical:

```elixir
model = LemonAi.Models.get_model(:openai, "gpt-4o")
model = LemonAi.Models.get_model(:google, "gemini-2.5-pro")
model = LemonAi.Models.get_model(:groq, "llama-3.3-70b-versatile")
```

The API key resolves in this order: `opts.api_key` you pass in →
provider-specific env var (e.g. `ANTHROPIC_API_KEY`) → generic fallback. So you can pass
keys explicitly or rely on the environment.

## Streaming

`LemonAi.stream/3` returns an `LemonAi.EventStream` you consume as a lazy stream of events:

```elixir
{:ok, stream} = LemonAi.stream(model, context, %{temperature: 0.7, reasoning: :medium})

stream
|> LemonAi.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta} -> IO.write(delta)
  {:thinking_delta, _idx, delta} -> IO.write([IO.ANSI.faint(), delta, IO.ANSI.reset()])
  {:done, _reason, _message} -> IO.puts("\n-- done --")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)
```

Convenience helpers on the stream:

```elixir
text            = LemonAi.EventStream.collect_text(stream)   # blocking, returns full text
{:ok, message}  = LemonAi.EventStream.result(stream)         # blocking, returns final message
%{queue_size: _, dropped: _} = LemonAi.EventStream.stats(stream)
LemonAi.EventStream.cancel(stream, :user_requested)
```

Non-blocking lifecycle observers can call
`LemonAi.EventStream.subscribe_result/2`; it synchronously registers the
subscriber and later sends `{:event_stream_result, reference, result}`. This
guarantees that a subsequent cancellation cannot overtake result registration.

### Delta-only event contract (breaking package change)

Provider content events no longer carry an `AssistantMessage` snapshot:

- Starts: `{:text_start, index}`, `{:thinking_start, index}`,
  `{:tool_call_start, index, tool_call}` (tool identity/initial arguments).
- Deltas: `{:text_delta | :thinking_delta | :tool_call_delta, index, delta}`.
  Tool argument deltas are JSON fragments.
- Ends: `{:text_end, index, text}`, `{:thinking_end, index, thinking}`,
  `{:tool_call_end, index, tool_call}`.
- `{:start, message}`, `{:done, reason, message}` and
  `{:error, reason, message}` retain their existing shapes. Terminal messages
  retain complete content, usage and provider signatures.

Render delta bytes in order; subscriber transports may combine adjacent text
deltas for the same block without changing their concatenated bytes. Consumers
that need partial answers can keep `LemonAi.StreamAccumulator.new(message)`, feed
events through `apply/2`, and call `snapshot/1` on demand. It retains chunks rather
than copying a growing binary on every event. Do not materialize a snapshot on
each delta. `result/2` and `collect_text/1` still return the same final text.

The opt-in 100 KiB tool-argument benchmark is excluded from default tests; see
`apps/lemon_ai/test/lemon_ai/stream_delta_benchmark_test.exs` for its focused command
and the byte-copy accounting method. No live provider calls are required.

`LemonAi.complete/3` collects the stream privately and retries classified transient
completion errors, including resolved error messages, up to **three total attempts**.
Its attempt budget replaces nested provider HTTP retries rather than multiplying
them. Authentication, invalid requests, quota exhaustion and context overflow are
not retried. Structured retry hints take priority over backoff; a hint longer than
the default 30-second maximum wait surfaces the original failure instead of
retrying earlier than requested.

```elixir
LemonAi.complete(model, context, retry: [max_attempts: 2, max_delay_ms: 10_000])
# Disable completion retries:
LemonAi.complete(model, context, retry: [max_attempts: 1])
```

`LemonAi.OneshotRetry.run/2` provides the same bounded policy for side-effect-free
completion callbacks, with per-call `sleep_fun`, `cancelled?` and
`subscribe_cancel` hooks. A subscription returns
`{:message, cancellation_message, unsubscribe_fun}`; backoff waits receive that
message without polling, and cleanup runs on every exit. Without a subscription,
the cancellation predicate is checked only at attempt/wait boundaries. Do not use
it around tool execution or externally consumed streams. `LemonAi.stream/3` does
not acquire oneshot retries; the agent loop refuses replay after any text,
thinking or tool update, even if later partials erase the content. Metadata-only
failed attempts do not leave dangling transcript starts, and reported usage from
failed attempts remains charged to the cumulative agent budget.

### Preconnect and opt-in hedging

`LemonAi.preconnect(model)` asynchronously hints the stock `Req.Finch` pool with
an unauthenticated `HEAD /` to the model's origin. It never generates tokens or
sends credentials/prompts; failure does not affect calls. Caller policy coalesces
each origin for 30 seconds and permits eight distinct origins per window, with
eight concurrent tasks maximum. Servers may close connections;
first-request latency improvements still require the #546 measurement.

Request hedging is **off for every provider by default**, including subscription
providers whose quotas count duplicate calls. Enable only selected providers:

```elixir
config :lemon_ai, LemonAi.CallDispatcher, hedging: %{openai: true}
```

The dispatcher retains the latest 100 first-content-event latencies per
provider/model (caller policy), using their nearest-rank p90 as the deadline.
There is no hedge until an observation exists. At most one duplicate can start
after that deadline, only through normal circuit/rate admission and a
**zero-wait concurrency acquisition**. Failed admission never queues or bypasses
the provider authority. The first content event or terminal result selects the
winning stream; the losing stream and its provider task are cancelled. No output
from the losing stream reaches the caller. Tools and unlabelled callbacks never
hedge.

An atomic per-model budget permits no more than `floor(requests / 10)` duplicates,
including duplicates that fail after admission. The cap is cumulative since
dispatcher startup, not a rolling rate; restart resets the latency/budget window.
The duplicate input is conservatively estimated using the existing prompt-size
heuristic, added to the returned message's known input/total-token counters, and
recorded in `CallDispatcher.hedging_state(provider, model).duplicate_input_tokens`.
It is not measured vendor billing; unknown usage remains unknown and cost fields
remain vendor-reported. Each admitted transport retains its own model-call span;
the separate `:hedge_started` telemetry records the estimate, avoiding duplicate
logical usage in those spans.

Published-package API additions: `LemonAi.preconnect/1`,
`LemonAi.CallDispatcher.hedging_state/2`, per-provider `:hedging` configuration,
and the dispatch option `:hedge_input_tokens` (zero-arity estimate callback;
supplied automatically by `LemonAi.stream/3` and `complete/3`).

## Tool use

```elixir
tools = [
  %LemonAi.Types.Tool{
    name: "get_weather",
    description: "Get weather for a location",
    parameters: %{
      type: "object",
      properties: %{location: %{type: "string"}},
      required: ["location"]
    }
  }
]

context =
  LemonAi.new_context(system_prompt: "You can check weather.", tools: tools)
  |> LemonAi.Types.Context.add_user_message("Weather in Paris?")

{:ok, message} = LemonAi.complete(model, context)

for tc <- LemonAi.get_tool_calls(message) do
  result = %LemonAi.Types.ToolResultMessage{
    tool_call_id: tc.id,
    tool_name: tc.name,
    content: [%LemonAi.Types.TextContent{text: "Sunny, 22C"}],
    is_error: false
  }

  context =
    context
    |> LemonAi.Types.Context.add_assistant_message(message)
    |> LemonAi.Types.Context.add_tool_result(result)

  {:ok, final} = LemonAi.complete(model, context)
  IO.puts(LemonAi.get_text(final))
end
```

## Provider capability matrix

Every provider is reached through one of **10 wire-protocol modules**. The 27 registered
provider IDs in `LemonAi.Models` route through these — for example Groq, xAI, DeepSeek,
Qwen, Cerebras, OpenRouter, Vercel AI Gateway, HuggingFace, Fireworks, and Mistral all
speak the OpenAI Chat Completions format, so they inherit its capabilities.

The migration replaced 25 provider-module literal catalogs with 26 JSON resources under
`priv/models/`, loaded at compile time by `LemonAi.Models.Catalog`. The counts differ
because Google uses `google.json` plus `google_antigravity_extras.json`. The
`:google_antigravity` registry is derived from entries tagged for that provider plus the
extras file; `:openai_codex` uses an explicit ChatGPT OAuth catalog rather than
exposing API-key-only models under the subscription endpoint. The files are compiler
external resources, so edits recompile their provider modules. Invalid JSON and malformed entries
fail compilation with catalog and model-key context, including invalid field types,
negative sizes, negative costs, and unsupported compatibility overrides. Atom-valued API,
provider, input, and compatibility keys use explicit allowlists rather than creating atoms
from arbitrary catalog strings.

| Wire module (`api_id`) | Streaming | Tool calls | Vision (image input) | Reasoning / thinking | Cost data |
|------------------------|:---------:|:----------:|:--------------------:|:--------------------:|:---------:|
| Anthropic `:anthropic_messages` | ✅ | ✅ | ✅ | ✅ | ✅ |
| OpenAI Chat Completions `:openai_completions` | ✅ | ✅ | ✅ | ✅ | ✅ |
| OpenAI Responses `:openai_responses` | ✅ | ✅ | ✅ | ✅ | ✅ |
| OpenAI Codex `:openai_codex_responses` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Azure OpenAI `:azure_openai_responses` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Google Generative AI `:google_generative_ai` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Google Vertex `:google_vertex` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Google Gemini CLI `:google_gemini_cli` | ✅ | ✅ | ✅ | ✅ | ✅ |
| AWS Bedrock `:bedrock_converse_stream` | ✅ | ✅ | ✅ | ✅ | ✅ |
| Mistral Conversations `:mistral_conversations` | ✅ | — | — | — | ✅ |

Vision and reasoning are additionally gated **per model** by the model's `input` and
`reasoning` fields — a wire module supporting vision doesn't make a text-only model
accept images. The thinking request shape is driven by explicit capability flags on
each catalog entry: `adaptive_thinking` (Anthropic-style `thinking: adaptive`,
plus `output_config.effort` when efforts are declared) and `reasoning_efforts` (the
Lemon levels a model accepts; other levels clamp to the nearest declared one via
`LemonAi.Models.reasoning_effort_for/2`). Query the specific model:

```elixir
LemonAi.Models.supports_vision?(model)
LemonAi.Models.supports_reasoning?(model)
LemonAi.Models.supports_xhigh(model)
```

### Provider request controls

OpenAI Responses and Codex Responses support an **opt-in**, session-owned
WebSocket transport. SSE remains the default. Standalone callers create one
transport per live conversation and pass its PID on every turn:

```elixir
{:ok, transport} =
  LemonAi.Providers.OpenAIResponsesWebSocket.start_link(owner: self())

opts = %LemonAi.Types.StreamOptions{
  api_key: key,
  provider_options: %{responses_websocket: true, responses_transport: transport}
}

{:ok, stream} = LemonAi.stream(model, context, opts)
```

Always pass the complete context: the transport sends only the new suffix when
the previous response and replay prefix still match. A definite first-frame
anchor rejection permits one full replay; three rejected anchors disable
chaining for that live session. Partial or uncertain exchanges are never replayed.
Idle sockets close after 30 seconds. Credential/header changes, endpoint/model
changes and `OpenAIResponsesWebSocket.reset/1` discard the connection and anchor;
call `reset/1` after compaction or history replacement. Owner death releases the
transport. This state is memory-only and must not be journaled or shared across
accounts or sessions. No token or latency improvement is claimed without an arena
measurement. These provider options and transport lifecycle functions extend the
published `lemon_ai` API.

Anthropic requests default the required `max_tokens` field to the model's full
output budget rather than a fraction of it. An explicit `max_tokens` overrides
that default (clamped to the model maximum, with room reserved for manual thinking).
First-party Claude models older than 4.5 declare
`compat.anthropic_context_window_overflow`, enabling the
`model-context-window-exceeded-2025-08-26` beta so input plus the output budget can
exceed the context window without a validation error. The beta composes with
OAuth, effort, and caller betas. A `model_context_window_exceeded` stop is normal
truncation (`:length`), just like `max_tokens`; see Anthropic's
[context-window documentation](https://platform.claude.com/docs/en/build-with-claude/context-windows).

Other transports leave optional output limits unset unless `max_tokens` is
explicitly supplied, retaining server defaults and avoiding context-fit errors
on local servers or excessive credit preauthorization on OpenRouter. Z.AI is the
exception described below. Codex subscription requests omit output limits, and
Bedrock Nova high-effort reasoning omits `maxTokens` as required by those endpoints.

Z.AI keeps the coding-plan Chat Completions endpoint
(`/api/coding/paas/v4/chat/completions`), sends `max_tokens` (131,072 for GLM-5.x),
and uses top-level `reasoning_effort` alongside `thinking: {type: "enabled"}`
on models declaring effort support. GLM-5.3 variants use `low`, `high`, or `max`;
Lemon's `medium` maps to `high`, `xhigh` to `max`, and off/minimal maps to `low`
because these models require thinking. GLM-5.2 also accepts disabled thinking;
older models receive only the thinking toggle, not an unsupported effort field.
These shapes follow Z.AI's [deep-thinking](https://docs.z.ai/guides/capabilities/thinking)
and [parameter](https://docs.z.ai/guides/overview/concept-param) documentation.

Modern OpenAI Responses models accept sampling temperature only at effective
effort `:none`. `PI_CACHE_RETENTION=long` requests 12-hour retention through
`prompt_cache_options.ttl` on current models; older models retain their 24-hour
`prompt_cache_retention` format. Set
`thinking_budgets: %{service_tier: "ultrafast"}` to request that tier on a
supporting model. Returned `usage.cost` accounts for the actual response tier,
mixed cache-write lifetimes and long-context prices; `"fast"` responses use
the model's Priority rates.

Google models with declared reasoning levels use `thinkingLevel`, including
Gemini 4 Argon, which rejects `thinkingBudget`. Legacy budget-based models
still accept budget overrides. Vertex's global location uses
`aiplatform.googleapis.com`.

Bedrock uses the catalog's AWS region unless the caller supplies an explicit
region override, and signs for that same region. Adaptive Claude models use
Converse's adaptive-thinking fields. Nova 2 high-effort reasoning omits its
incompatible temperature and output-token cap.

### Reviewed upstream identities

Subscription compatibility currently imitates upstream clients rather than only
identifying Lemon. [`priv/upstream_identities.json`](priv/upstream_identities.json)
is the review ledger: it records exact local prompt/header/client-ID bytes,
SHA-256 hashes, immutable npm versions or full GitHub revisions, and hashed
upstream files containing the evidence. Public OAuth client IDs are application
identifiers, not access tokens. No credentials belong in this manifest.

| Identity | Preserved baseline and provenance |
| --- | --- |
| Claude Code | System prefix, OAuth betas, `x-app`, public client ID and User-Agent template from published [`pi-ai@0.49.0`](https://registry.npmjs.org/@mariozechner/pi-ai/0.49.0); version [`2.1.296`](https://registry.npmjs.org/@anthropic-ai/claude-code/2.1.296). |
| GitHub Copilot | Chat `0.35.0`, VS Code `1.107.0`, integration ID and public client ID from the same pi-ai package; all provider/auth and model-catalog copies are checked. |
| Gemini / Antigravity | Cloud SDK/Node headers, metadata, body identities, Antigravity `1.11.5`, its system instruction and copied Pi bridge prompt from the same pi-ai package. |
| Codex | Public OAuth client and `pi` originator from pi-ai; capability version from [`@openai/codex@0.159.0`](https://registry.npmjs.org/@openai/codex/0.159.0). Lemon's `pi/0.159.0` User-Agent is a composition, **not** a pi release number. Request and discovery versions are both checked. |
| Kimi | Version and public client ID from [`kimi-cli@1.52.0`](https://github.com/MoonshotAI/kimi-cli/tree/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82); KimiCLI User-Agent template from the pinned omp source. |
| SuperGrok / ZCode | Public client IDs and ZCode redirect identity from [`omp@7c49c11`](https://github.com/can1357/oh-my-pi/tree/7c49c11aa5bbaf3f418406583096168ad5b8c6dc). This is compatibility-client provenance, not first-party vendor source. |

Claude's advertised version is fixed at the reviewed value: installing a newer
`claude`/`claude-code` executable no longer silently changes network identity.
Existing explicit caller header/client-ID overrides remain caller-owned.
Actual host/OS values, session/device/account IDs and tokens are not upstream
constants. Gemini and Antigravity OAuth client credentials are operator-supplied,
not bundled vendor identities. The OpenCode Go `lemon_ai` User-Agent, Codex OAuth
`lemon` originator, and Z.AI `lemon` key name are Lemon's own identities and are
explicitly excluded.

From the repository root (Python 3 standard library only; no Mix compilation):

```bash
python3 scripts/check_upstream_identities --offline
python3 scripts/check_upstream_identities --online
```

Offline mode fails on changed, missing or duplicated local identity selections,
including every repeated Copilot catalog header. Online mode also downloads the
pinned artifacts, resolves npm's **latest** dist-tag / GitHub's current default
branch, fetches those sources, and fails on version or hash drift. Missing files,
malformed responses and network failures fail closed. It never installs or
executes upstream code, changes pins, or updates runtime defaults. Whole upstream
file/archive hashes intentionally require review even for non-identity changes;
an unrelated GitHub commit with identical watched files does not fail.

These are historical compatibility pins, not a claim that current upstream
matches. Initial source research found npm latest versions Claude `2.1.325`,
Codex `0.169.0`, and pi-ai `0.73.1`; online checking should report that drift,
not silently promote the advertised versions. To refresh, inspect the new
upstream artifacts, review the compatibility change, update local code and the
manifest's source hashes/selectors/text together, then run both modes and:

```bash
mix test apps/lemon_ai/test/lemon_ai/upstream_identities_test.exs apps/lemon_ai/test/lemon_ai/auth/anthropic_oauth_test.exs
```

The ExUnit regressions exercise offline mutations and online npm/GitHub drift
logic with in-memory responses; normal tests do not contact upstream services.
The manifest additionally records Claude `2.1.325` SDK Read/Edit/Bash inputs and
the pinned first-party Codex `apply_patch` grammar/spec for the opt-in dialect
experiment. Those source pins do not enable a tool dialect or change its default.

### Codex and Anthropic request controls

Codex accepts a ChatGPT access token through `api_key`, including Lemon's configured
API-key authentication mode. The account header is derived from the URL-safe JWT
claims; an OpenAI API key is not a ChatGPT token. Reuse `session_id` across turns
and resumes: it supplies the prompt-cache key and matching `session_id`,
`conversation_id` and `x-client-request-id` affinity headers. IDs longer than
64 wire bytes become deterministic SHA-256-derived keys; IDs are never truncated
or replaced with a per-request random identity. Native coding sessions supply their
persisted session ID automatically. Provider cache hits appear in `usage.cache_read`;
hits depend on the provider's prefix length, retention and routing, not merely on
sending a key. Sampling temperature and output-token caps are deliberately omitted
because the Codex endpoint rejects them.
Codex sends the same pinned `version: 0.159.0` used for live model discovery;
caller headers cannot accidentally override that capability version. Function
tools explicitly use `strict: false` so optional parameters remain optional rather
than being auto-filled by the endpoint.

For deliberate local diagnostics, `StreamOptions.on_payload` observes the final
request body and `on_usage` observes raw terminal usage, including vendor
`attribution.request_fields`. Both receive only provider/model/session metadata,
have ignored return values, and propagate callback failures as stream errors.
Bodies can contain private content: retain only counts/hashes, never raw payloads
or authentication data. These hooks are disabled by default.

Lemon onboarding can explicitly import an existing Codex CLI ChatGPT login with
`lemon setup --provider openai-codex --auth codex-cli --non-interactive`.
This copies refreshable OAuth credentials into Lemon's encrypted secret store;
it neither refreshes during import nor writes the Codex login file. Import is a
snapshot, not continuous synchronization or a separate browser login. Subsequent
refreshes persist only Lemon's secret, and persistence failure is surfaced rather
than reporting success with lost rotating credentials.

`LemonAi.Auth.OpenAICodexOAuth.login_device_code/1` supports headless sign-in
without a localhost callback. Its optional `:on_device_code` callback receives
only `%{verification_url: url, user_code: code, expires_at_ms: epoch_ms,
poll_interval_ms: milliseconds}`; the URL is exactly
`https://auth.openai.com/codex/device`, never a credential-bearing link. The
device secret and PKCE verifier are not callback metadata. The first and later
polls honor the provider interval plus a three-second margin, bounded to
60 seconds; a larger interval fails closed rather than polling too early.
Grants expire within 15 minutes, and explicit `access_denied`/`expired_token`
responses are terminal even when the endpoint also uses bare 403/404 for pending.
The caller still owns lifecycle cancellation and encrypted credential persistence.

For Responses and Codex, `thinking_budgets: %{summary: "auto", service_tier: "priority"}`
selects reasoning summaries and a service tier (`"auto"`, `"default"`, `"flex"` or
`"priority"` where the model supports it). Codex honors `tool_choice`. Returned
service tiers take precedence for billing; Codex tier multipliers come from model
metadata (for example GPT-6.1 Sol priority is 2.5×). Reasoning output tokens are already
included in the provider's output count, not charged twice.

Native Anthropic requests support `provider_options: %{anthropic: %{cache_retention: :none | :short | :long}}`.
Short-lived caching is the default; `:long` requests the one-hour TTL and `:none`
removes cache markers. Adaptive thinking uses catalog capabilities, and catalog
context limits include current 1M-context Claude models without adding an obsolete
context beta. Provider conversion preserves full history; preflight compaction is
the caller's responsibility rather than silent wire truncation.

### Ordered system prompts (Hex API addition)

`Context.system_prompt` continues to accept a binary or `nil`, and now also accepts
ordered `%{text: binary, directory_derived: boolean}` blocks. This extends the
published `lemon_ai` package API; existing binary callers need no migration.

```elixir
prompt = [
  %{text: "You are a helpful assistant.\n\n", directory_derived: false},
  %{text: "Project directory: /worktrees/example", directory_derived: true}
]

context = LemonAi.new_context(system_prompt: prompt)
text = LemonAi.SystemPrompt.text(prompt)
digest = LemonAi.SystemPrompt.digest(prompt)
```

Put directory-independent blocks first. Anthropic places one system cache marker
on the last non-empty block before the **first** directory-derived block (or the
last block when none is directory-derived). Later non-directory blocks do not
move that boundary. OAuth retains its Claude Code prefix and existing text
sanitization; the prefix itself is cacheable when no other static block exists.
Empty/whitespace-only blocks are omitted from Anthropic requests. With no static
prefix, API-key requests omit the system marker. Together with the last-user
marker this uses at most two of Anthropic's four permitted breakpoints, regardless
of block count. `cache_retention: :none` removes both markers.

Every other transport concatenates the block texts into its existing binary
system-prompt shape, retaining existing provider-specific sanitization, defaults,
and cache controls. **No separator is inserted**: include newlines or spaces in
the block text. `SystemPrompt.text(nil)` returns `""`.

`SystemPrompt.digest/1` returns lowercase SHA-256 of the canonical Erlang external
term `{:system_prompt, 1, [{text, directory_derived}, ...]}`. Text bytes, block order,
boundaries, and directory flags all participate; map key order does not. A binary
normalizes to one directory-independent block, and `nil` normalizes to `[]`.
The digest identifies the supplied prompt, not provider wire transformations or
a guaranteed cache hit. `PromptDiagnostics.stats/1` retains its concatenated-text
byte count and `system_prompt_sha256`, and adds `system_prompt_digest` for this
block-aware identity. Diagnostics still contain no raw prompt text.

The 27 registered provider IDs: `:anthropic`, `:openai`, `:openai_codex`,
`:amazon_bedrock`, `:google`, `:google_antigravity`, `:kimi`, `:kimi_coding`,
`:opencode`, `:opencode_go`, `:xai`, `:mistral`, `:cerebras`, `:deepseek`, `:qwen`,
`:minimax`, `:zai`, `:azure_openai_responses`, `:github_copilot`, `:google_gemini_cli`,
`:google_vertex`, `:groq`, `:huggingface`, `:minimax_cn`, `:fireworks`, `:openrouter`,
`:vercel_ai_gateway`.

Starting with `lemon_ai` 0.2.1, the Codex provider atom is `:openai_codex`
(formerly `:"openai-codex"`). Use the new atom in model lookups, provider
callbacks and persisted Elixir model structs. The wire-protocol API remains
`:openai_codex_responses`; Lemon's `openai-codex` configuration spelling is unchanged.

## What you get beyond raw HTTP

### Circuit breaking

Each provider gets its own circuit breaker (closed → open → half-open), lazily started
the first time you call it. After a run of failures the breaker opens and fails fast
instead of hammering a down provider.

```elixir
config :lemon_ai, :circuit_breaker,
  failure_threshold: 5,       # failures before opening (default: 5)
  recovery_timeout: 30_000    # ms before half-open recovery (default: 30_000)

LemonAi.CircuitBreaker.open?(:anthropic)
LemonAi.CircuitBreaker.reset(:anthropic)
LemonAi.CircuitBreaker.get_state(:anthropic)   # state, failure count, last failure reason
```

Admission/status reads (`open?/1`, `time_until_recovery/1`, `peek/1`) read ETS
snapshots without calling the breaker. `record_success/1`, `record_failure/2` and
`reset/1` still return `:ok`, but now synchronously acknowledge snapshot publication.

### Rate limiting and concurrency caps

A per-provider token bucket plus an in-flight concurrency cap, both enforced by the
dispatcher before the provider is ever called. A caller that finds the provider at its
cap waits in a FIFO queue for a free slot (default up to 120s,
`config :lemon_ai, LemonAi.CallDispatcher, queue_timeout_ms: ...`) before
`{:error, :max_concurrency}` is returned.

Each provider has an independent slot authority. Caps and live leases survive
authority and dispatcher restarts. While an authority is unavailable, admission
**fails closed** with `{:error, :admission_unavailable}` without invoking the
callback; `LemonAi.Error` classifies this as transient. The provider's cap is never
silently bypassed, and other providers can continue admitting calls.
Queued callers interrupted by an authority restart receive the same unavailable
error rather than being implicitly replayed.
These are node-local limits, retained across child-process restarts, not across
application/VM shutdown or shared across multiple nodes.

For Hex consumers, the additional `:admission_unavailable` error also applies to
`set_concurrency_cap/2`, `get_concurrency_cap/1` and `get_active_requests/1`.
`get_state/0` lists unavailable authorities in `:unavailable` rather than reporting
them as idle.

```elixir
config :lemon_ai, :rate_limiter,
  tokens_per_second: 10,   # refill rate (default: 10)
  max_tokens: 20           # bucket capacity (default: 20)

LemonAi.CallDispatcher.set_concurrency_cap(:anthropic, 20)
LemonAi.CallDispatcher.get_active_requests(:anthropic)
```

### Cost tracking

Every model carries pricing, so you can price any response:

```elixir
{:ok, message} = LemonAi.complete(model, context)
cost = LemonAi.calculate_cost(model, message.usage)
# cost.total, cost.input, cost.output, cost.cache_read, cost.cache_write  (US dollars)
```
Input usage excludes cache-read/write tokens; total tokens include them. Hourly
Anthropic writes are reported as `usage.cache_write_long`, a subset of `cache_write`.
The canonical cost calculation includes their higher write price and uses the
catalog's long-context rate when **all** input tokens (including cache) cross its
threshold. Prefer the returned `message.usage.cost` when a service tier was used,
since recalculating base model prices alone does not retain the response's tier.

OpenAI-compatible streams expose finalized request bodies through `on_payload`
and terminal raw Chat Completions usage through `on_usage`, with the configured
provider, model and session ID. Usage-only chunks with `choices: []` are supported.
Observers run in the provider worker; exceptions fail the stream. Bodies contain
private conversation content and must not be logged or persisted.

Missing counters remain `nil`, including absent cache details. Chat prompt counts
include cache reads/writes, so uncached input is only known when both cache
breakdowns are reported. Completion counts already include reasoning; reasoning
is never added a second time. Total tokens are retained from the provider rather
than inferred. Unknown cost components and incomplete total costs remain `nil`,
even at a catalog price of zero. These are nominal catalog costs, not evidence of
subscription charges.

Offline regression fixtures live in `test/fixtures/openai_completions/`.
`zai_usage_only.sse` follows the
[ZAI Chat Completion schema](https://docs.z.ai/api-reference/llm/chat-completion):
prompt 100, cached 20, completion 30, total 130, with cache-write absent.
Consequently uncached input and cache-write remain unknown.
`compatible_complete.sse` deliberately exercises the documented OpenAI-compatible
[usage schema](https://github.com/openai/openai-python/blob/main/src/openai/types/completion_usage.py):
prompt 100, cache-read 20, cache-write 10, completion 30 (including reasoning 12),
total 130; normalized disjoint counters are 70/20/10/30.
It does **not** assert that ZAI emits cache-write or reasoning detail fields.
Both files are synthetic offline fixtures, never captured operator usage.

Replay through the actual provider by setting `Req.default_options(plug: ...)`
to an in-memory Plug transport, supplying an explicit dummy `api_key`, and calling
`OpenAICompletions.stream/3`. Restore the previous Req defaults afterwards.
The provider tests use the existing shared `Req.Test` convention; native runtime
replay can use a Plug function without changing the provider or route.
The catalog's `:zai` / `glm-5.3` route remains
`https://api.z.ai/api/coding/paas/v4/chat/completions`.


### Automatic retries

Providers retry transient failures (429, 529 overloaded, 5xx, connection resets, TLS
hiccups) on the call's own async task, so one slow retry never blocks another caller.
Anthropic, OpenAI Chat Completions, Responses and Codex share one policy: 4 attempts,
exponential backoff with jitter starting around 1s and capped at 30s, and the server's
`retry-after` / `retry-after-ms` / Anthropic `anthropic-ratelimit-*-reset` hint when
present. A server-requested wait longer than `max_retry_after_ms` (60s) is not slept
in-provider; the error message carries it as `AssistantMessage.retry_after_ms` so the
caller can schedule its own retry.

```elixir
config :lemon_ai, :provider_retry,
  max_attempts: 4, base_delay_ms: 1_000, max_delay_ms: 30_000, max_retry_after_ms: 60_000
```
Authentication failures, invalid requests, context overflow and exhausted billing
or subscription quotas are not retried in place. Quota exhaustion remains
`:rate_limit` for credential rotation, but `LemonAi.Error.retryable?/1` returns
`false`; temporary throttling returns `true`. `classify/1` and `retryable?/1` accept
HTTP tuples, parsed error maps, transport failures and terminal assistant messages.
Responses streams that disconnect or time out before a terminal event are errors,
not successful empty/truncated replies. Both CRLF and multiline SSE data are parsed.
Terminal `AssistantMessage.error_details` carries the canonical classification,
retry eligibility, HTTP status and server retry hints; `error_message` is only
display text. Call `Error.retryable?(message)` on the whole terminal message.
Req, Finch and Mint closed/reset/timeout failures retain typed reasons through
Responses parsing and are transient even when their display text is opaque.
Structured metadata survives JSON session persistence without creating atoms
from external category names.
Generic resource exhaustion/throttling remains retryable under the bounded policy;
only explicit account, credit, billing or depleted-quota evidence makes it permanent.
Legacy provider wrappers using status `0` for closed connections classify as
transport failures, not malformed HTTP requests.


### Token estimation

`LemonAi.Tokens` gives fast token *estimates* for budgeting and thresholds:

```elixir
LemonAi.Tokens.estimate_chars("some prompt text")   # ~ String.length / 4
LemonAi.Tokens.estimate_bytes(payload)               # ~ byte_size / 4
```

> **Caveat:** this is a rough **4-characters-per-token heuristic, not a real
> tokenizer.** It will diverge from any model's actual token count and must not be
> trusted for billing or hard context-window limits. Use it for quick thresholds and
> diagnostics only; use `message.usage` (the provider's reported counts) for anything
> that needs to be accurate.

### Actionable, classified errors

`LemonAi.Error` parses provider error bodies into a normalized category and tells you whether
to retry:

```elixir
parsed = LemonAi.Error.parse_http_error(429, response_body, headers)
# parsed.category  => :rate_limit | :auth | :client | :server | :transient
# parsed.retryable => true
# parsed.rate_limit_info.retry_after => merged from headers or body hints

LemonAi.Error.retryable?(:timeout)                          # => true
LemonAi.Error.auth_error?({:http_error, 401, "Unauthorized"})  # => true
LemonAi.Error.suggested_retry_delay({:http_error, 429, _})  # => 60_000
```

It handles the OpenAI/Anthropic map shapes, Google `errors` arrays, FastAPI/Pydantic
`detail` arrays, OAuth `error_description`, and JSON:API `errors` — so you get a useful
message instead of a raw blob, whatever provider you hit.

## Model lookup

```elixir
LemonAi.Models.get_model(:openai, "gpt-6.1-terra")            # provider + id
LemonAi.Models.find_by_id("gemini-4-argon")                   # search all providers by id
LemonAi.Models.get_models(:openai)                          # all models for a provider
LemonAi.Models.get_providers()                              # all known provider atoms
```
The bundled catalogs include GPT-6.1 Terra and Sol, Claude 5.5, Gemini 4 Argon,
and current DeepSeek, Kimi, MiniMax, Qwen, GLM and gateway offerings. Catalogs are
compile-time metadata snapshots, not guarantees that an account or region can
access a model. Unsupported realtime/audio/image-generation protocols are not
advertised through the text coding APIs.

Metadata is checked against [models.dev](https://models.dev/), then provider
documentation for protocol-specific capabilities and billing:
[OpenAI](https://developers.openai.com/api/docs/models/gpt-6.1-terra),
[Google](https://aistudio.google.com/docs/models/gemini-4-argon),
[DeepSeek](https://api-docs.deepseek.com/guides/thinking_mode), and
[Qwen](https://www.alibabacloud.com/help/en/model-studio/deep-thinking).
The current refresh also compares model inventories with the pinned remote
[oh-my-pi catalog](https://github.com/can1357/oh-my-pi/blob/660a31dc33aa93449eb4f569c8cef87033b9f646/packages/catalog/src/models.json)
and [OpenCode catalog](https://github.com/anomalyco/opencode/blob/2658ec02c848ce7e5bd618ee2e18256c5c0992db/packages/core/src/models-dev/snapshot.txt).
Additional entries include `chat-latest`, Robotics ER 2 Preview, Qwen 3.8
variants, GLM-5.3 Highspeed and current Vercel gateway models. Comparisons keep
provider endpoints separate and exclude retired-only entries, client-only free
models, generated batch/mode aliases and unsupported media protocols.
Gateway prices and endpoints follow the gateway, not the underlying vendor.
The cost schema supports one long-context threshold; new entries requiring
multiple thresholds are not added with incomplete prices. DeepSeek's
time-dependent direct and OpenCode Go prices use nominal peak rates. Gemini 4 Argon's
introductory prices apply through November 30, 2026; its published standard
rates are higher afterward.
Robotics ER 2 Preview's catalog rates likewise reflect its current introductory
pricing; the upstream catalog schedules higher text-token rates from January 1, 2027.

Low-level `StreamOptions.reasoning` accepts `:none` and `:max` in addition to
the existing levels. Declared model capabilities clamp unsupported requests.
`:none` disables thinking only where the model's API supports disabling it;
`nil` leaves provider defaults unchanged. DeepSeek's thinking toggle and Qwen's
`enable_thinking` use their native request formats rather than OpenAI's effort
field. OpenCode Go requests identify Lemon and retain a stable conversation
session header.
Existing integration exclusions remain in effect even when the reference catalog
still lists an old preview: Vertex's `gemini-3-flash-preview`, `gemini-3-pro-preview`
and `gemini-3.1-pro-preview` are not advertised by Lemon.

Lemon's runtime model picker uses account-scoped Codex discovery, not every
bundled Codex SKU. The ChatGPT `/codex/models?client_version=0.159.0` result is
cached for five minutes by account and endpoint; tokens, account identifiers and
login files are not stored in that cache. Refreshing the picker may explicitly
bypass the cache (`models.list` with `forceRefresh: true`). A discovery failure
does not advertise unverified Codex models. Known hidden models remain usable
when the account advertises support; `visibility` is not an authorization flag.

```elixir
LemonAi.Models.list_models(
  discover_codex: true,
  codex_access_token: concrete_chatgpt_token
)
```

Runtime role selectors (`@smol`, `@slow`, custom roles) are checked against the
same account cache once a concrete ChatGPT credential is available. Unsupported
roles fail before submitting a model request and identify the role, rejected
model and supported alternatives; change `[model_roles]` or choose a model from
the picker. Static registry lookups remain network-free for metadata and tests.


You can also skip the registry entirely and hand-build a `%LemonAi.Types.Model{}` — the
registry is a convenience, not a requirement.

## Configuration reference

```elixir
config :lemon_ai, LemonAi.CallDispatcher,
  stream_idle_timeout: 300_000,      # silence between provider events
  stream_timeout: 1_800_000          # independent hard response ceiling
```

The dispatcher uses the stream's own timers rather than imposing another
absolute deadline. These settings replace `stream_result_timeout_ms`; explicit
per-request options take precedence. Both accept `:infinity`.

Direct providers and dispatched calls use the same limits: every event, including
thinking, text and tool-argument deltas, resets the idle window. Idle cancellation
is `:stream_idle_timeout` (direct) or `:dispatcher_stream_idle_timeout` (dispatched).
The hard ceiling never resets; its reasons remain `:timeout` and
`:dispatcher_stream_timeout`.

`LemonAi.ModelCache` caches provider `GET /models` availability with a configurable TTL
(default 5 minutes). Its supervised process owns the ETS table; caller exits do not
discard entries, while restarting the owner creates an empty cache.

## Key types

All defined in `LemonAi.Types`:

```elixir
%LemonAi.Types.Model{
  id: String.t(),
  name: String.t(),
  api: atom(),               # must match a registered api_id
  provider: atom(),          # keyed for circuit breaker / rate limiter
  base_url: String.t(),
  reasoning: boolean(),
  adaptive_thinking: boolean(),  # Anthropic adaptive thinking + effort
  reasoning_efforts: [:none | :minimal | :low | :medium | :high | :xhigh | :max],  # [] = undeclared
  input: [:text | :image],
  cost: %LemonAi.Types.ModelCost{input: float(), output: float()},
  context_window: non_neg_integer(),
  max_tokens: non_neg_integer(),
  headers: map(),
  compat: map() | nil
}

%LemonAi.Types.StreamOptions{
  temperature: float() | nil,
  max_tokens: non_neg_integer() | nil,
  api_key: String.t() | nil,
  headers: map(),
  reasoning: :none | :minimal | :low | :medium | :high | :xhigh | :max | nil,
  stream_timeout: timeout(),        # hard ceiling; default 1_800_000ms
  stream_idle_timeout: timeout(),   # silence window; default 300_000ms
  tool_choice: atom() | String.t() | nil
  # ...plus Vertex/OAuth fields: project, location, access_token, service_account_json
}

%LemonAi.Types.Context{
  system_prompt: LemonAi.SystemPrompt.t(),  # binary | ordered blocks | nil
  messages: [message()],       # stored newest-first for O(1) append
  tools: [Tool.t()]
}
```

> `Context.messages` is stored reversed (newest first). Use
> `LemonAi.Types.Context.get_messages_chronological/1` when passing to an API directly.

`LemonAi.ImageInputs.validate/1` validates the JSON image block array
`[{"type":"image","mime_type":"image/png","data":"<canonical Base64>"}]`
into `ImageContent` structs. `encode/1` accepts only those known native structs
and produces the same wire format after validation; arbitrary structs and
executable fields are never serialized. Both enforce at most five PNG/JPEG/GIF/
WebP images totaling 10 MiB decoded, strict standard Base64 and matching MIME
headers. This input validation does not grant vision capability to a text-only
model.

## Streaming event types

Events emitted by `LemonAi.EventStream`:

```elixir
{:start, message}
{:text_start, idx}
{:text_delta, idx, delta}
{:text_end, idx, text}
{:thinking_start, idx}
{:thinking_delta, idx, delta}
{:thinking_end, idx, thinking}
{:tool_call_start, idx, tool_call}
{:tool_call_delta, idx, json_fragment}
{:tool_call_end, idx, tool_call}
{:done, stop_reason, message}
{:error, stop_reason, message}
{:canceled, reason}
```

`stop_reason` is one of `:stop | :length | :tool_use | :error | :aborted`.

## Architecture

Every call flows through a dispatcher that checks the circuit breaker, acquires a
rate-limit permit, and enforces the concurrency cap before invoking the provider.
Streaming responses come back through an `LemonAi.EventStream` GenServer with a bounded
queue, backpressure, owner monitoring, and timeouts.

This is also the implementation behind the published `LemonAgent.EventStream`
facade; there is only one queue/lifecycle implementation. Provider completion
uses `{:done, stop_reason, message}`, while list completion uses
`{:agent_end, messages}`. `error/2` retains provider message results and `error/3`
retains agent reason/partial-state results. Runner monitoring and `:resync`
overflow fencing are supported alongside owner monitoring and result subscriptions.

Synchronous `push/2` waits without a call timeout and returns
`:ok | {:error, :overflow | :canceled}`; callers must handle rejection.
`push!/2` finishes overflow with a terminal error and throws
`{:event_stream_push_failed, reason}` to an explicit producer failure boundary.
Async pushes retain their documented drop policy.

The phase-2 direct-mailbox replacement is not implemented. The opt-in benchmark
under `apps/lemon_ai/bench` compares one/two queue hops with a direct-send baseline.
Record measurements and the #546 context before choosing a replacement; no
latency gain or phase-2 decision is claimed by consolidation alone.

```bash
LEMON_EVENT_STREAM_BENCH=1 LEMON_BENCH_REVISION=<revision> MIX_ENV=test \
  mix run --no-start apps/lemon_ai/bench/event_stream.exs
```

The benchmark prints runtime metadata and p50/p95 batch and per-event costs.
Its direct-send baseline deliberately does not implement the lifecycle contract.

```
LemonAi.stream/3  or  LemonAi.complete/3
  → LemonAi.ProviderRegistry          -- O(1) :persistent_term lookup by api_id
  → LemonAi.CallDispatcher.dispatch/2 -- circuit breaker + rate limiter + concurrency cap
  → LemonAi.Provider.stream/3         -- provider behaviour callback
  → LemonAi.EventStream               -- async delivery, backpressure, cancellation
```

Supervision tree:

```
LemonAi.Supervisor (one_for_one; owns the retained slot lease/cap ETS table)
  ├── Task.Supervisor (LemonAi.StreamTaskSupervisor)
  ├── Registry (LemonAi.RateLimiterRegistry)
  ├── Registry (LemonAi.CircuitBreakerRegistry)
  ├── Registry (LemonAi.CallDispatcherRegistry)
  ├── DynamicSupervisor (LemonAi.ProviderSupervisor) -- per-provider breakers/limiters/slots
  ├── LemonAi.CallDispatcher -- provider failure summaries
  ├── LemonAi.ModelCache -- model availability ETS owner
  ├── LemonAi.Auth.Cache -- token and fingerprint ETS owner
  └── LemonAi.Auth.OmpAuthBroker -- broker snapshot ETS owner and watchers
```

`LemonAi.ProviderRegistry` lives outside the tree in `:persistent_term`, so provider
mappings survive process restarts. Only explicit boot/configuration registration
updates this map; request-path lookups never initialize or mutate it.

Mutable and lazily discovered auth values live in `LemonAi.Auth.Cache`, not
`:persistent_term`: omp access tokens retain their expiry/forced-refresh rules,
Claude Code versions are cached per `PATH`, and Kimi CLI fingerprint headers are
cached for the owner's lifetime. Reads and writes access ETS directly. Caller exits
leave entries intact; an owner restart discards them for rediscovery. Before startup
or during a restart, auth adapters resolve values without caching rather than creating
a caller-owned table. This cache never stores omp refresh credentials.

## Adding a provider

Implement the `LemonAi.Provider` behaviour (`stream/3`, `provider_id/0`, `api_id/0`, and
optionally `get_env_api_key/0`), add a catalog file under `priv/models/` with a
`LemonAi.Models.*` module that loads it, add any new API/provider value to the
explicit allowlist in `LemonAi.Models.Catalog`, and register the module in
`LemonAi.Application`:

```elixir
LemonAi.ProviderRegistry.register(:my_provider_api, LemonAi.Providers.MyProvider)
```

Inside `stream/3` you start an `LemonAi.EventStream`, run the HTTP request in a supervised
task, and push events (`LemonAi.EventStream.push_async/2`) until you complete or error the
stream. See any module under `lib/ai/providers/` for the pattern.

## Authentication and OAuth

Most providers authenticate with a bearer key from options or the environment. Providers
that require OAuth (Anthropic Claude Pro/Max, GitHub Copilot, Google Gemini CLI, OpenAI
Codex, Google Antigravity, Kimi Code and xAI) have helpers under `LemonAi.Auth.*` for
device-code / PKCE flows and token refresh. Callers own encrypted storage through
revision-aware callbacks:

- When `:persist_secret` is configured, `:reload_secret` must be an arity-one callback
  returning `{:ok, encoded, revision}`, with an opaque storage revision. Missing
  callbacks or value-only `{:ok, encoded}` results fail with
  `{:error, :oauth_secret_reload_failed}` before the refresh HTTP request.
- `persist_secret.(name, new_encoded, expected_revision)` must atomically compare the
  revision and store the refreshed payload. Only `:ok` or `{:ok, metadata}` acknowledges
  success. `{:error, :stale_revision}` becomes `{:error, :oauth_secret_changed}`; other
  failures, malformed acknowledgements and callback exceptions become
  `{:error, :oauth_secret_persistence_failed}`.

Refreshes are single-flight per secret on the local node. The reload captures the
revision under the lock before the HTTP refresh, and persistence compares that same
revision. A login replaced or deleted during refresh is never overwritten or recreated,
and the stale refreshed key is not returned. Storage revisions must also change on
login replacement and deletion, including deletion followed by recreating identical
credentials. A transient refresh failure re-reads storage before selecting an unexpired
fallback; a forced refresh never reuses the rejected token. Missing or unreadable
storage fails closed.

Copilot token-endpoint HTTP 401/403 responses are terminal
`{:error, :reauth_required}` failures: even a still-valid cached token is not returned.
Other transient failures retain the reload-based unexpired fallback.

Standalone callers that omit `:persist_secret` may still refresh ephemerally without
a reload callback, or with a value-only `{:ok, encoded}` reload result. These modes do
not provide durable revision guarantees. In a Lemon runtime, inject
`LemonCore.Secrets.get_with_revision/2` with environment fallback disabled and
`LemonCore.Secrets.set_if_revision/4` with the returned revision.

The ambient exception is `LemonAi.Auth.AnthropicOAuth.resolve_access_token/0`, which
reads Claude Code credentials and writes a refresh it performs back to
`~/.claude/.credentials.json` so Claude Code's rotated login stays valid; this file path
does not use the stored-secret callbacks.

Common environment variables (used as a standalone fallback when a key isn't passed in
options):

| Variable | Provider |
|----------|----------|
| `ANTHROPIC_API_KEY` | Anthropic (and Kimi/OpenCode/MiniMax compat) |
| `OPENAI_API_KEY` | OpenAI family |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google AI Studio (also `GOOGLE_API_KEY`, `GEMINI_API_KEY`) |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_REGION` | Bedrock |

Debug/diagnostic toggles: `LEMON_AI_HTTP_TRACE=1` (HTTP trace logging),
`LEMON_AI_PROMPT_DIAGNOSTICS=1` (prompt size/token diagnostics), `LEMON_AI_DEBUG=1`
(raw Anthropic SSE logging).

## Testing

```bash
mix test apps/lemon_ai                                    # from umbrella root
mix test apps/lemon_ai/test/lemon_ai/circuit_breaker_test.exs   # one file
mix test apps/lemon_ai/test/integration --include integration  # needs API keys
```

HTTP is mocked with `Req.Test` stubs; see `test/providers/` for patterns.

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `req ~> 0.5` | HTTP client with streaming support |
| `websockex ~> 0.5` | Opt-in session-owned Responses WebSocket client |
| `jason ~> 1.4` | JSON encoding/decoding |
| `nimble_options ~> 1.1` | Options validation |
| `plug ~> 1.16` (test only) | `Req.Test` stubs |

## Used by

`lemon_ai` is the LLM layer of the [Lemon](https://github.com/z80dev/lemon) agent
platform, where it drives long-running agents across every provider above. It has zero
dependency on the rest of that platform and is designed to be used entirely on its own.

## License

MIT.
