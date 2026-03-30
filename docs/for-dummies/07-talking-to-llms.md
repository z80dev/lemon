# Part 7: Talking to LLMs (ai)

[< The Agent](06-the-agent.md) | [Next: The Foundation >](08-the-foundation.md)

---

The `ai` package is Lemon's universal translator for talking to AI models. It
doesn't matter whether you're using Claude, GPT, Gemini, or a model from one
of 25+ providers — the rest of Lemon calls the same two functions and gets the
same format back.

Think of it as a power strip: you plug in any AI provider, and the outlet looks
the same.

---

## The Two Functions

The entire public API boils down to:

- **`Ai.stream(model, context, opts)`** — start a streaming AI call, get back
  an event stream
- **`Ai.complete(model, context, opts)`** — blocking wrapper: calls `stream`,
  then waits for the complete response

Everything else in the `ai` package exists to support these two functions.

---

## Models: The Menu

Lemon knows about 200+ models across 25+ providers. Each model is defined as a
data structure with:

```
id:           "claude-sonnet-4-20250514"
name:         "Claude Sonnet 4"
provider:     :anthropic
api:          :anthropic_messages        ← which wire protocol to use
context_window: 200_000                  ← max input tokens
max_tokens:   8_192                      ← max output tokens
reasoning:    true                       ← supports extended thinking?
cost:         input: $3/M, output: $15/M ← pricing per million tokens
```

### Supported Providers

The "big five" providers each have their own wire protocol implementation:

| Provider | Wire Protocol | Examples |
|----------|--------------|----------|
| **Anthropic** | Messages API + SSE | Claude Opus, Sonnet, Haiku |
| **OpenAI** | Chat Completions or Responses API | GPT-4o, o1, o3 |
| **Google** | Generative AI REST | Gemini 2.5 Pro, Flash |
| **Azure** | Azure OpenAI Responses API | Azure-hosted OpenAI models |
| **AWS Bedrock** | Converse Stream API | Bedrock-hosted Claude, etc. |

Many additional providers reuse the OpenAI-compatible protocol: Groq, Mistral,
xAI, Cerebras, DeepSeek, Qwen, MiniMax, Kimi, OpenRouter, GitHub Copilot,
HuggingFace, and others. Adding a new OpenAI-compatible provider costs zero
lines of HTTP code — just model definitions.

### How a Model Is Selected

When you configure Lemon with a model like `"anthropic:claude-sonnet-4-20250514"`:

1. The model ID is looked up in the model registry → returns a `Model` struct
2. The `Model.api` field (e.g., `:anthropic_messages`) identifies the wire
   protocol
3. The `ProviderRegistry` maps that API ID to the provider module
4. That module's `stream/3` function is called

```
"anthropic:claude-sonnet-4-20250514"
    → Model{api: :anthropic_messages}
        → ProviderRegistry.get(:anthropic_messages)
            → Ai.Providers.Anthropic
                → Anthropic.stream(model, context, opts)
```

---

## How a Call Works

Here's what happens inside `Ai.stream/3`:

### 1. Dispatch

The `CallDispatcher` wraps every AI call with reliability features:

```
Ai.stream(model, context, opts)
    │
    ▼
CallDispatcher.dispatch(provider_id, fn ->
    │
    ├── Check circuit breaker ── is this provider currently failing?
    ├── Acquire concurrency slot ── max 10 concurrent calls per provider
    ├── Acquire rate limit token ── token bucket (10/sec per provider)
    ├── Call provider.stream(model, context, opts)
    └── Start background task to track stream outcome
end)
```

### 2. The Provider Builds the Request

Each provider module converts Lemon's universal `Context` into the provider's
specific JSON format. For example, Anthropic needs:

```json
{
  "model": "claude-sonnet-4-20250514",
  "system": "You are a personal assistant...",
  "messages": [
    {"role": "user", "content": "What files are in my home directory?"},
    {"role": "assistant", "content": "...", "tool_use": [...]},
    {"role": "user", "content": [{"type": "tool_result", ...}]}
  ],
  "tools": [...],
  "max_tokens": 8192,
  "stream": true
}
```

OpenAI, Google, and Bedrock each have their own format, but the conversion is
handled internally.

### 3. Streaming HTTP Request

The provider fires an HTTP request using `Req` (Elixir's HTTP library) with
streaming enabled. As the response arrives in chunks (Server-Sent Events for
Anthropic/OpenAI, chunked JSON for Google), the provider parses each chunk and
pushes typed events into an `EventStream`:

```
HTTP SSE chunks → Provider parser → EventStream GenServer → Consumer
```

### 4. The EventStream

The `EventStream` is a GenServer that acts as a bounded FIFO queue between the
HTTP response and the consumer (agent_core's Loop):

- **Bounded:** Default 10,000 event capacity (backpressure if full)
- **Owner-monitored:** If the consumer dies, the stream auto-cancels
- **Timeout-protected:** Default 300 seconds before giving up
- **Lazy consumption:** The consumer reads events via a `Stream.resource`
  that blocks until events are available

### 5. Events Produced

A typical streaming AI call produces these events:

```
{:message_start}          ← response is beginning
{:content_start, 0}       ← first content block starting
{:content_delta, 0, "Here"}    ← token
{:content_delta, 0, " is"}     ← token
{:content_delta, 0, " the"}    ← token
...
{:content_end, 0}         ← first content block done
{:tool_call_start, 1, %ToolCall{name: "bash", ...}}  ← tool call (if any)
{:tool_call_delta, 1, input_json_chunk}
{:tool_call_end, 1, ...}
{:message_end}            ← response is complete
{:done, %AssistantMessage{...}}  ← final message with full text + usage
```

---

## The Context

The `Context` is the complete package sent to the LLM:

```
%Ai.Types.Context{
  system_prompt: "You are a personal assistant...",
  messages: [
    %UserMessage{content: "What files are in my home directory?"},
    %AssistantMessage{content: "...", tool_calls: [...]},
    %ToolResultMessage{tool_call_id: "...", content: "..."},
    ...
  ],
  tools: [
    %Tool{name: "bash", description: "Run a shell command", parameters: %{...}},
    %Tool{name: "read", description: "Read a file", parameters: %{...}},
    ...
  ]
}
```

The context grows with each turn of conversation. Previous messages are
included so the AI has the full history. Tools are defined as JSON Schema
objects so the AI knows what parameters each tool accepts.

---

## Reliability Features

### Circuit Breaker

Each provider has its own circuit breaker (the standard closed/open/half-open
pattern):

- **Closed** (normal): calls go through
- **Open** (broken): calls are rejected immediately (fast-fail) — triggered
  after 5 consecutive failures
- **Half-open** (testing): lets a few calls through to see if the provider has
  recovered — requires 2 successes to close

Only 5xx errors and network failures count as failures. 4xx errors (bad
request, auth, etc.) do not trip the circuit breaker because they indicate a
caller problem, not a provider problem.

### Rate Limiter

A token-bucket rate limiter prevents overwhelming providers:
- Default: 10 tokens per second, bucket capacity 20
- One rate limiter per provider (not per model)
- Lazy-started on first use

### Concurrency Cap

Each provider has a default maximum of 10 concurrent in-flight requests. This
prevents resource exhaustion and respects provider rate limits.

### Error Classification

When an HTTP error occurs, `Ai.Error` classifies it:

| Category | Examples | Retry? |
|----------|---------|--------|
| `:rate_limit` | 429 Too Many Requests | Yes, after `retry_after` |
| `:auth` | 401 Unauthorized | No |
| `:client` | 400 Bad Request | No |
| `:server` | 500, 502, 503 | Yes, with backoff |
| `:transient` | Network timeout, connection refused | Yes, with backoff |

---

## Extended Thinking

Some models (Claude, certain OpenAI models) support **extended thinking** —
giving the AI a "scratchpad" to reason through complex problems before
responding.

Lemon exposes this through thinking levels:

| Level | Budget Tokens | When to Use |
|-------|--------------|-------------|
| `:off` | 0 | Simple queries, fast responses |
| `:minimal` | 1,024 | Light reasoning |
| `:low` | 4,096 | Moderate reasoning |
| `:medium` | 10,000 | Complex problems (default when enabled) |
| `:high` | 32,000 | Very complex reasoning |
| `:xhigh` | 64,000 | Maximum reasoning depth |

For Anthropic, this translates to the `"thinking"` field in the API request.
The thinking content is captured in the response but typically not shown to the
user — only the final answer is.

---

## Token Tracking and Cost

Every AI response includes **usage** data:

```
%Usage{
  input: 1500,        ← input tokens consumed
  output: 250,        ← output tokens generated
  cache_read: 1200,   ← tokens served from cache (cheaper)
  cache_write: 300,   ← tokens written to cache
  total_tokens: 1750,
  cost: %Cost{
    input: 0.0045,    ← dollars
    output: 0.00375,
    total: 0.00825
  }
}
```

Cost is calculated using each model's published pricing (per million tokens).
The `BudgetTracker` in coding_agent uses this data to enforce per-run budgets.

### Prompt Caching

For Anthropic models, the `ai` package automatically adds cache control hints
to the system prompt and the last user message. This means repeated calls with
the same system prompt (which is most calls in a session) can reuse cached
tokens at a lower cost. Cache read tokens are ~10x cheaper than regular input
tokens.

---

## API Key Resolution

Getting the right API key is surprisingly complex because Lemon supports
multiple sources:

```
1. Environment variable (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.)
    ↓ if not set
2. Plain text in config.toml (providers.anthropic.api_key)
    ↓ if not set
3. Encrypted secret in LemonCore.Secrets (via secret_ref in config)
    ↓ if not set
4. Default secret name convention (`llm_<provider>_api_key`, except Anthropic raw API keys use `llm_anthropic_api_key_raw`)
    ↓ if not set
5. OAuth token (for Anthropic Claude Code, GitHub Copilot, Google Gemini CLI, OpenAI Codex)
```

OAuth tokens are automatically refreshed when they expire, and the refreshed
token is persisted back to the secrets store.

---

## Context Compaction

When a conversation gets too long for the model's context window, the
`ContextCompactor` can handle it:

1. **Truncation** — drop the oldest messages (sliding window)
2. **Summarization** — use the LLM itself to summarize old messages
3. **Hybrid** — summarize then truncate if still too long

This is triggered automatically by coding_agent when a context-length error
is detected.

---

## Key Takeaways

1. **Two functions: `stream` and `complete`** — that's the entire public API.
   Everything else is plumbing.
2. **Models carry their own routing** — the `api` field on each model determines
   which provider handles it. Adding a new OpenAI-compatible provider is just
   data.
3. **Three reliability layers** — circuit breaker, rate limiter, and concurrency
   cap protect against provider failures and abuse.
4. **Streaming is the default** — `complete` is just `stream` + wait. Events
   flow as they're generated, enabling real-time display on Telegram.
5. **Token tracking is built in** — every call reports usage and cost, enabling
   budget enforcement upstream.
6. **Prompt caching reduces cost** — Anthropic's cache control is automatically
   applied, making repeated calls in the same session cheaper.

---

[Next: The Foundation (lemon_core) >](08-the-foundation.md)
