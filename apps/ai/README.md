# Ai

Unified LLM provider abstraction and streaming runtime for the Lemon platform. This
OTP application delivers a single API surface for interacting with more than twenty
LLM providers -- Anthropic, OpenAI, Google, AWS Bedrock, Azure, GitHub Copilot, and
many others -- while managing streaming lifecycles, rate limiting, circuit breaking,
and cost tracking behind the scenes.

## Architecture Overview

```
Ai.stream/3  or  Ai.complete/3
  |
  v
Ai.ProviderRegistry          -- O(1) :persistent_term lookup by api_id
  |
  v
Ai.CallDispatcher.dispatch/2 -- GenServer coordination layer
  |  |  |
  |  |  +-- Ai.CircuitBreaker (per-provider, lazy-started via DynamicSupervisor)
  |  +-- Ai.RateLimiter       (per-provider, lazy-started via DynamicSupervisor)
  |
  v
Ai.Provider.stream/3          -- provider behaviour callback
  |
  v
Ai.EventStream                -- async GenServer: bounded queue, backpressure,
                                  owner monitoring, task linking, timeout
```

Every call flows through the dispatcher, which checks the circuit breaker, acquires
a rate-limit permit, enforces per-provider concurrency caps, then invokes the
provider. Streaming responses are delivered through an `Ai.EventStream` GenServer
that the caller consumes as a lazy `Stream`.

### Supervision Tree

```
Ai.Supervisor (one_for_one)
  +-- Task.Supervisor  (name: Ai.StreamTaskSupervisor)
  +-- Registry         (name: Ai.RateLimiterRegistry)
  +-- Registry         (name: Ai.CircuitBreakerRegistry)
  +-- Ai.ProviderSupervisor   (DynamicSupervisor -- spawns per-provider GenServers)
  +-- Ai.CallDispatcher        (GenServer)
  +-- Ai.ModelCache            (GenServer, ETS-backed)
```

`Ai.ProviderRegistry` lives outside the supervision tree -- it uses
`:persistent_term` directly so provider mappings survive process restarts.

## Module Inventory

### Core Modules

| Module | Purpose |
|--------|---------|
| `Ai` | Public API: `stream/3`, `complete/3`, `get_text/1`, `get_thinking/1`, `get_tool_calls/1`, `calculate_cost/2`, `new_context/1` |
| `Ai.Provider` | Behaviour (`stream/3`, `provider_id/0`, `api_id/0`, optional `get_env_api_key/0`) |
| `Ai.ProviderRegistry` | `:persistent_term` registry for O(1) provider lookups by `api_id` |
| `Ai.ProviderSupervisor` | `DynamicSupervisor` for per-provider circuit breakers and rate limiters |
| `Ai.CallDispatcher` | Routes calls through circuit breaker + rate limiter + concurrency cap; tracks streaming task results |
| `Ai.CircuitBreaker` | Per-provider GenServer (closed / open / half-open), lazy-started under `ProviderSupervisor` |
| `Ai.RateLimiter` | Token-bucket GenServer per provider, lazy-started under `ProviderSupervisor` |
| `Ai.ModelCache` | ETS-backed model availability cache with configurable TTL (default 5 minutes) |
| `Ai.EventStream` | Async GenServer for streaming events: bounded queue, backpressure, owner monitoring, task linking, cancellation, timeout |
| `Ai.Models` | Compile-time registry of all model definitions and metadata across all providers |
| `Ai.Types` | All struct/type definitions: `Model`, `Context`, `StreamOptions`, `AssistantMessage`, `UserMessage`, `ToolResultMessage`, `ToolCall`, `TextContent`, `ThinkingContent`, `ImageContent`, `Tool`, `Usage`, `Cost`, `ModelCost` |
| `Ai.Error` | HTTP error parsing, classification (`:rate_limit`, `:auth`, `:client`, `:server`, `:transient`), retry advice, formatting |
| `Ai.HttpInspector` | Captures and saves sanitized request dumps for 4xx errors to `~/.lemon/logs/http-errors/` |
| `Ai.PromptDiagnostics` | Opt-in prompt size and token usage diagnostics (enabled via `LEMON_AI_PROMPT_DIAGNOSTICS=1`) |

### Provider Modules

| Module | `api_id` | Covers |
|--------|----------|--------|
| `Ai.Providers.Anthropic` | `:anthropic_messages` | Anthropic Claude (also Kimi, OpenCode via same wire format) |
| `Ai.Providers.OpenAICompletions` | `:openai_completions` | OpenAI Chat Completions and compatible APIs (Groq, Mistral, xAI, Cerebras, OpenRouter, HuggingFace, etc.) |
| `Ai.Providers.OpenAIResponses` | `:openai_responses` | OpenAI Responses API |
| `Ai.Providers.OpenAICodexResponses` | `:openai_codex_responses` | OpenAI Codex (ChatGPT JWT auth) |
| `Ai.Providers.AzureOpenAIResponses` | `:azure_openai_responses` | Azure OpenAI |
| `Ai.Providers.Google` | `:google_generative_ai` | Google AI Studio (Gemini) |
| `Ai.Providers.GoogleVertex` | `:google_vertex` | Google Vertex AI |
| `Ai.Providers.GoogleGeminiCli` | `:google_gemini_cli` | Google Cloud Code Assist / Gemini CLI |
| `Ai.Providers.Bedrock` | `:bedrock_converse_stream` | AWS Bedrock Converse Stream |

### Provider Helpers

| Module | Purpose |
|--------|---------|
| `Ai.Providers.GoogleShared` | Shared content/tool conversion, stop-reason mapping, thought-signature handling for all Google providers |
| `Ai.Providers.OpenAIResponsesShared` | Shared message/tool conversion, stream processing, `function_call_output` size guards for OpenAI Responses family |
| `Ai.Providers.HttpTrace` | HTTP request/response trace logging (enabled via `LEMON_AI_HTTP_TRACE=1`) |
| `Ai.Providers.TextSanitizer` | UTF-8 sanitization for streamed text (replaces invalid sequences with U+FFFD) |

### Auth Modules

| Module | Purpose |
|--------|---------|
| `Ai.Auth.OAuthSecretResolver` | Central dispatcher -- routes encrypted secret payloads to provider-specific OAuth resolvers |
| `Ai.Auth.GitHubCopilotOAuth` | GitHub Copilot device-code login, Copilot token refresh, secret encoding/decoding |
| `Ai.Auth.GoogleAntigravityOAuth` | Google Antigravity PKCE OAuth: authorize URL, token exchange/refresh, secret resolver |
| `Ai.Auth.OpenAICodexOAuth` | OpenAI Codex PKCE OAuth: authorize URL, code exchange, token refresh, JWT extraction |
| `Ai.Auth.OAuthPKCE` | PKCE verifier/challenge generation utility |

### Model Definition Modules

Each provider has a dedicated module under `Ai.Models.*` that returns a
`%{String.t() => Model.t()}` map at compile time:

`Ai.Models.Anthropic`, `Ai.Models.OpenAI`, `Ai.Models.AmazonBedrock`,
`Ai.Models.Google`, `Ai.Models.GoogleVertex`, `Ai.Models.GoogleGeminiCLI`,
`Ai.Models.AzureOpenAI`, `Ai.Models.GitHubCopilot`, `Ai.Models.Groq`,
`Ai.Models.Mistral`, `Ai.Models.XAI`, `Ai.Models.Cerebras`,
`Ai.Models.DeepSeek`, `Ai.Models.Qwen`, `Ai.Models.MiniMax`,
`Ai.Models.MiniMaxCN`, `Ai.Models.ZAI`, `Ai.Models.Kimi`,
`Ai.Models.KimiCoding`, `Ai.Models.OpenCode`, `Ai.Models.HuggingFace`,
`Ai.Models.OpenRouter`, `Ai.Models.VercelAIGateway`

## Supported Providers

The `@providers` list in `Ai.Models` enumerates all supported provider atoms:

`:anthropic`, `:openai`, `:"openai-codex"`, `:amazon_bedrock`, `:google`,
`:google_antigravity`, `:kimi`, `:kimi_coding`, `:opencode`, `:xai`,
`:mistral`, `:cerebras`, `:deepseek`, `:qwen`, `:minimax`, `:zai`,
`:azure_openai_responses`, `:github_copilot`, `:google_gemini_cli`,
`:google_vertex`, `:groq`, `:huggingface`, `:minimax_cn`, `:openrouter`,
`:vercel_ai_gateway`

## Usage Examples

### Creating a Context and Streaming

```elixir
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")

context =
  Ai.new_context(system_prompt: "You are a helpful assistant")
  |> Ai.Types.Context.add_user_message("Explain OTP in three sentences.")

{:ok, stream} = Ai.stream(model, context, %{temperature: 0.7, reasoning: :medium})

stream
|> Ai.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta, _partial} -> IO.write(delta)
  {:thinking_delta, _idx, delta, _partial} -> IO.write(["[think] ", delta])
  {:done, _reason, _message} -> IO.puts("\n-- done --")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)
```

### Blocking Completion

```elixir
{:ok, message} = Ai.complete(model, context)

text     = Ai.get_text(message)
thinking = Ai.get_thinking(message)
calls    = Ai.get_tool_calls(message)
```

### Tool Use

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

context = Ai.new_context(system_prompt: "You can check weather.", tools: tools)
context = Ai.Types.Context.add_user_message(context, "Weather in Paris?")

{:ok, message} = Ai.complete(model, context)

for tc <- Ai.get_tool_calls(message) do
  result = %Ai.Types.ToolResultMessage{
    tool_call_id: tc.id,
    tool_name: tc.name,
    content: [%Ai.Types.TextContent{text: "Sunny, 22C"}],
    is_error: false
  }

  context = Ai.Types.Context.add_assistant_message(context, message)
  context = Ai.Types.Context.add_tool_result(context, result)
  {:ok, final} = Ai.complete(model, context)
  IO.puts(Ai.get_text(final))
end
```

### Cost Calculation

```elixir
{:ok, message} = Ai.complete(model, context)
cost = Ai.calculate_cost(model, message.usage)
# cost.total, cost.input, cost.output, cost.cache_read, cost.cache_write  (dollars)
```

### EventStream Utilities

```elixir
# Collect all text into a single string
text = Ai.EventStream.collect_text(stream)

# Wait for the final AssistantMessage (blocking)
{:ok, message} = Ai.EventStream.result(stream)

# Inspect queue stats
%{queue_size: _, max_queue: _, dropped: _} = Ai.EventStream.stats(stream)

# Cancel a running stream
Ai.EventStream.cancel(stream, :user_requested)
```

### Model Lookup

```elixir
# Lookup by provider + model id
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")

# Search across all providers by model id string
model = Ai.Models.find_by_id("gpt-4o")

# List all models for a provider
models = Ai.Models.get_models(:openai)

# All known providers
providers = Ai.Models.get_providers()

# Capability queries
Ai.Models.supports_vision?(model)
Ai.Models.supports_reasoning?(model)
Ai.Models.supports_xhigh(model)
```

### Error Handling

```elixir
Ai.Error.format_error(:rate_limited)
# => "Request rate limited. Please wait before retrying."

Ai.Error.retryable?(:timeout)
# => true

Ai.Error.auth_error?({:http_error, 401, "Unauthorized"})
# => true

Ai.Error.suggested_retry_delay({:http_error, 429, _body})
# => 60_000

parsed = Ai.Error.parse_http_error(429, response_body, headers)
# parsed.category, parsed.message, parsed.retryable, parsed.rate_limit_info
```

## Configuration

### Application Config (`config/config.exs`)

```elixir
config :ai, :circuit_breaker,
  failure_threshold: 5,       # failures before opening (default: 5)
  recovery_timeout: 30_000    # ms before half-open recovery (default: 30_000)

config :ai, :rate_limiter,
  tokens_per_second: 10,      # token refill rate (default: 10)
  max_tokens: 20              # bucket capacity (default: 20)

config :ai, Ai.CallDispatcher,
  stream_result_timeout_ms: 300_000   # how long dispatcher tracks streams
```

### Runtime Configuration via `Ai.CallDispatcher`

```elixir
Ai.CallDispatcher.set_concurrency_cap(:anthropic, 20)
Ai.CallDispatcher.get_active_requests(:anthropic)
Ai.CallDispatcher.get_state()
```

### Circuit Breaker Control

```elixir
Ai.CircuitBreaker.is_open?(:anthropic)
Ai.CircuitBreaker.reset(:anthropic)
Ai.CircuitBreaker.get_state(:anthropic)
```

## Key Types

All types are defined in `Ai.Types`:

```elixir
%Ai.Types.Model{
  id: String.t(),
  name: String.t(),
  api: atom(),               # must match registered api_id in ProviderRegistry
  provider: atom(),           # keyed for circuit breaker / rate limiter
  base_url: String.t(),
  reasoning: boolean(),
  input: [:text | :image],
  cost: %Ai.Types.ModelCost{input: float(), output: float(), ...},
  context_window: non_neg_integer(),
  max_tokens: non_neg_integer(),
  headers: map(),             # extra HTTP headers for this model
  compat: map() | nil         # provider-specific overrides
}

%Ai.Types.StreamOptions{
  temperature: float() | nil,
  max_tokens: non_neg_integer() | nil,
  api_key: String.t() | nil,
  session_id: String.t() | nil,
  headers: map(),
  reasoning: :minimal | :low | :medium | :high | :xhigh | nil,
  thinking_budgets: map(),
  stream_timeout: timeout(),        # default 300_000ms
  tool_choice: atom() | nil,
  project: String.t() | nil,        # GCP project for Vertex
  location: String.t() | nil,       # GCP location for Vertex
  access_token: String.t() | nil,   # OAuth token for Vertex/GeminiCli
  service_account_json: String.t() | nil
}

%Ai.Types.Context{
  system_prompt: String.t() | nil,
  messages: [message()],       # stored newest-first for O(1) append
  tools: [Tool.t()]
}
```

**Important:** `Context.messages` is stored in reverse order (newest first). Use
`Context.get_messages_chronological/1` when passing messages to an LLM API.

## Event Types

Events emitted by `Ai.EventStream`:

```elixir
{:start, AssistantMessage.t()}
{:text_start, idx, AssistantMessage.t()}
{:text_delta, idx, String.t(), AssistantMessage.t()}
{:text_end, idx, String.t(), AssistantMessage.t()}
{:thinking_start, idx, AssistantMessage.t()}
{:thinking_delta, idx, String.t(), AssistantMessage.t()}
{:thinking_end, idx, String.t(), AssistantMessage.t()}
{:tool_call_start, idx, AssistantMessage.t()}
{:tool_call_delta, idx, String.t(), AssistantMessage.t()}
{:tool_call_end, idx, ToolCall.t(), AssistantMessage.t()}
{:done, stop_reason, AssistantMessage.t()}
{:error, stop_reason, AssistantMessage.t()}
{:canceled, reason}
```

`stop_reason` is one of `:stop | :length | :tool_use | :error | :aborted`.

## Environment Variables

| Variable | Provider/Module | Purpose |
|----------|-----------------|---------|
| `ANTHROPIC_API_KEY` | Anthropic | API authentication |
| `OPENAI_API_KEY` | OpenAI family | API authentication |
| `OPENAI_CODEX_API_KEY` / `CHATGPT_TOKEN` | OpenAI Codex | JWT token (env-first; also supports OAuth secret payloads) |
| `OPENAI_CODEX_OAUTH_CLIENT_ID` | `Ai.Auth.OpenAICodexOAuth` | Override OAuth client ID |
| `AZURE_OPENAI_API_KEY` | Azure OpenAI | API authentication |
| `AZURE_OPENAI_BASE_URL` | Azure OpenAI | Full base URL (optional) |
| `AZURE_OPENAI_RESOURCE_NAME` | Azure OpenAI | Resource name (if no base URL) |
| `AZURE_OPENAI_API_VERSION` | Azure OpenAI | API version (default: "v1") |
| `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` | Azure OpenAI | Comma-separated `model=deployment` mappings |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Bedrock | AWS credentials |
| `AWS_REGION` | Bedrock | AWS region (default: `us-east-1`) |
| `GOOGLE_GENERATIVE_AI_API_KEY` | Google AI Studio | API key (also checks `GOOGLE_API_KEY`, `GEMINI_API_KEY`) |
| `GOOGLE_CLOUD_PROJECT` / `GCLOUD_PROJECT` | Google Vertex | GCP project ID |
| `GOOGLE_CLOUD_LOCATION` | Google Vertex | GCP region |
| `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID` | `Ai.Auth.GoogleAntigravityOAuth` | Optional env fallback for OAuth client ID |
| `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET` | `Ai.Auth.GoogleAntigravityOAuth` | Optional env fallback for OAuth client secret |
| `LEMON_AI_HTTP_TRACE` | `Ai.Providers.HttpTrace` | Set to `"1"` to enable HTTP trace logging |
| `LEMON_AI_DEBUG` | Anthropic | Set to `"1"` to log raw SSE events |
| `LEMON_AI_DEBUG_FILE` | Anthropic | SSE log file path (default: `/tmp/lemon_anthropic_sse.log`) |
| `LEMON_AI_PROMPT_DIAGNOSTICS` | `Ai.PromptDiagnostics` | Set to `"1"` to enable prompt size/usage logging |
| `LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL` | `Ai.PromptDiagnostics` | Log level for diagnostics (default: `info`) |
| `LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N` | `Ai.PromptDiagnostics` | Number of largest messages to report (default: 5) |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | Anthropic (Kimi) | Max history messages for Kimi models (default: 200) |
| `PI_CACHE_RETENTION` | OpenAI Responses | Set to `"long"` for 24h prompt cache retention |

## How to Add a New Provider

### 1. Create the Provider Module

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
    {:ok, stream} = EventStream.start_link(
      owner: self(),
      max_queue: 10_000,
      timeout: opts.stream_timeout || 300_000
    )

    {:ok, task_pid} = Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
      do_stream(stream, model, context, opts)
    end)

    EventStream.attach_task(stream, task_pid)
    {:ok, stream}
  end

  defp do_stream(stream, model, context, opts) do
    # 1. Build request body from context
    # 2. Make HTTP request with Req (into: :self for streaming)
    # 3. Push events:  EventStream.push_async(stream, {:text_delta, 0, text, partial})
    # 4. On success:   EventStream.complete(stream, final_assistant_message)
    # 5. On error:     EventStream.error(stream, error_assistant_message)
  end
end
```

### 2. Add Model Definitions

Create `lib/ai/models/my_provider.ex` with a `models/0` function returning a
`%{String.t() => Model.t()}` map. Then add the provider to the `@models` and
`@providers` lists in `Ai.Models`.

### 3. Register the Provider

Add the registration call to `Ai.Application.register_providers/0`:

```elixir
Ai.ProviderRegistry.register(:my_provider_api, Ai.Providers.MyProvider)
```

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `lemon_core` (umbrella) | Shared primitives: `LemonCore.Telemetry.emit/3`, `LemonCore.Secrets`, `LemonCore.Introspection` |
| `req ~> 0.5` | HTTP client with streaming support; `Req.Test` for test mocking |
| `jason ~> 1.4` | JSON encoding/decoding |
| `nimble_options ~> 1.1` | Options validation |
| `plug ~> 1.16` (test only) | Required for `Req.Test` stub via `Plug.Conn` |

## Testing

```bash
# Run all ai tests from the umbrella root
mix test apps/ai

# Run a specific test file
mix test apps/ai/test/ai/circuit_breaker_test.exs

# Run integration tests (requires API keys, excluded by default)
mix test apps/ai/test/integration --include integration
```

HTTP requests are mocked with `Req.Test` stubs. See existing provider tests
under `test/providers/` for patterns.
