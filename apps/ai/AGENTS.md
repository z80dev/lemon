# AI App - Agent Guidelines

## Purpose and Responsibilities

The `ai` app provides a unified LLM API abstraction layer for the Lemon platform. It enables seamless interaction with multiple AI providers (Anthropic, OpenAI, Google, AWS Bedrock, etc.) through a consistent streaming interface.

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
  │                       ├── Ai.CircuitBreaker (per-provider)
  │                       ├── Ai.RateLimiter (per-provider)
  │                       └── Provider Module
  │                               │
  │                               └── Ai.EventStream (async events)
  │
  └── Ai.complete/3 (blocking wrapper around stream)
```

### Core Components

| Module | Purpose |
|--------|---------|
| `Ai` | Main public API |
| `Ai.Provider` | Behaviour for provider implementations |
| `Ai.ProviderRegistry` | `:persistent_term` registry (crash-resilient) |
| `Ai.ProviderSupervisor` | Dynamic supervisor for per-provider services |
| `Ai.CallDispatcher` | Routes calls through circuit breaker + rate limiter |
| `Ai.CircuitBreaker` | Per-provider fault tolerance (closed/open/half-open) |
| `Ai.RateLimiter` | Token bucket rate limiting per provider |
| `Ai.ModelCache` | ETS-backed model availability cache |
| `Ai.EventStream` | Async event streaming with lifecycle management |
| `Ai.Models` | Model definitions and metadata |
| `Ai.Types` | Core type definitions |

## Provider Behaviour

All providers implement `Ai.Provider`:

```elixir
defmodule Ai.Provider do
  @callback stream(Model.t(), Context.t(), StreamOptions.t()) ::
              {:ok, EventStream.t()} | {:error, term()}
  
  @callback provider_id() :: atom()
  @callback api_id() :: atom()
  @callback get_env_api_key() :: String.t() | nil  # optional
end
```

### Provider Registration

Providers are registered at startup in `Ai.Application.register_providers/0`:

```elixir
Ai.ProviderRegistry.register(:anthropic_messages, Ai.Providers.Anthropic)
Ai.ProviderRegistry.register(:openai_responses, Ai.Providers.OpenAIResponses)
# etc.
```

The registry uses `:persistent_term` for O(1) lookups that survive process crashes.

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
    # Start event stream
    {:ok, stream} = EventStream.start_link(owner: self(), max_queue: 10_000, timeout: 300_000)
    
    # Start streaming task under supervision
    {:ok, task_pid} = Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
      do_stream(stream, model, context, opts)
    end)
    
    EventStream.attach_task(stream, task_pid)
    {:ok, stream}
  end
  
  defp do_stream(stream, model, context, opts) do
    # 1. Build request
    # 2. Make HTTP request (use Req with streaming)
    # 3. Push events via EventStream.push_async/2
    # 4. Call EventStream.complete/2 or EventStream.error/2
  end
end
```

### 2. Add Model Definitions

Add models to `Ai.Models`:

```elixir
@my_provider_models %{
  "my-model-id" => %Types.Model{
    id: "my-model-id",
    name: "My Model",
    api: :my_provider_api,  # matches registered api_id
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

### 3. Register Provider

Add to `Ai.Application.register_providers/0`:

```elixir
def register_providers do
  # ... existing registrations
  Ai.ProviderRegistry.register(:my_provider_api, Ai.Providers.MyProvider)
end
```

### 4. Test the Provider

Create `test/providers/my_provider_test.exs`:

```elixir
defmodule Ai.Providers.MyProviderTest do
  use ExUnit.Case
  
  alias Ai.Providers.MyProvider
  alias Ai.Types.{Context, Model, StreamOptions}
  
  test "streams response successfully" do
    model = Ai.Models.get_model(:my_provider, "my-model-id")
    context = Context.new(system_prompt: "You are helpful")
    context = Context.add_user_message(context, "Hello!")
    opts = %StreamOptions{}
    
    {:ok, stream} = MyProvider.stream(model, context, opts)
    
    events = EventStream.events(stream) |> Enum.to_list()
    assert [{:start, _}, {:text_delta, 0, "Hi", _} | _] = events
  end
end
```

## Circuit Breaker & Rate Limiting

### Circuit Breaker Pattern

The `Ai.CircuitBreaker` module implements three states:

- **Closed** (normal): Requests pass through
- **Open** (failure threshold reached): Requests rejected immediately  
- **Half-Open** (recovery timeout elapsed): Limited requests allowed to test recovery

**Configuration** (via `config/config.exs`):

```elixir
config :ai, :circuit_breaker,
  failure_threshold: 5,      # failures before opening
  recovery_timeout: 30_000   # ms before attempting recovery
```

**Manual Control**:

```elixir
Ai.CircuitBreaker.is_open?(:anthropic)        # check state
Ai.CircuitBreaker.reset(:anthropic)           # manual reset
Ai.CircuitBreaker.get_state(:anthropic)       # get full state
```

### Rate Limiter Pattern

The `Ai.RateLimiter` uses token bucket algorithm:

**Configuration**:

```elixir
config :ai, :rate_limiter,
  tokens_per_second: 10,  # refill rate
  max_tokens: 20          # bucket capacity
```

### Call Dispatcher

The dispatcher coordinates both patterns:

```elixir
Ai.CallDispatcher.dispatch(:anthropic, fn ->
  # Your API call here
  Ai.Providers.Anthropic.stream(model, context, opts)
end)
# Returns: {:ok, stream} | {:error, :circuit_open} | {:error, :rate_limited}
```

**Concurrency Control**:

```elixir
Ai.CallDispatcher.set_concurrency_cap(:anthropic, 20)
Ai.CallDispatcher.get_active_requests(:anthropic)
```

## Event Streaming

### Event Types

```elixir
{:start, AssistantMessage.t()}                    # Stream started
{:text_start, idx, AssistantMessage.t()}          # Text block started
{:text_delta, idx, String.t(), AssistantMessage.t()}  # Text chunk
{:text_end, idx, String.t(), AssistantMessage.t()}    # Text block complete
{:thinking_start, idx, AssistantMessage.t()}      # Thinking block started
{:thinking_delta, idx, String.t(), AssistantMessage.t()}
{:thinking_end, idx, String.t(), AssistantMessage.t()}
{:tool_call_start, idx, AssistantMessage.t()}     # Tool call started
{:tool_call_delta, idx, String.t(), AssistantMessage.t()}
{:tool_call_end, idx, ToolCall.t(), AssistantMessage.t()}
{:done, stop_reason, AssistantMessage.t()}        # Stream completed
{:error, stop_reason, AssistantMessage.t()}       # Stream error
{:canceled, reason}                               # Stream canceled
```

### Consuming Events

```elixir
# Stream events
{:ok, stream} = Ai.stream(model, context)

stream
|> Ai.EventStream.events()
|> Enum.each(fn
  {:text_delta, _idx, delta, _partial} -> IO.write(delta)
  {:done, _reason, message} -> IO.puts("\nDone: #{message.stop_reason}")
  {:error, _reason, message} -> IO.puts("Error: #{message.error_message}")
  _ -> :ok
end)

# Or get complete result
{:ok, message} = Ai.EventStream.result(stream)
text = Ai.get_text(message)
```

### Stream Lifecycle

- Streams are linked to owner process (auto-cancel on owner death)
- Tasks are supervised under `Ai.StreamTaskSupervisor`
- Streams have configurable timeout (default 5 minutes)
- Backpressure via `:max_queue` and `:drop_strategy` options

## Common Tasks

### Making a Simple Request

```elixir
model = Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
context = Ai.Context.new(system_prompt: "You are helpful")
context = Ai.Context.add_user_message(context, "Explain OTP")

{:ok, message} = Ai.complete(model, context, %{temperature: 0.7})
text = Ai.get_text(message)
```

### Streaming with Tools

```elixir
tools = [
  %Ai.Types.Tool{
    name: "get_weather",
    description: "Get weather for a location",
    parameters: %{
      type: "object",
      properties: %{
        location: %{type: "string", description: "City name"}
      },
      required: ["location"]
    }
  }
]

context = Ai.Context.new(tools: tools)
context = Ai.Context.add_user_message(context, "What's the weather in Paris?")

{:ok, stream} = Ai.stream(model, context)

events
|> Enum.each(fn
  {:tool_call_end, _idx, tool_call, _msg} ->
    # Execute tool: tool_call.name, tool_call.arguments
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

context = Ai.Context.add_tool_result(context, result)
```

### Calculating Cost

```elixir
{:ok, message} = Ai.complete(model, context)
cost = Ai.calculate_cost(model, message.usage)
# cost.total in dollars
```

## Testing Guidance

### Running Tests

```bash
# All ai tests
mix test apps/ai

# Specific test file
mix test apps/ai/test/ai/circuit_breaker_test.exs

# Integration tests (requires API keys)
mix test apps/ai/test/integration --include integration

# Specific provider tests
mix test apps/ai/test/providers/anthropic_test.exs
```

### Test Structure

| Directory | Purpose |
|-----------|---------|
| `test/ai/` | Core module tests |
| `test/providers/` | Provider implementation tests |
| `test/integration/` | Live API tests (requires keys) |

### Mocking HTTP Requests

Use `Req.Test` for HTTP mocking:

```elixir
test "handles API error" do
  Req.Test.stub(MyProvider, fn conn ->
    Req.Test.json(conn, %{error: %{message: "Rate limited"}}, status: 429)
  end)
  
  model = %{model | base_url: "http://localhost:#{bypass.port}"}
  {:ok, stream} = MyProvider.stream(model, context, %StreamOptions{})
  
  events = EventStream.events(stream) |> Enum.to_list()
  assert [{:error, :error, %{error_message: msg}}] = events
  assert msg =~ "Rate limited"
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

Create `test/integration/my_provider_live_test.exs`:

```elixir
defmodule Ai.Integration.MyProviderLiveTest do
  use ExUnit.Case
  
  @moduletag :integration
  
  test "live streaming works" do
    model = Ai.Models.get_model(:my_provider, "my-model")
    context = Ai.Context.new() |> Ai.Context.add_user_message("Hello")
    
    {:ok, stream} = Ai.stream(model, context)
    message = Ai.EventStream.result(stream)
    
    assert {:ok, %Ai.Types.AssistantMessage{}} = message
    assert message.content != []
  end
end
```

Run with: `mix test --include integration`

## Environment Variables

| Variable | Used By | Purpose |
|----------|---------|---------|
| `ANTHROPIC_API_KEY` | Anthropic provider | API authentication |
| `OPENAI_API_KEY` | OpenAI providers | API authentication |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Bedrock | AWS credentials |
| `GOOGLE_API_KEY` | Google providers | API authentication |
| `LEMON_AI_DEBUG` | All providers | Enable debug logging |
| `LEMON_AI_DEBUG_FILE` | All providers | Debug log path |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | Kimi provider | History limit |

## Key Dependencies

- `lemon_core` - Shared primitives and telemetry
- `req` - HTTP client with streaming support
- `jason` - JSON encoding/decoding
- `nimble_options` - Options validation
