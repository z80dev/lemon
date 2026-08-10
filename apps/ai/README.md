# lemon_ai

A provider-agnostic LLM client for Elixir. Call **27 model providers** — Anthropic,
OpenAI, Google, AWS Bedrock, Azure, Groq, Mistral, xAI, DeepSeek, OpenRouter, and more —
through **one streaming API**, with a built-in model registry, per-provider circuit
breaking and rate limiting, and cost accounting. No web framework, no umbrella, no
runtime dependencies beyond [`req`](https://hex.pm/packages/req),
[`jason`](https://hex.pm/packages/jason), and
[`nimble_options`](https://hex.pm/packages/nimble_options).

The whole surface is `Ai.stream/3` and `Ai.complete/3` plus a handful of helpers. Point
a `%Ai.Types.Model{}` at any provider and the rest of your code stays identical.

## Install

`lemon_ai` is not yet on Hex. Add it as a git dependency for now:

```elixir
def deps do
  [
    {:lemon_ai, github: "z80dev/lemon", sparse: "apps/ai"}
  ]
end
```

Once published, this becomes:

```elixir
{:lemon_ai, "~> 0.1"}
```

The OTP application is named `:ai`, so you call it as `Ai.*`. It starts its own
supervision tree (circuit breakers, rate limiters, the model cache) automatically.

## Quickstart

Set the API key for whichever provider you want (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GOOGLE_GENERATIVE_AI_API_KEY`, …) and make a blocking call:

```elixir
model = Ai.Models.get_model(:anthropic, "claude-haiku-4-5")

context =
  Ai.new_context(system_prompt: "You are a helpful assistant.")
  |> Ai.Types.Context.add_user_message("Explain OTP supervision in two sentences.")

{:ok, message} = Ai.complete(model, context)

IO.puts(Ai.get_text(message))
```

Switch providers by changing one line — the context, options, and result handling are
identical:

```elixir
model = Ai.Models.get_model(:openai, "gpt-4o")
model = Ai.Models.get_model(:google, "gemini-2.5-pro")
model = Ai.Models.get_model(:groq, "llama-3.3-70b-versatile")
```

The API key resolves in this order: `opts.api_key` you pass in →
provider-specific env var (e.g. `ANTHROPIC_API_KEY`) → generic fallback. So you can pass
keys explicitly or rely on the environment.

## Streaming

`Ai.stream/3` returns an `Ai.EventStream` you consume as a lazy stream of events:

```elixir
{:ok, stream} = Ai.stream(model, context, %{temperature: 0.7, reasoning: :medium})

stream
|> Ai.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta, _partial} -> IO.write(delta)
  {:thinking_delta, _idx, delta, _partial} -> IO.write([IO.ANSI.faint(), delta, IO.ANSI.reset()])
  {:done, _reason, _message} -> IO.puts("\n-- done --")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)
```

Convenience helpers on the stream:

```elixir
text            = Ai.EventStream.collect_text(stream)   # blocking, returns full text
{:ok, message}  = Ai.EventStream.result(stream)         # blocking, returns final message
%{queue_size: _, dropped: _} = Ai.EventStream.stats(stream)
Ai.EventStream.cancel(stream, :user_requested)
```

`Ai.complete/3` is just `stream/3` + `EventStream.result/1` collected for you.

## Tool use

```elixir
tools = [
  %Ai.Types.Tool{
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
  Ai.new_context(system_prompt: "You can check weather.", tools: tools)
  |> Ai.Types.Context.add_user_message("Weather in Paris?")

{:ok, message} = Ai.complete(model, context)

for tc <- Ai.get_tool_calls(message) do
  result = %Ai.Types.ToolResultMessage{
    tool_call_id: tc.id,
    tool_name: tc.name,
    content: [%Ai.Types.TextContent{text: "Sunny, 22C"}],
    is_error: false
  }

  context =
    context
    |> Ai.Types.Context.add_assistant_message(message)
    |> Ai.Types.Context.add_tool_result(result)

  {:ok, final} = Ai.complete(model, context)
  IO.puts(Ai.get_text(final))
end
```

## Provider capability matrix

Every provider is reached through one of **10 wire-protocol modules**. The 27 provider
catalogs in `Ai.Models` route through these — for example Groq, xAI, DeepSeek, Qwen,
Cerebras, OpenRouter, Vercel AI Gateway, HuggingFace, Fireworks, and Mistral's catalog
all speak the OpenAI Chat Completions format, so they inherit its capabilities.

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
accept images. Query the specific model:

```elixir
Ai.Models.supports_vision?(model)
Ai.Models.supports_reasoning?(model)
Ai.Models.supports_xhigh(model)
```

The 27 provider catalogs: `:anthropic`, `:openai`, `:"openai-codex"`,
`:amazon_bedrock`, `:google`, `:google_antigravity`, `:kimi`, `:kimi_coding`,
`:opencode`, `:opencode_go`, `:xai`, `:mistral`, `:cerebras`, `:deepseek`, `:qwen`,
`:minimax`, `:zai`, `:azure_openai_responses`, `:github_copilot`, `:google_gemini_cli`,
`:google_vertex`, `:groq`, `:huggingface`, `:minimax_cn`, `:fireworks`, `:openrouter`,
`:vercel_ai_gateway`.

## What you get beyond raw HTTP

### Circuit breaking

Each provider gets its own circuit breaker (closed → open → half-open), lazily started
the first time you call it. After a run of failures the breaker opens and fails fast
instead of hammering a down provider.

```elixir
config :ai, :circuit_breaker,
  failure_threshold: 5,       # failures before opening (default: 5)
  recovery_timeout: 30_000    # ms before half-open recovery (default: 30_000)

Ai.CircuitBreaker.open?(:anthropic)
Ai.CircuitBreaker.reset(:anthropic)
Ai.CircuitBreaker.get_state(:anthropic)   # state, failure count, last failure reason
```

### Rate limiting and concurrency caps

A per-provider token bucket plus an in-flight concurrency cap, both enforced by the
dispatcher before the provider is ever called.

```elixir
config :ai, :rate_limiter,
  tokens_per_second: 10,   # refill rate (default: 10)
  max_tokens: 20           # bucket capacity (default: 20)

Ai.CallDispatcher.set_concurrency_cap(:anthropic, 20)
Ai.CallDispatcher.get_active_requests(:anthropic)
```

### Cost tracking

Every model carries pricing, so you can price any response:

```elixir
{:ok, message} = Ai.complete(model, context)
cost = Ai.calculate_cost(model, message.usage)
# cost.total, cost.input, cost.output, cost.cache_read, cost.cache_write  (US dollars)
```

### Automatic retries

Providers retry transient failures (429, 5xx, connection resets, TLS hiccups) on the
call's own async task with exponential backoff + jitter, honoring `retry-after` headers
when present. Retries are bounded — 2 for Anthropic, 3 for the OpenAI family — and each
request retries in isolation, so one slow retry never blocks another caller.

### Context compaction

`Ai.CompactingClient` wraps a call and, on a `ContextLengthExceeded` error,
automatically compacts the conversation and retries instead of failing outright.

### Token estimation

`Ai.Tokens` gives fast token *estimates* for budgeting and thresholds:

```elixir
Ai.Tokens.estimate_chars("some prompt text")   # ~ String.length / 4
Ai.Tokens.estimate_bytes(payload)               # ~ byte_size / 4
```

> **Caveat:** this is a rough **4-characters-per-token heuristic, not a real
> tokenizer.** It will diverge from any model's actual token count and must not be
> trusted for billing or hard context-window limits. Use it for quick thresholds and
> diagnostics only; use `message.usage` (the provider's reported counts) for anything
> that needs to be accurate.

### Actionable, classified errors

`Ai.Error` parses provider error bodies into a normalized category and tells you whether
to retry:

```elixir
parsed = Ai.Error.parse_http_error(429, response_body, headers)
# parsed.category  => :rate_limit | :auth | :client | :server | :transient
# parsed.retryable => true
# parsed.rate_limit_info.retry_after => merged from headers or body hints

Ai.Error.retryable?(:timeout)                          # => true
Ai.Error.auth_error?({:http_error, 401, "Unauthorized"})  # => true
Ai.Error.suggested_retry_delay({:http_error, 429, _})  # => 60_000
```

It handles the OpenAI/Anthropic map shapes, Google `errors` arrays, FastAPI/Pydantic
`detail` arrays, OAuth `error_description`, and JSON:API `errors` — so you get a useful
message instead of a raw blob, whatever provider you hit.

## Model lookup

```elixir
Ai.Models.get_model(:anthropic, "claude-haiku-4-5")  # provider + id
Ai.Models.find_by_id("gpt-4o")                         # search all providers by id
Ai.Models.get_models(:openai)                          # all models for a provider
Ai.Models.get_providers()                              # all known provider atoms
```

You can also skip the registry entirely and hand-build a `%Ai.Types.Model{}` — the
registry is a convenience, not a requirement.

## Configuration reference

```elixir
config :ai, Ai.CallDispatcher,
  stream_result_timeout_ms: 300_000   # how long the dispatcher tracks a stream's result
```

`Ai.ModelCache` caches provider `GET /models` availability with a configurable TTL
(default 5 minutes).

## Key types

All defined in `Ai.Types`:

```elixir
%Ai.Types.Model{
  id: String.t(),
  name: String.t(),
  api: atom(),               # must match a registered api_id
  provider: atom(),          # keyed for circuit breaker / rate limiter
  base_url: String.t(),
  reasoning: boolean(),
  input: [:text | :image],
  cost: %Ai.Types.ModelCost{input: float(), output: float()},
  context_window: non_neg_integer(),
  max_tokens: non_neg_integer(),
  headers: map(),
  compat: map() | nil
}

%Ai.Types.StreamOptions{
  temperature: float() | nil,
  max_tokens: non_neg_integer() | nil,
  api_key: String.t() | nil,
  headers: map(),
  reasoning: :minimal | :low | :medium | :high | :xhigh | nil,
  stream_timeout: timeout(),        # default 300_000ms
  tool_choice: atom() | String.t() | nil
  # ...plus Vertex/OAuth fields: project, location, access_token, service_account_json
}

%Ai.Types.Context{
  system_prompt: String.t() | nil,
  messages: [message()],       # stored newest-first for O(1) append
  tools: [Tool.t()]
}
```

> `Context.messages` is stored reversed (newest first). Use
> `Ai.Types.Context.get_messages_chronological/1` when passing to an API directly.

## Streaming event types

Events emitted by `Ai.EventStream`:

```elixir
{:start, message}
{:text_start, idx, message}
{:text_delta, idx, delta, message}
{:text_end, idx, text, message}
{:thinking_start | :thinking_delta | :thinking_end, idx, ..., message}
{:tool_call_start, idx, message}
{:tool_call_delta, idx, json_fragment, message}
{:tool_call_end, idx, tool_call, message}
{:done, stop_reason, message}
{:error, stop_reason, message}
{:canceled, reason}
```

`stop_reason` is one of `:stop | :length | :tool_use | :error | :aborted`.

## Architecture

Every call flows through a dispatcher that checks the circuit breaker, acquires a
rate-limit permit, and enforces the concurrency cap before invoking the provider.
Streaming responses come back through an `Ai.EventStream` GenServer with a bounded
queue, backpressure, owner monitoring, and timeouts.

```
Ai.stream/3  or  Ai.complete/3
  → Ai.ProviderRegistry          -- O(1) :persistent_term lookup by api_id
  → Ai.CallDispatcher.dispatch/2 -- circuit breaker + rate limiter + concurrency cap
  → Ai.Provider.stream/3         -- provider behaviour callback
  → Ai.EventStream               -- async delivery, backpressure, cancellation
```

Supervision tree:

```
Ai.Supervisor (one_for_one)
  ├── Task.Supervisor (Ai.StreamTaskSupervisor)
  ├── Registry (Ai.RateLimiterRegistry)
  ├── Registry (Ai.CircuitBreakerRegistry)
  ├── Ai.ProviderSupervisor  -- DynamicSupervisor for per-provider breakers/limiters
  ├── Ai.CallDispatcher
  └── Ai.ModelCache
```

`Ai.ProviderRegistry` lives outside the tree in `:persistent_term`, so provider
mappings survive process restarts.

## Adding a provider

Implement the `Ai.Provider` behaviour (`stream/3`, `provider_id/0`, `api_id/0`, and
optionally `get_env_api_key/0`), add a model catalog under `Ai.Models.*`, and register
the module in `Ai.Application`:

```elixir
Ai.ProviderRegistry.register(:my_provider_api, Ai.Providers.MyProvider)
```

Inside `stream/3` you start an `Ai.EventStream`, run the HTTP request in a supervised
task, and push events (`Ai.EventStream.push_async/2`) until you complete or error the
stream. See any module under `lib/ai/providers/` for the pattern.

## Authentication and OAuth

Most providers authenticate with a bearer key from options or the environment. Providers
that require OAuth (GitHub Copilot, Google Gemini CLI, OpenAI Codex, Google Antigravity)
have helpers under `Ai.Auth.*` for the device-code / PKCE flows and token refresh. These
are protocol helpers only — they do not read or write any external app's secret store.

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
mix test apps/ai                                    # from umbrella root
mix test apps/ai/test/ai/circuit_breaker_test.exs   # one file
mix test apps/ai/test/integration --include integration  # needs API keys
```

HTTP is mocked with `Req.Test` stubs; see `test/providers/` for patterns.

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `req ~> 0.5` | HTTP client with streaming support |
| `jason ~> 1.4` | JSON encoding/decoding |
| `nimble_options ~> 1.1` | Options validation |
| `plug ~> 1.16` (test only) | `Req.Test` stubs |

## Used by

`lemon_ai` is the LLM layer of the [Lemon](https://github.com/z80dev/lemon) agent
platform, where it drives long-running agents across every provider above. It has zero
dependency on the rest of that platform and is designed to be used entirely on its own.

## License

MIT.
