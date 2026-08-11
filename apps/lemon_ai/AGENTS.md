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
LemonAi (main API)
  |
  +-- LemonAi.stream/3 --> LemonAi.CallDispatcher.dispatch/2
  |                       |
  |                       +-- LemonAi.CircuitBreaker (per-provider, lazy-started)
  |                       +-- LemonAi.RateLimiter (per-provider, lazy-started)
  |                       +-- Provider Module
  |                               |
  |                               +-- LemonAi.EventStream (async GenServer)
  |
  +-- LemonAi.complete/3 (blocking wrapper around stream)
```

### Core Modules

| Module | Purpose |
|--------|---------|
| `LemonAi` | Main public API (`stream/3`, `complete/3`, `get_text/1`, `get_thinking/1`, `get_tool_calls/1`, `calculate_cost/2`) |
| `LemonAi.Provider` | Behaviour for provider implementations |
| `LemonAi.ProviderRegistry` | `:persistent_term` registry for O(1) provider lookups |
| `LemonAi.ProviderSupervisor` | `DynamicSupervisor` for per-provider services |
| `LemonAi.CallDispatcher` | Routes calls through circuit breaker + rate limiter + concurrency cap |
| `LemonAi.CircuitBreaker` | Per-provider fault tolerance (closed/open/half-open), lazy-started |
| `LemonAi.RateLimiter` | Token bucket rate limiting per provider, lazy-started |
| `LemonAi.ModelCache` | ETS-backed model availability cache (5-minute default TTL) |
| `LemonAi.EventStream` | Async GenServer for streaming events with lifecycle management |
| `LemonAi.Models` | All model definitions and metadata (large file: many thousands of lines). Registry entries should stay aligned with live provider IDs; dead preview/model aliases that return provider 404s should be removed instead of left selectable. |
| `LemonAi.Types` | All type/struct definitions (inline in module) |
| `LemonAi.Error` | HTTP error parsing, classification, retryability, and formatting utilities; provider-specific overloaded responses such as Anthropic HTTP 529 are transient retryable errors |
| `LemonAi.HttpInspector` | Captures and saves request dumps for 4xx errors |
| `LemonAi.PromptDiagnostics` | Opt-in prompt size + token usage diagnostics |

### Provider Implementation Modules

| Module | API ID | Provider |
|--------|--------|----------|
| `LemonAi.Providers.Anthropic` | `:anthropic_messages` | Anthropic (also Kimi, OpenCode via same API) |
| `LemonAi.Providers.OpenAICompletions` | `:openai_completions` | OpenAI Chat Completions (and compatible: Groq, Mistral, xAI, Cerebras, OpenRouter, etc.) |
| `LemonAi.Providers.OpenAIResponses` | `:openai_responses` | OpenAI Responses API |
| `LemonAi.Providers.OpenAICodexResponses` | `:openai_codex_responses` | OpenAI Codex (ChatGPT JWT auth) |
| `LemonAi.Providers.AzureOpenAIResponses` | `:azure_openai_responses` | Azure OpenAI |
| `LemonAi.Providers.Google` | `:google_generative_ai` | Google AI Studio (Gemini) |
| `LemonAi.Providers.GoogleVertex` | `:google_vertex` | Google Vertex AI |
| `LemonAi.Providers.GoogleGeminiCli` | `:google_gemini_cli` | Google Cloud Code Assist / Gemini CLI |
| `LemonAi.Providers.Bedrock` | `:bedrock_converse_stream` | AWS Bedrock Converse Stream |

### Internal Provider Helpers

`LemonAi.Auth.*` modules are implemented in this app as provider protocol helpers.
They must not depend on Lemon config, secrets, or persistence. Lemon-owned apps
should consume `LemonAgent.ModelRuntime.Credentials` for stored credential lookup
and refresh persistence.

- `LemonAi.Providers.GoogleShared` - Shared request/response logic for all Google providers
  - Includes async HTTP error-body normalization for streaming calls so provider errors
    surface real upstream JSON messages (not `Req.Response.Async` struct dumps)
- `LemonAi.Providers.Anthropic` - Anthropic Messages provider, including Claude Code-compatible
  OAuth request/response shaping for Claude subscription auth (`anthropic-beta` headers,
  dynamic Claude CLI version detection, Claude Code system identity, OAuth-only system prompt
  sanitization, `mcp_` tool name normalization/prefixing/stripping, adaptive thinking on Claude 4.6,
  and normalization of restored map-shaped content blocks (`text`, `image`, `thinking`, `tool_use`,
  tool-result text) before Anthropic-compatible request building for providers like MiniMax
- `LemonAi.Models.OpenAI` - Static direct OpenAI model catalog used by channel pickers; keep latest alias IDs aligned with live `GET /v1/models` results for the configured key and remove dead aliases instead of leaving them selectable
- `LemonAi.Models.Google` - Treat direct Google Generative AI entries the same way: remove IDs that fail live `generateContent` on the configured surface instead of leaving dead models selectable in Telegram
- `:"openai-codex"` model registry - Derived from the direct OpenAI catalog plus Codex OAuth-only IDs; do not assume `/v1/models` is authoritative for ChatGPT/Codex-authenticated model availability
- `LemonAi.Providers.OpenAIResponsesShared` - Shared logic for OpenAI Responses and Azure, including `function_call_output` size guards and immediate terminal handling once `response.completed` arrives
- `LemonAi.Providers.OpenAIResponses` - Direct OpenAI Responses streaming path; when tools are present it now sends explicit `tool_choice: "auto"` and `parallel_tool_calls: true` so GPT-5 family models do not silently skip tool use on task-heavy prompts
- `LemonAi.Providers.OpenAICompletions` - OpenAI-compatible chat requests map `tool_choice: :any` to `"required"`; ZAI thinking format must honor explicit `reasoning: false` with `thinking.type = "disabled"`
- `LemonAi.Providers.HttpTrace` - HTTP request/response tracing (enabled via `LEMON_AI_HTTP_TRACE=1`)
- `LemonAi.Providers.TextSanitizer` - UTF-8 sanitization for streamed text
- `LemonAi.Auth.GoogleAntigravityOAuth` - Antigravity PKCE OAuth URL helpers, token exchange/refresh, and encoded OAuth payload resolution (`{"token","projectId"}` API key shape)
- `LemonAi.Auth.GoogleGeminiCliOAuth` - Gemini CLI PKCE OAuth helpers, Code Assist project setup, token refresh, and encoded OAuth payload resolution (`{"token","projectId"}` API key shape)
- `LemonAi.Auth.GitHubCopilotOAuth` - GitHub Copilot OAuth device login + token refresh helpers for encoded secret payloads
- `LemonAi.Auth.OpenAICodexOAuth` - OpenAI Codex PKCE OAuth helpers, token refresh, and JWT extraction
- `LemonAi.Auth.OAuthSecretResolver` - Central dispatcher for provider-specific encoded OAuth payloads
- `LemonAi.Auth.OAuthPKCE` - PKCE verifier/challenge generation utility

## Key Types (all defined in `LemonAi.Types`)

```elixir
# Model struct - note headers and compat fields
%LemonAi.Types.Model{
  id: String.t(),
  name: String.t(),
  api: atom(),           # matches registered api_id
  provider: atom(),      # used for circuit breaker / rate limiter keying
  base_url: String.t(),
  reasoning: boolean(),
  input: [:text | :image],
  cost: %LemonAi.Types.ModelCost{input: float(), output: float(), cache_read: float(), cache_write: float()},
  context_window: non_neg_integer(),
  max_tokens: non_neg_integer(),
  headers: map(),        # extra HTTP headers for this model
  compat: map() | nil   # provider-specific compatibility overrides
}

# StreamOptions - full set of fields
%LemonAi.Types.StreamOptions{
  temperature: float() | nil,
  max_tokens: non_neg_integer() | nil,
  api_key: String.t() | nil,
  session_id: String.t() | nil,
  headers: map(),
  reasoning: :minimal | :low | :medium | :high | :xhigh | nil,
  thinking_budgets: map(),   # per-model reasoning budget overrides
  stream_timeout: timeout(), # default 300_000ms
  tool_choice: atom() | String.t() | nil,
  project: String.t() | nil,   # GCP project for Vertex
  location: String.t() | nil,  # GCP location for Vertex
  access_token: String.t() | nil,  # OAuth token for Vertex/GeminiCli
  service_account_json: String.t() | nil
}

# Context - messages stored in REVERSE order internally (newest first)
%LemonAi.Types.Context{
  system_prompt: String.t() | nil,
  messages: [UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t()],
  tools: [Tool.t()]
}

# ToolResultMessage
%LemonAi.Types.ToolResultMessage{
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

All providers implement `LemonAi.Provider`:

```elixir
@callback stream(Model.t(), Context.t(), StreamOptions.t()) ::
            {:ok, EventStream.t()} | {:error, term()}

@callback provider_id() :: atom()
@callback api_id() :: atom()
@callback get_env_api_key() :: String.t() | nil  # optional callback
```

### Provider Registration

Providers are registered at startup in `LemonAi.Application.register_providers/0`:

```elixir
LemonAi.ProviderRegistry.register(:anthropic_messages, LemonAi.Providers.Anthropic)
LemonAi.ProviderRegistry.register(:openai_responses, LemonAi.Providers.OpenAIResponses)
# etc.
```

The registry uses `:persistent_term` for O(1) lookups that survive process crashes. Do not call `register/2` from providers themselves.

## How to Add a New Provider

### 1. Create Provider Module

Create `lib/ai/providers/my_provider.ex`:

```elixir
defmodule LemonAi.Providers.MyProvider do
  @behaviour LemonAi.Provider

  alias LemonAi.{EventStream, Types}

  @impl true
  def api_id, do: :my_provider_api

  @impl true
  def provider_id, do: :my_provider

  @impl true
  def get_env_api_key, do: System.get_env("MY_PROVIDER_API_KEY")

  @impl true
  def stream(%Types.Model{} = model, %Types.Context{} = context, %Types.StreamOptions{} = opts) do
    {:ok, stream} = EventStream.start_link(owner: self(), max_queue: 10_000, timeout: opts.stream_timeout || 300_000)

    {:ok, task_pid} = Task.Supervisor.start_child(LemonAi.StreamTaskSupervisor, fn ->
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

Add models to `LemonAi.Models` (the `@models` compile-time map at the bottom of the file):

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

Add to `LemonAi.Application.register_providers/0`:

```elixir
LemonAi.ProviderRegistry.register(:my_provider_api, LemonAi.Providers.MyProvider)
```

## Circuit Breaker

The `LemonAi.CircuitBreaker` module implements three states:

- **Closed** (normal): Requests pass through
- **Open** (failure threshold reached): Requests rejected immediately
- **Half-Open** (recovery timeout elapsed): Limited requests allowed (2 successes needed to close)

Both `CircuitBreaker` and `RateLimiter` are started lazily on first use via `ensure_started/1`.

**Configuration** (via `config/config.exs`):

```elixir
config :lemon_ai, :circuit_breaker,
  failure_threshold: 5,     # failures before opening (default: 5)
  recovery_timeout: 30_000  # ms before attempting recovery (default: 30_000)
```

**Manual Control**:

```elixir
LemonAi.CircuitBreaker.open?(:anthropic)    # check state
LemonAi.CircuitBreaker.reset(:anthropic)       # manual reset to closed
LemonAi.CircuitBreaker.get_state(:anthropic)   # returns {:ok, map()}
LemonAi.CircuitBreaker.record_success(:anthropic)
LemonAi.CircuitBreaker.record_failure(:anthropic)
```

`LemonAi.CircuitBreaker.get_state/1` returns the current state plus the last recorded
failure reason, which is the fastest way to diagnose why a provider circuit opened.

## Rate Limiter

Token bucket algorithm. **Configuration**:

```elixir
config :lemon_ai, :rate_limiter,
  tokens_per_second: 10,  # refill rate (default: 10)
  max_tokens: 20          # bucket capacity (default: 20)
```

## Call Dispatcher

Routes calls through circuit breaker, rate limiter, and concurrency cap.

```elixir
LemonAi.CallDispatcher.dispatch(:anthropic, fn ->
  LemonAi.Providers.Anthropic.stream(model, context, opts)
end)
# Returns: {:ok, stream} | {:error, :circuit_open} | {:error, :rate_limited} | {:error, :max_concurrency}
```

**Concurrency Control** (default cap: 10 per provider):

```elixir
LemonAi.CallDispatcher.set_concurrency_cap(:anthropic, 20)
LemonAi.CallDispatcher.get_active_requests(:anthropic)
LemonAi.CallDispatcher.get_state()  # returns full dispatcher state map
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
{:ok, stream} = LemonAi.stream(model, context)

# Consume event by event (blocking, lazy)
stream
|> LemonAi.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta, _partial} -> IO.write(delta)
  {:done, _reason, message} -> IO.puts("\nDone")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)

# Wait for final result (blocking)
{:ok, message} = LemonAi.EventStream.result(stream)

# Collect all text in one call
text = LemonAi.EventStream.collect_text(stream)

# Check queue stats
%{queue_size: n, max_queue: m, dropped: d} = LemonAi.EventStream.stats(stream)

# Cancel explicitly
LemonAi.EventStream.cancel(stream, :user_requested)
```

### Stream Lifecycle

- Streams are linked to owner process (auto-cancel on owner death)
- Tasks supervised under `LemonAi.StreamTaskSupervisor`
- Default timeout: 300_000ms (configurable via `opts.stream_timeout`)
- Default max queue: 10_000 events
- Default drop strategy: `:error` (returns `{:error, :overflow}` from `push/2`)
- Other drop strategies: `:drop_oldest`, `:drop_newest`
- Use `push/2` for backpressure, `push_async/2` for fire-and-forget

## Models API

```elixir
# Look up a model
model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-4-20250514")  # returns nil if not found

# List all models for a provider
models = LemonAi.Models.get_models(:openai)  # returns []  if unknown provider

# List all known providers
providers = LemonAi.Models.get_providers()

# List all models (all providers)
all = LemonAi.Models.list_models()

# Capability checks
LemonAi.Models.supports_vision?(model)      # checks :image in model.input
LemonAi.Models.supports_reasoning?(model)  # checks model.reasoning flag
LemonAi.Models.supports_xhigh(model)       # checks if :xhigh reasoning is supported

# Find by model ID string alone (searches all providers)
model = LemonAi.Models.find_by_id("claude-sonnet-4-20250514")

# Compare models
LemonAi.Models.models_equal?(model_a, model_b)  # compares id + provider

# Get just the IDs for a provider
ids = LemonAi.Models.get_model_ids(:anthropic)
```

**Supported providers in `@providers`**: `:anthropic`, `:openai`, `:"openai-codex"`, `:amazon_bedrock`, `:google`, `:google_antigravity`, `:kimi`, `:kimi_coding`, `:opencode`, `:opencode_go`, `:xai`, `:mistral`, `:cerebras`, `:deepseek`, `:qwen`, `:minimax`, `:zai`, `:azure_openai_responses`, `:github_copilot`, `:google_gemini_cli`, `:google_vertex`, `:groq`, `:huggingface`, `:minimax_cn`, `:openrouter`, `:vercel_ai_gateway`

## Common Tasks

### Making a Simple Request

```elixir
model = LemonAi.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
context = LemonAi.Types.Context.new(system_prompt: "You are helpful")
context = LemonAi.Types.Context.add_user_message(context, "Explain OTP")

{:ok, message} = LemonAi.complete(model, context, %{temperature: 0.7})
text = LemonAi.get_text(message)
thinking = LemonAi.get_thinking(message)  # for reasoning models
tool_calls = LemonAi.get_tool_calls(message)
```

Note: `LemonAi.new_context/1` is a delegate to `LemonAi.Types.Context.new/1`.

### Streaming with Tools

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

context = LemonAi.Types.Context.new(tools: tools)
context = LemonAi.Types.Context.add_user_message(context, "What's the weather in Paris?")

{:ok, stream} = LemonAi.stream(model, context)

LemonAi.EventStream.events(stream)
|> Enum.each(fn
  {:tool_call_end, _idx, tool_call, _msg} ->
    # tool_call.name, tool_call.arguments (map), tool_call.id
    :ok
  _ -> :ok
end)
```

### Adding Tool Results

```elixir
result = %LemonAi.Types.ToolResultMessage{
  tool_call_id: tool_call.id,
  tool_name: tool_call.name,
  content: [%LemonAi.Types.TextContent{text: "Sunny, 22C"}],
  is_error: false
}

context = LemonAi.Types.Context.add_tool_result(context, result)
```

### Calculating Cost

```elixir
{:ok, message} = LemonAi.complete(model, context)
cost = LemonAi.calculate_cost(model, message.usage)
# cost.total, cost.input, cost.output, cost.cache_read, cost.cache_write (all in dollars)
```

### Error Handling

```elixir
# Format any error term to a human-readable string
LemonAi.Error.format_error(:rate_limited)
LemonAi.Error.format_error({:http_error, 429, body})

# Check error properties
LemonAi.Error.retryable?(:timeout)           # => true
LemonAi.Error.auth_error?({:http_error, 401, _})  # => true
LemonAi.Error.rate_limit_error?(:rate_limited)    # => true

# Get suggested retry delay in ms
LemonAi.Error.suggested_retry_delay(:rate_limited)  # => 60_000

# Parse raw HTTP error
parsed = LemonAi.Error.parse_http_error(429, response_body, headers)
# parsed.category, parsed.message, parsed.retryable, parsed.rate_limit_info
```

## Testing Guidance

### Running Tests

```bash
# All ai tests (from umbrella root)
mix test apps/lemon_ai

# Specific test file
mix test apps/lemon_ai/test/lemon_ai/circuit_breaker_test.exs

# Integration tests (requires API keys)
mix test apps/lemon_ai/test/integration --include integration
mix test --include integration --only provider:anthropic
```

### Test Structure

| Directory | Purpose |
|-----------|---------|
| `test/ai/` | Core module tests (circuit breaker, event stream, models, error, types, etc.) |
| `test/ai/auth/` | OAuth module tests (GitHub Copilot, Google Antigravity, OpenAI Codex, secret resolver) |
| `test/ai/providers/` | Provider-specific unit tests |
| `test/providers/` | Additional provider tests (streaming, parsing, comprehensive edge cases) |
| `test/integration/` | Live API tests (requires keys, excluded by default with `@moduletag :integration`) |

### Mocking HTTP Requests

Use `Req.Test` for HTTP mocking (the pattern used throughout the codebase):

```elixir
defmodule LemonAi.Providers.MyProviderTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
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

    model = %LemonAi.Types.Model{..., base_url: "https://example.test"}
    context = LemonAi.Types.Context.new() |> LemonAi.Types.Context.add_user_message("Hi")
    {:ok, stream} = MyProvider.stream(model, context, %LemonAi.Types.StreamOptions{api_key: "test-key"})
    assert {:ok, result} = LemonAi.EventStream.result(stream, 1000)
  end
end
```

### Test Helpers

```elixir
# Reset circuit breaker state between tests
setup do
  LemonAi.CircuitBreaker.reset(:anthropic)
  :ok
end

# Clear provider registry (for isolation)
setup do
  LemonAi.ProviderRegistry.clear()
  :ok
end
```

### Integration Testing

```elixir
defmodule LemonAi.Integration.MyProviderLiveTest do
  use ExUnit.Case

  @moduletag :integration

  test "live streaming works" do
    model = LemonAi.Models.get_model(:my_provider, "my-model")
    context = LemonAi.Types.Context.new() |> LemonAi.Types.Context.add_user_message("Hello")

    {:ok, stream} = LemonAi.stream(model, context)
    assert {:ok, %LemonAi.Types.AssistantMessage{} = msg} = LemonAi.EventStream.result(stream)
    assert msg.content != []
  end
end
```

Run with: `mix test --include integration`

## Environment Variables

Lemon callers resolve config, secrets, and OAuth state through
`LemonAgent.ModelRuntime` before calling `LemonAi`. Providers consume concrete values from
`LemonAi.Types.StreamOptions`; process env reads are only standalone authentication
fallback behavior for direct `ai` usage.

| Variable | Used By | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Anthropic provider | API authentication |
| `OPENAI_API_KEY` | OpenAI providers | API authentication |
| `OPENAI_CODEX_API_KEY` | OpenAI Codex provider | JWT token fallback |
| `CHATGPT_TOKEN` | OpenAI Codex provider | Fallback JWT token env var |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI provider | API authentication |
| `AZURE_OPENAI_BASE_URL` | Azure OpenAI provider | Full base URL (optional) |
| `AZURE_OPENAI_RESOURCE_NAME` | Azure OpenAI provider | Resource name (if no base URL) |
| `AZURE_OPENAI_API_VERSION` | Azure OpenAI provider | API version (default: "v1") |
| `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` | Azure OpenAI provider | Comma-separated `model=deployment` mappings |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Bedrock provider | AWS credentials |
| `AWS_REGION` | Bedrock provider | AWS region (default: `us-east-1`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google AI Studio provider | API key (also checks `GOOGLE_API_KEY`, `GEMINI_API_KEY`) |
| `GOOGLE_GEMINI_CLI_API_KEY` | Google Gemini CLI provider | JSON credential payload (`{"token","projectId"}`) |
| `GOOGLE_CLOUD_PROJECT` | `LemonAgent.ModelRuntime.StreamOptions` Vertex option resolver | GCP project ID (also checks `GCLOUD_PROJECT`) |
| `GOOGLE_CLOUD_LOCATION` | `LemonAgent.ModelRuntime.StreamOptions` Vertex option resolver | GCP region |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | `LemonAgent.ModelRuntime.StreamOptions` Vertex option resolver | Inline service account JSON |
| `GOOGLE_APPLICATION_CREDENTIALS` | Google Vertex provider | ADC service account JSON file path |
| `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID` / `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET` | `LemonAi.Auth.GoogleGeminiCliOAuth` | Optional env fallback for Gemini CLI OAuth client credentials |
| `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID` / `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET` | `LemonAi.Auth.GoogleAntigravityOAuth` | Optional env fallback for Antigravity OAuth client credentials |
| `OPENAI_CODEX_OAUTH_CLIENT_ID` | `LemonAi.Auth.OpenAICodexOAuth` | Optional override for Codex OAuth client id |
| `LEMON_AI_HTTP_TRACE` | `LemonAi.Providers.HttpTrace` | Set to `"1"` to enable HTTP request/response logging |
| `LEMON_AI_DEBUG` | Anthropic provider | Set to `"1"` to log raw SSE to a file |
| `LEMON_AI_DEBUG_FILE` | Anthropic provider | SSE log file path (default: `/tmp/lemon_anthropic_sse.log`) |
| `LEMON_AI_PROMPT_DIAGNOSTICS` | `LemonAi.PromptDiagnostics` | Set to `"1"` to enable prompt size/usage logging |
| `LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL` | `LemonAi.PromptDiagnostics` | Log level for diagnostics (default: `info`) |
| `LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N` | `LemonAi.PromptDiagnostics` | Number of largest messages to report (default: 5) |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | Anthropic provider (Kimi) | Max history messages for Kimi models (default: 200) |
| `PI_CACHE_RETENTION` | OpenAI Responses provider | Set to `"long"` for 24h prompt cache retention |

## Key Dependencies

- `req` - HTTP client with streaming support (`Req.Test` for test mocking)
- `jason` - JSON encoding/decoding
- `nimble_options` - Options validation
- `plug` - Test only (required for `Req.Test` stubs via `Plug.Conn`)

## Supervision Tree

```
LemonAi.Supervisor (one_for_one)
  +-- Task.Supervisor (name: LemonAi.StreamTaskSupervisor)
  +-- Registry (name: LemonAi.RateLimiterRegistry)
  +-- Registry (name: LemonAi.CircuitBreakerRegistry)
  +-- LemonAi.ProviderSupervisor (DynamicSupervisor for per-provider services)
  +-- LemonAi.CallDispatcher
  +-- LemonAi.ModelCache
```

`LemonAi.ProviderRegistry` is NOT in the supervision tree - it uses `:persistent_term` directly.

## Common Modification Patterns

### Adding a New Provider

1. Create `lib/ai/providers/my_provider.ex` implementing `@behaviour LemonAi.Provider`
2. Create `lib/ai/models/my_provider.ex` with a `models/0` function returning `%{String.t() => Model.t()}`
3. Add the provider to `@models` and `@providers` in `LemonAi.Models`
4. Register in `LemonAi.Application.register_providers/0`
5. Add tests in `test/providers/my_provider_test.exs`

### Adding a New Model to an Existing Provider

1. Open the relevant `lib/ai/models/<provider>.ex` file
2. Add a new entry to the models map with a `%LemonAi.Types.Model{}` struct
3. Ensure `api`, `provider`, and `base_url` match the existing provider convention

### Adding OAuth Support for a New Provider

1. Create `lib/ai/auth/my_provider_oauth.ex` implementing `resolve_api_key_from_secret/2`
2. Add the module to the `@resolvers` list in `LemonAi.Auth.OAuthSecretResolver`
3. Add tests in `test/ai/auth/my_provider_oauth_test.exs`

### Changing Auth Behaviour

- Lemon API key/config resolution belongs in `LemonAgent.ModelRuntime`; providers receive concrete values through `LemonAi.Types.StreamOptions`.
- Provider OAuth helpers may refresh encoded payloads, but persistence is injected by `LemonAgent.ModelRuntime.Credentials`.
- Adding new Lemon config or secret behavior means updating `apps/lemon_agent`, not provider modules in this app.

### Modifying the Streaming Pipeline

- Request building: each provider has a `build_request/4` private function
- SSE parsing: handled per-provider (Anthropic has its own parser; OpenAI family shares `OpenAIResponsesShared.process_stream/5`)
- Event emission: all providers push events via `EventStream.push_async/2` or `EventStream.push/2`
- Completion: providers call `EventStream.complete/2` on success, `EventStream.error/2` on failure

### Modifying Error Handling

- Error classification: `LemonAi.Error.classify_status/1` (private) and `LemonAi.Error.parse_http_error/3`
- Retry logic: `LemonAi.Error.retryable?/1` and `LemonAi.Error.suggested_retry_delay/1`
- Provider-specific error messages: `LemonAi.Error.extract_provider_message/1` handles Anthropic, OpenAI, Google, AWS, atom-key Elixir maps and enum values, OAuth-style `error_description`, string error codes with sibling `message` / `detail` / `description`, symbolic `type` / string `code` prefixes with direct or nested effective messages, FastAPI/Pydantic `detail` arrays, JSON:API-style `errors[].detail` / `errors[].title`, nested validation-array `error` objects, nested detail-array `error_description` / `error_message` / `description` formats, symbolic top-level error maps whose actionable text lives under nested `details`, and placeholder-empty top-level messages with actionable nested details
- Provider body retry hints: `LemonAi.Error.parse_http_error/3` merges `retry_after`, `retryAfter`, `retry_after_ms`, `retryAfterMs`, and Google `RetryInfo.retryDelay` into `rate_limit_info.retry_after` when retry headers are absent

## How This App Connects to Other Umbrella Apps

- **`coding_agent`** (consumer): Uses `LemonAi.stream/3` and `LemonAi.complete/3` for LLM calls during coding sessions; resolves models via `LemonAi.Models`
- **`agent_core`** (consumer): Orchestrates multi-turn LLM conversations using `LemonAi.Types.Context`, `LemonAi.stream/3`, and tool-call handling
- **`lemon_automation`** (consumer): Uses `LemonAi` for automated LLM calls in cron jobs and routines

## Debugging Tips

- Set `LEMON_AI_HTTP_TRACE=1` to see all HTTP requests/responses in logs
- Set `LEMON_AI_DEBUG=1` to dump raw SSE events from Anthropic to `/tmp/lemon_anthropic_sse.log`
- Set `LEMON_AI_PROMPT_DIAGNOSTICS=1` to log prompt sizes and token usage for every call
- Check `~/.lemon/logs/http-errors/` for saved 4xx error dumps from `LemonAi.HttpInspector`
- Use `LemonAi.CircuitBreaker.get_state(:provider)` to inspect circuit breaker status
- Use `LemonAi.CallDispatcher.get_state()` to see concurrency caps and active request counts
- Use `LemonAi.ModelCache.stats()` to inspect cache entries
OpenAI-compatible providers must resolve provider-specific API keys before falling back to `OPENAI_API_KEY` (for example `ZAI_API_KEY`, `MINIMAX_API_KEY`, `FIREWORKS_API_KEY`).
