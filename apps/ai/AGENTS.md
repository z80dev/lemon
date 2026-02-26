# AI App - Agent Guidelines

## Purpose and Responsibilities

The `ai` app provides a unified LLM API abstraction layer for the Lemon platform. It enables seamless interaction with multiple AI providers through a consistent streaming interface.

### Key Responsibilities

- **Provider Abstraction**: Single interface for multiple LLM providers
- **Streaming Responses**: Real-time event streaming with backpressure
- **Resilience**: Circuit breakers and rate limiting per provider
- **Caching**: Model availability caching via ETS
- **Cost Tracking**: Token usage and cost calculation

## Architecture Overview

```
Ai (main API)
  │
  ├── Ai.stream/3 ──→ Ai.CallDispatcher.dispatch/2
  │                       │
  │                       ├── Ai.CircuitBreaker (per-provider, lazy-started)
  │                       ├── Ai.RateLimiter (per-provider, lazy-started)
  │                       └── Provider Module
  │                               │
  │                               └── Ai.EventStream (async GenServer)
  │
  └── Ai.complete/3 (blocking wrapper around stream)
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `Ai` | Main public API (`stream/3`, `complete/3`, `get_text/1`, `get_thinking/1`, `get_tool_calls/1`, `calculate_cost/2`) |
| `Ai.Provider` | Behaviour for provider implementations |
| `Ai.ProviderRegistry` | `:persistent_term` registry for O(1) provider lookups |
| `Ai.ProviderSupervisor` | `DynamicSupervisor` for per-provider services |
| `Ai.CallDispatcher` | Routes calls through circuit breaker + rate limiter + concurrency cap |
| `Ai.CircuitBreaker` | Per-provider fault tolerance (closed/open/half-open), lazy-started |
| `Ai.RateLimiter` | Token bucket rate limiting per provider, lazy-started |
| `Ai.ModelCache` | ETS-backed model availability cache (5-minute default TTL) |
| `Ai.EventStream` | Async GenServer for streaming events with lifecycle management |
| `Ai.Models` | All model definitions and metadata (large file: ~11k lines) |
| `Ai.Types` | All type/struct definitions (inline in module) |
| `Ai.Error` | HTTP error parsing, classification, and formatting utilities |
| `Ai.HttpInspector` | Captures and saves request dumps for 4xx errors |

### Provider Implementation Modules

| Module | API ID | Provider |
|--------|--------|----------|
| `Ai.Providers.Anthropic` | `:anthropic_messages` | Anthropic (also Kimi, OpenCode via same API) |
| `Ai.Providers.OpenAICompletions` | `:openai_completions` | OpenAI Chat Completions (and compatible: Groq, Mistral, xAI, Cerebras, OpenRouter, etc.) |
| `Ai.Providers.OpenAIResponses` | `:openai_responses` | OpenAI Responses API |
| `Ai.Providers.OpenAICodexResponses` | `:openai_codex_responses` | OpenAI Codex (ChatGPT JWT auth; source selected by `providers.openai-codex.auth_source`) |
| `Ai.Providers.AzureOpenAIResponses` | `:azure_openai_responses` | Azure OpenAI |
| `Ai.Providers.Google` | `:google_generative_ai` | Google AI Studio (Gemini) |
| `Ai.Providers.GoogleVertex` | `:google_vertex` | Google Vertex AI |
| `Ai.Providers.GoogleGeminiCli` | `:google_gemini_cli` | Google Cloud Code Assist / Gemini CLI |
| `Ai.Providers.Bedrock` | `:bedrock_converse_stream` | AWS Bedrock Converse Stream |

### Internal Provider Helpers

- `Ai.Providers.GoogleShared` - Shared request/response logic for all Google providers
  - Includes async HTTP error-body normalization for streaming calls so provider errors
    surface real upstream JSON messages (not `Req.Response.Async` struct dumps)
- `Ai.Providers.OpenAIResponsesShared` - Shared logic for OpenAI Responses and Azure, including `function_call_output` size guards
- `Ai.Providers.HttpTrace` - HTTP request/response tracing (enabled via `LEMON_AI_HTTP_TRACE=1`)
- `Ai.Providers.TextSanitizer` - UTF-8 sanitization for streamed text
- `Ai.Auth.OpenAICodexOAuth` - Resolves/refreshes ChatGPT JWT tokens from encrypted OAuth secret payloads (default: `llm_openai_codex_api_key`)
- `Ai.Auth.GitHubCopilotOAuth` - GitHub Copilot OAuth device login + token refresh helpers for encrypted secret payloads

## Key Types (all defined in `Ai.Types`)

```elixir
# Model struct - note headers and compat fields
%Ai.Types.Model{
  id: String.t(),
  name: String.t(),
  api: atom(),           # matches registered api_id
  provider: atom(),      # used for circuit breaker / rate limiter keying
  base_url: String.t(),
  reasoning: boolean(),
  input: [:text | :image],
  cost: %Ai.Types.ModelCost{input: float(), output: float(), cache_read: float(), cache_write: float()},
  context_window: non_neg_integer(),
  max_tokens: non_neg_integer(),
  headers: map(),        # extra HTTP headers for this model
  compat: map() | nil   # provider-specific compatibility overrides
}

# StreamOptions - full set of fields
%Ai.Types.StreamOptions{
  temperature: float() | nil,
  max_tokens: non_neg_integer() | nil,
  api_key: String.t() | nil,
  session_id: String.t() | nil,
  headers: map(),
  reasoning: :minimal | :low | :medium | :high | :xhigh | nil,
  thinking_budgets: map(),   # per-model reasoning budget overrides
  stream_timeout: timeout(), # default 300_000ms
  tool_choice: atom() | nil,
  project: String.t() | nil,   # GCP project for Vertex
  location: String.t() | nil,  # GCP location for Vertex
  access_token: String.t() | nil  # OAuth token for Vertex/GeminiCli
}

# Context - messages stored in REVERSE order internally (newest first)
%Ai.Types.Context{
  system_prompt: String.t() | nil,
  messages: [UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t()],
  tools: [Tool.t()]
}

# ToolResultMessage
%Ai.Types.ToolResultMessage{
  role: :tool_result,
  tool_call_id: String.t(),
  tool_name: String.t(),
  content: [TextContent.t() | ImageContent.t()],
  details: any(),        # arbitrary metadata
  trust: :trusted | :untrusted,
  is_error: boolean(),
  timestamp: integer()
}
```

IMPORTANT: `Context.messages` is stored newest-first. Use `Context.get_messages_chronological/1` when passing messages to an LLM API.

## Provider Behaviour

All providers implement `Ai.Provider`:

```elixir
@callback stream(Model.t(), Context.t(), StreamOptions.t()) ::
            {:ok, EventStream.t()} | {:error, term()}

@callback provider_id() :: atom()
@callback api_id() :: atom()
@callback get_env_api_key() :: String.t() | nil  # optional callback
```

### Provider Registration

Providers are registered at startup in `Ai.Application.register_providers/0`:

```elixir
Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
Ai.ProviderRegistry.register(:openai_responses, Ai.Providers.OpenAIResponses)
# etc.
```

The registry uses `:persistent_term` for O(1) lookups that survive process crashes. Do not call `register/2` from providers themselves.

## How to Add a New Provider

### 1. Create Provider Module

Create `lib/ai/providers/my_provider.ex`:

```elixir
defmodule Ai.Providers.MyProvider do
  @behaviour Ai.Provider

  alias Ai.{EventStream, Types}

  @impl true
  def api_id, do: :my_provider_api

  @impl true
  def provider_id, do: :my_provider

  @impl true
  def get_env_api_key, do: System.get_env("MY_PROVIDER_API_KEY")

  @impl true
  def stream(%Types.Model{} = model, %Types.Context{} = context, %Types.StreamOptions{} = opts) do
    {:ok, stream} = EventStream.start_link(owner: self(), max_queue: 10_000, timeout: opts.stream_timeout || 300_000)

    {:ok, task_pid} = Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
      do_stream(stream, model, context, opts)
    end)

    EventStream.attach_task(stream, task_pid)
    {:ok, stream}
  end

  defp do_stream(stream, model, context, opts) do
    # 1. Build request body
    # 2. Make HTTP request with Req (streaming)
    # 3. Push events: EventStream.push_async(stream, event)
    # 4. Finish: EventStream.complete(stream, assistant_message)
    #    or on error: EventStream.error(stream, assistant_message)
  end
end
```

### 2. Add Model Definitions

Add models to `Ai.Models` (the `@models` compile-time map at the bottom of the file):

```elixir
@my_provider_models %{
  "my-model-id" => %Types.Model{
    id: "my-model-id",
    name: "My Model",
    api: :my_provider_api,  # must match registered api_id
    provider: :my_provider,
    base_url: "https://api.myprovider.com",
    reasoning: false,
    input: [:text, :image],
    cost: %Types.ModelCost{input: 1.0, output: 2.0, cache_read: 0.0, cache_write: 0.0},
    context_window: 128_000,
    max_tokens: 4096
  }
}
```

Then add `:my_provider` to the `@providers` list and include the model map in the `@models` map.

### 3. Register Provider

Add to `Ai.Application.register_providers/0`:

```elixir
Ai.ProviderRegistry.register(:my_provider_api, Ai.Providers.MyProvider)
```

## Circuit Breaker

The `Ai.CircuitBreaker` module implements three states:

- **Closed** (normal): Requests pass through
- **Open** (failure threshold reached): Requests rejected immediately
- **Half-Open** (recovery timeout elapsed): Limited requests allowed (2 successes needed to close)

Both `CircuitBreaker` and `RateLimiter` are started lazily on first use via `ensure_started/1`.

**Configuration** (via `config/config.exs`):

```elixir
config :ai, :circuit_breaker,
  failure_threshold: 5,     # failures before opening (default: 5)
  recovery_timeout: 30_000  # ms before attempting recovery (default: 30_000)
```

**Manual Control**:

```elixir
Ai.CircuitBreaker.is_open?(:anthropic)    # check state
Ai.CircuitBreaker.reset(:anthropic)       # manual reset to closed
Ai.CircuitBreaker.get_state(:anthropic)   # returns {:ok, map()}
Ai.CircuitBreaker.record_success(:anthropic)
Ai.CircuitBreaker.record_failure(:anthropic)
```

## Rate Limiter

Token bucket algorithm. **Configuration**:

```elixir
config :ai, :rate_limiter,
  tokens_per_second: 10,  # refill rate (default: 10)
  max_tokens: 20          # bucket capacity (default: 20)
```

## Call Dispatcher

Routes calls through circuit breaker, rate limiter, and concurrency cap.

```elixir
Ai.CallDispatcher.dispatch(:anthropic, fn ->
  Ai.Providers.Anthropic.stream(model, context, opts)
end)
# Returns: {:ok, stream} | {:error, :circuit_open} | {:error, :rate_limited} | {:error, :max_concurrency}
```

**Concurrency Control** (default cap: 10 per provider):

```elixir
Ai.CallDispatcher.set_concurrency_cap(:anthropic, 20)
Ai.CallDispatcher.get_active_requests(:anthropic)
Ai.CallDispatcher.get_state()  # returns full dispatcher state map
```

The dispatcher also tracks streaming task completion to record circuit breaker success/failure after stream finishes.

## Event Streaming

### Event Types

```elixir
{:start, AssistantMessage.t()}                        # Stream started
{:text_start, idx, AssistantMessage.t()}              # Text block started
{:text_delta, idx, String.t(), AssistantMessage.t()}  # Text chunk
{:text_end, idx, String.t(), AssistantMessage.t()}    # Text block complete
{:thinking_start, idx, AssistantMessage.t()}
{:thinking_delta, idx, String.t(), AssistantMessage.t()}
{:thinking_end, idx, String.t(), AssistantMessage.t()}
{:tool_call_start, idx, AssistantMessage.t()}
{:tool_call_delta, idx, String.t(), AssistantMessage.t()}
{:tool_call_end, idx, ToolCall.t(), AssistantMessage.t()}
{:done, stop_reason, AssistantMessage.t()}            # Stream completed
{:error, stop_reason, AssistantMessage.t()}           # Stream error
{:canceled, reason}                                   # Stream canceled
```

`stop_reason` is one of: `:stop | :length | :tool_use | :error | :aborted`

### Consuming Events

```elixir
{:ok, stream} = Ai.stream(model, context)

# Consume event by event (blocking, lazy)
stream
|> Ai.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta, _partial} -> IO.write(delta)
  {:done, _reason, message} -> IO.puts("\nDone")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)

# Wait for final result (blocking)
{:ok, message} = Ai.EventStream.result(stream)

# Collect all text in one call
text = Ai.EventStream.collect_text(stream)

# Check queue stats
%{queue_size: n, max_queue: m, dropped: d} = Ai.EventStream.stats(stream)

# Cancel explicitly
Ai.EventStream.cancel(stream, :user_requested)
```

### Stream Lifecycle

- Streams are linked to owner process (auto-cancel on owner death)
- Tasks supervised under `Ai.StreamTaskSupervisor`
- Default timeout: 300_000ms (configurable via `opts.stream_timeout`)
- Default max queue: 10_000 events
- Default drop strategy: `:error` (returns `{:error, :overflow}` from `push/2`)
- Other drop strategies: `:drop_oldest`, `:drop_newest`
- Use `push/2` for backpressure, `push_async/2` for fire-and-forget

## Models API

```elixir
# Look up a model
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")  # returns nil if not found

# List all models for a provider
models = Ai.Models.get_models(:openai)  # returns []  if unknown provider

# List all known providers
providers = Ai.Models.get_providers()

# List all models (all providers)
all = Ai.Models.list_models()

# Capability checks
Ai.Models.supports_vision?(model)      # checks :image in model.input
Ai.Models.supports_reasoning?(model)  # checks model.reasoning flag
Ai.Models.supports_xhigh(model)       # checks if :xhigh reasoning is supported

# Find by model ID string alone (searches all providers)
model = Ai.Models.find_by_id("claude-sonnet-4-20250514")

# Compare models
Ai.Models.models_equal?(model_a, model_b)  # compares id + provider

# Get just the IDs for a provider
ids = Ai.Models.get_model_ids(:anthropic)
```

**Supported providers in `@providers`**: `:anthropic`, `:openai`, `:"openai-codex"`, `:amazon_bedrock`, `:google`, `:google_antigravity`, `:kimi`, `:kimi_coding`, `:opencode`, `:xai`, `:mistral`, `:cerebras`, `:deepseek`, `:qwen`, `:minimax`, `:zai`, `:azure_openai_responses`, `:github_copilot`, `:google_gemini_cli`, `:google_vertex`, `:groq`, `:huggingface`, `:minimax_cn`, `:openrouter`, `:vercel_ai_gateway`

## Common Tasks

### Making a Simple Request

```elixir
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
context = Ai.Types.Context.new(system_prompt: "You are helpful")
context = Ai.Types.Context.add_user_message(context, "Explain OTP")

{:ok, message} = Ai.complete(model, context, %{temperature: 0.7})
text = Ai.get_text(message)
thinking = Ai.get_thinking(message)  # for reasoning models
tool_calls = Ai.get_tool_calls(message)
```

Note: `Ai.new_context/1` is a delegate to `Ai.Types.Context.new/1`.

### Streaming with Tools

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

context = Ai.Types.Context.new(tools: tools)
context = Ai.Types.Context.add_user_message(context, "What's the weather in Paris?")

{:ok, stream} = Ai.stream(model, context)

Ai.EventStream.events(stream)
|> Enum.each(fn
  {:tool_call_end, _idx, tool_call, _msg} ->
    # tool_call.name, tool_call.arguments (map), tool_call.id
    :ok
  _ -> :ok
end)
```

### Adding Tool Results

```elixir
result = %Ai.Types.ToolResultMessage{
  tool_call_id: tool_call.id,
  tool_name: tool_call.name,
  content: [%Ai.Types.TextContent{text: "Sunny, 22°C"}],
  is_error: false
}

context = Ai.Types.Context.add_tool_result(context, result)
```

### Calculating Cost

```elixir
{:ok, message} = Ai.complete(model, context)
cost = Ai.calculate_cost(model, message.usage)
# cost.total, cost.input, cost.output, cost.cache_read, cost.cache_write (all in dollars)
```

### Error Handling

```elixir
# Format any error term to a human-readable string
Ai.Error.format_error(:rate_limited)
Ai.Error.format_error({:http_error, 429, body})

# Check error properties
Ai.Error.retryable?(:timeout)           # => true
Ai.Error.auth_error?({:http_error, 401, _})  # => true
Ai.Error.rate_limit_error?(:rate_limited)    # => true

# Get suggested retry delay in ms
Ai.Error.suggested_retry_delay(:rate_limited)  # => 60_000

# Parse raw HTTP error
parsed = Ai.Error.parse_http_error(429, response_body, headers)
# parsed.category, parsed.message, parsed.retryable, parsed.rate_limit_info
```

## Testing Guidance

### Running Tests

```bash
# All ai tests (from umbrella root)
mix test apps/ai

# Specific test file
mix test apps/ai/test/ai/circuit_breaker_test.exs

# Integration tests (requires API keys)
mix test apps/ai/test/integration --include integration
mix test --include integration --only provider:anthropic
```

### Test Structure

| Directory | Purpose |
|-----------|---------|
| `test/ai/` | Core module tests (circuit breaker, event stream, models, etc.) |
| `test/providers/` | Provider implementation tests |
| `test/integration/` | Live API tests (requires keys, excluded by default) |
| `test/support/` | `IntegrationConfig` helper for integration test setup |

### Mocking HTTP Requests

Use `Req.Test` for HTTP mocking (the pattern used throughout the codebase):

```elixir
defmodule Ai.Providers.MyProviderTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  test "streams response" do
    Req.Test.stub(__MODULE__, fn conn ->
      body = "event: message_stop\ndata: {}\n\n"
      Plug.Conn.send_resp(conn, 200, body)
    end)

    model = %Ai.Types.Model{..., base_url: "https://example.test"}
    context = Ai.Types.Context.new() |> Ai.Types.Context.add_user_message("Hi")
    {:ok, stream} = MyProvider.stream(model, context, %Ai.Types.StreamOptions{api_key: "test-key"})
    assert {:ok, result} = Ai.EventStream.result(stream, 1000)
  end
end
```

### Test Helpers

```elixir
# Reset circuit breaker state between tests
setup do
  Ai.CircuitBreaker.reset(:anthropic)
  :ok
end

# Clear provider registry (for isolation)
setup do
  Ai.ProviderRegistry.clear()
  :ok
end
```

### Integration Testing

```elixir
defmodule Ai.Integration.MyProviderLiveTest do
  use ExUnit.Case

  @moduletag :integration

  test "live streaming works" do
    model = Ai.Models.get_model(:my_provider, "my-model")
    context = Ai.Types.Context.new() |> Ai.Types.Context.add_user_message("Hello")

    {:ok, stream} = Ai.stream(model, context)
    assert {:ok, %Ai.Types.AssistantMessage{} = msg} = Ai.EventStream.result(stream)
    assert msg.content != []
  end
end
```

Run with: `mix test --include integration`

## Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Anthropic provider | API authentication |
| `OPENAI_API_KEY` | OpenAI providers | API authentication |
| `OPENAI_CODEX_API_KEY` | OpenAI Codex provider | Static key/token when `providers.openai-codex.auth_source = "api_key"` |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI provider | API authentication |
| `AZURE_OPENAI_BASE_URL` | Azure OpenAI provider | Full base URL (optional) |
| `AZURE_OPENAI_RESOURCE_NAME` | Azure OpenAI provider | Resource name (if no base URL) |
| `AZURE_OPENAI_API_VERSION` | Azure OpenAI provider | API version (default: "v1") |
| `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` | Azure OpenAI provider | Comma-separated `model=deployment` mappings |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Bedrock provider | AWS credentials |
| `AWS_REGION` | Bedrock provider | AWS region (default: `us-east-1`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google AI Studio provider | API key (also checks `GOOGLE_API_KEY`, `GEMINI_API_KEY`) |
| `GOOGLE_CLOUD_PROJECT` | Google Vertex provider | GCP project ID (also checks `GCLOUD_PROJECT`) |
| `GOOGLE_CLOUD_LOCATION` | Google Vertex provider | GCP region |
| `LEMON_AI_HTTP_TRACE` | `Ai.Providers.HttpTrace` | Set to `"1"` to enable HTTP request/response logging |
| `LEMON_AI_DEBUG` | Anthropic provider | Set to `"1"` to log raw SSE to a file |
| `LEMON_AI_DEBUG_FILE` | Anthropic provider | SSE log file path (default: `/tmp/lemon_anthropic_sse.log`) |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | Anthropic provider (Kimi) | Max history messages for Kimi models (default: 200) |
| `PI_CACHE_RETENTION` | OpenAI Responses provider | Set to `"long"` for 24h prompt cache retention |

## Key Dependencies

- `lemon_core` - Shared primitives and telemetry (`LemonCore.Telemetry.emit/3`)
- `req` - HTTP client with streaming support (`Req.Test` for test mocking)
- `jason` - JSON encoding/decoding
- `nimble_options` - Options validation
- `plug` - Test only (required for `Req.Test` stubs via `Plug.Conn`)

## Supervision Tree

```
Ai.Supervisor (one_for_one)
  ├── Task.Supervisor (name: Ai.StreamTaskSupervisor)
  ├── Registry (name: Ai.RateLimiterRegistry)
  ├── Registry (name: Ai.CircuitBreakerRegistry)
  ├── Ai.ProviderSupervisor (DynamicSupervisor for per-provider services)
  ├── Ai.CallDispatcher
  └── Ai.ModelCache
```

`Ai.ProviderRegistry` is NOT in the supervision tree - it uses `:persistent_term` directly.
