# AI Provider Duplication Analysis

## Executive Summary

Extensive code duplication found across 8 AI provider implementations (Anthropic, OpenAI Completions, OpenAI Responses, OpenAI Codex, Azure OpenAI, Bedrock, Google, Google Vertex, Google Gemini CLI). Three major categories of duplication identified with specific recommendations for shared helpers.

---

## 1. IDENTICAL SSE PARSING LOGIC

### Pattern: `parse_sse_chunk/1`

**Exact duplicate** across 3 providers with **zero variation**:

**Files:**
- `/Users/z80/dev/lemon/apps/ai/lib/ai/providers/openai_responses.ex:556-586`
- `/Users/z80/dev/lemon/apps/ai/lib/ai/providers/openai_codex_responses.ex:525-553`
- `/Users/z80/dev/lemon/apps/ai/lib/ai/providers/azure_openai_responses.ex:421-449`

**Code:**
```elixir
defp parse_sse_chunk(buffer) do
  # Split by double newlines (SSE event delimiter)
  parts = String.split(buffer, "\n\n")

  # Last part might be incomplete
  {complete_parts, [incomplete]} =
    if length(parts) > 1 do
      Enum.split(parts, -1)
    else
      {[], parts}
    end

  events =
    complete_parts
    |> Enum.flat_map(fn part ->
      part
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&String.trim_leading(&1, "data:"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" || &1 == "[DONE]"))
      |> Enum.flat_map(fn data ->
        case Jason.decode(data) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)
    end)

  {events, incomplete}
end
```

**Recommendation:**
Move to shared helper module `Ai.Providers.SSEParser` with public function:
```elixir
@spec parse_sse_chunk(String.t()) :: {[map()], String.t()}
def parse_sse_chunk(buffer) do
  # ... implementation
end
```

**Impact:**
- Replace 63 lines (3 × 21 lines) with 1 import + 1 function call
- Used by: `openai_responses.ex`, `openai_codex_responses.ex`, `azure_openai_responses.ex`

---

## 2. EXPONENTIAL BACKOFF RETRY DELAY (WITH JITTER)

### Pattern: `retry_delay_ms/1` and `retry_delay_with_jitter/2`

**Identical implementation** in 3 providers with different names:

**Files & Line Numbers:**
- `anthropic.ex:402-406` → `defp retry_delay_ms(attempt)`
- `google_gemini_cli.ex:886-890` → `defp retry_delay_with_jitter(base_ms, attempt)`
- `openai_codex_responses.ex:391-395` → `defp retry_delay_with_jitter(base_ms, attempt)`

**Code:**
```elixir
defp retry_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
  base = (@base_retry_delay_ms * :math.pow(2, attempt)) |> trunc()
  half = max(div(base, 2), 1)
  half + :rand.uniform(half)
end
```

**Variation:** Different base delay constants per provider:
- Anthropic: `@base_retry_delay_ms 400` (line 44)
- Google Gemini CLI: `@base_delay_ms 1000` (line 69)
- OpenAI Codex: Calls with varying base values at each retry site

**Recommendation:**
Create `Ai.Providers.RetryHelper` module:
```elixir
@spec exponential_backoff_with_jitter(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
def exponential_backoff_with_jitter(base_ms, attempt) when is_integer(attempt) and attempt >= 0 do
  base = (base_ms * :math.pow(2, attempt)) |> trunc()
  half = max(div(base, 2), 1)
  half + :rand.uniform(half)
end
```

Each provider supplies its own `base_ms` constant.

**Impact:**
- Replace 5 lines × 3 providers = 15 lines duplicated code
- Used by: `anthropic.ex`, `google_gemini_cli.ex`, `openai_codex_responses.ex`

---

## 3. ASSISTANT MESSAGE INITIALIZATION

### Pattern: `init_assistant_message/1`, `init_output/1`, `initial_output/1`

**Nearly identical** across 8 providers (different naming, same structure):

**Files:**
- `anthropic.ex:1258-1276` → `init_assistant_message(model)`
- `bedrock.ex:179-197` → `init_output(model)`
- `google.ex:131-142` → `init_output(model)`
- `google_vertex.ex:128-139` (lines not shown but matching pattern)
- `google_gemini_cli.ex:142-154` → `init_output(model)`
- `openai_responses.ex:592-610` → `initial_output(model)`
- `openai_codex_responses.ex:617-635` → `initial_output(model)`
- `azure_openai_responses.ex:455-473` → `initial_output(model)`

**Base Implementation (from anthropic.ex:1258-1276):**
```elixir
defp init_assistant_message(model) do
  %AssistantMessage{
    role: :assistant,
    content: [],
    api: model.api,                    # ← varies by provider
    provider: model.provider,
    model: model.id,
    usage: %Usage{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    },
    stop_reason: :stop,
    timestamp: System.system_time(:millisecond)
  }
end
```

**Variations:**
- Most use `api: model.api` (can read from model), some hardcode specific API
- Some initialize `usage: %Usage{cost: %Cost{}}` (shorthand, relies on struct defaults)
- All follow identical structure except for `api` field

**Recommendation:**
Create public helper in `Ai.Providers.AssistantMessageHelper`:
```elixir
@spec init_assistant_message(Model.t()) :: AssistantMessage.t()
def init_assistant_message(%Model{} = model) do
  %AssistantMessage{
    role: :assistant,
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: %Usage{
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 0,
      cost: %Cost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0, total: 0.0}
    },
    stop_reason: :stop,
    timestamp: System.system_time(:millisecond)
  }
end
```

For hardcoded API cases, allow optional override:
```elixir
@spec init_assistant_message(Model.t(), atom() | nil) :: AssistantMessage.t()
def init_assistant_message(%Model{} = model, api_override \\ nil) do
  api = api_override || model.api
  # ... same structure
end
```

**Impact:**
- Replace 18 lines × 8 providers = 144 lines duplicated
- Used by: all 8 providers
- **High-priority refactor** - largest duplication area

---

## 4. HTTP RETRYABLE STATUS CODES

### Pattern: `retryable_http_status?/1`

**Similar** with minor variations:

**Files:**
- `anthropic.ex:408-412` - Status list: [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
- `openai_codex_responses.ex:397-403` - Status list: [429, 500, 502, 503, 504] + regex for error text

**Code (anthropic.ex):**
```elixir
defp retryable_http_status?(status) when is_integer(status) do
  status in [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]
end

defp retryable_http_status?(_), do: false
```

**Code (openai_codex_responses.ex):**
```elixir
defp retryable_error?(status, error_text) do
  status in [429, 500, 502, 503, 504] ||
    Regex.match?(
      ~r/rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused/i,
      error_text
    )
end
```

**Recommendation:**
Create `Ai.Providers.RetryHelper` with configurable status lists:
```elixir
# Default retry statuses (broad, Anthropic's list)
@default_retryable_statuses [408, 409, 425, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524]

@spec retryable_http_status?(integer(), [integer()] | nil) :: boolean()
def retryable_http_status?(status, allowed_statuses \\ @default_retryable_statuses) do
  status in allowed_statuses
end

@spec retryable_error_text?(String.t()) :: boolean()
def retryable_error_text?(error_text) do
  Regex.match?(
    ~r/rate.?limit|overloaded|service.?unavailable|upstream.?connect|connection.?refused/i,
    error_text
  )
end
```

**Impact:**
- Eliminate duplication across retry logic modules
- Each provider imports and uses with their own status list if needed

---

## 5. RETRYABLE TRANSPORT ERROR DETECTION

### Pattern: `retryable_transport_error?/1` and `retryable_transport_reason?/1`

**Extensively duplicated** - Anthropic has most comprehensive list:

**Files:**
- `anthropic.ex:440-472` - Comprehensive error atom and pattern matching
- Google and other providers have simpler or incomplete versions

**Code (anthropic.ex:440-472):**
```elixir
defp retryable_transport_error?(%Req.TransportError{reason: reason}) do
  retryable_transport_reason?(reason)
end

defp retryable_transport_error?(reason), do: retryable_transport_reason?(reason)

defp retryable_transport_reason?(reason)
     when reason in [
            :timeout,
            :closed,
            :econnrefused,
            :econnreset,
            :enetdown,
            :enetwork_unreachable,
            :nxdomain,
            :ehostunreach,
            :unreachable
          ],
     do: true

defp retryable_transport_reason?({:tls_alert, {_alert, _detail}}), do: true
defp retryable_transport_reason?({:failed_connect, _}), do: true
defp retryable_transport_reason?({:closed, _}), do: true
defp retryable_transport_reason?(reason) when is_tuple(reason) do
  # Heuristic: tuples with error code might be Erlang errors
  case elem(reason, 0) do
    e when e in [:enotconn, :epipe, :econnaborted, :ebadf] -> true
    _ -> false
  end
end

defp retryable_transport_reason?(_), do: false
```

**Recommendation:**
Extract to `Ai.Providers.RetryHelper`:
```elixir
@retryable_transport_atoms [
  :timeout, :closed, :econnrefused, :econnreset, :enetdown,
  :enetwork_unreachable, :nxdomain, :ehostunreach, :unreachable
]

@spec retryable_transport_error?(any()) :: boolean()
def retryable_transport_error?(%Req.TransportError{reason: reason}) do
  retryable_transport_reason?(reason)
end

def retryable_transport_error?(reason), do: retryable_transport_reason?(reason)

@spec retryable_transport_reason?(any()) :: boolean()
defp retryable_transport_reason?(reason) when reason in @retryable_transport_atoms, do: true
defp retryable_transport_reason?({:tls_alert, {_alert, _detail}}), do: true
defp retryable_transport_reason?({:failed_connect, _}), do: true
defp retryable_transport_reason?({:closed, _}), do: true
defp retryable_transport_reason?(reason) when is_tuple(reason) do
  case elem(reason, 0) do
    e when e in [:enotconn, :epipe, :econnaborted, :ebadf] -> true
    _ -> false
  end
end
defp retryable_transport_reason?(_), do: false
```

**Impact:**
- Used by: `anthropic.ex`, and other providers have incomplete versions
- Consolidate error detection across all providers

---

## 6. ERROR MESSAGE EXTRACTION

### Pattern: `extract_error_message/1` and `extract_error_message/2`

**Similar patterns** with provider-specific variations:

**Files:**
- `anthropic.ex:1339-1355` - Handles body as binary or map, extracts "error" key
- `openai_completions.ex:1382-1398` - Similar logic
- `bedrock.ex:1375-1383` - Similar with "error" and "__type" keys
- `openai_codex_responses.ex:405-439` - More elaborate with "plan_type", "resets_at" parsing

**Base Implementation (anthropic.ex:1339-1355):**
```elixir
defp extract_error_message(body, status) when is_binary(body) do
  case Jason.decode(body) do
    {:ok, %{"error" => %{"message" => msg}}} -> msg
    _ -> "HTTP #{status}"
  end
end

defp extract_error_message(body, status) when is_map(body) do
  case body do
    %{"error" => %{"message" => msg}} -> msg
    _ -> "HTTP #{status}"
  end
end

defp extract_error_message(_, status), do: "HTTP #{status}"
```

**Recommendation:**
Create `Ai.Providers.ErrorHandler` with configurable extractors:
```elixir
@spec extract_error_message(any(), integer()) :: String.t()
def extract_error_message(body, status) do
  case decode_if_needed(body) do
    %{"error" => %{"message" => msg}} when is_binary(msg) -> msg
    %{"error" => %{"message" => msg}} -> Jason.encode!(msg)
    %{"message" => msg} when is_binary(msg) -> msg
    _ -> "HTTP #{status}"
  end
end

defp decode_if_needed(body) when is_binary(body) do
  case Jason.decode(body) do
    {:ok, map} -> map
    _ -> %{}
  end
end

defp decode_if_needed(body) when is_map(body), do: body
defp decode_if_needed(_), do: %{}
```

**Impact:**
- Replace ~15 lines × (8 providers with variations)
- Improve consistency in error handling

---

## 7. STREAMING INITIALIZATION PATTERN

### Pattern: EventStream setup in `stream/3` callback

**Identical pattern** across all 8 providers:

**Code Template (every provider):**
```elixir
@impl true
def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
  owner = self()
  stream_timeout = opts.stream_timeout || 300_000

  {:ok, stream} =
    EventStream.start_link(
      owner: owner,
      max_queue: 10_000,
      timeout: stream_timeout
    )

  {:ok, task_pid} =
    Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
      do_stream(stream, model, context, opts)
    end)

  EventStream.attach_task(stream, task_pid)

  {:ok, stream}
end
```

**Files with this exact pattern:**
- `anthropic.ex:64-87`
- `openai_completions.ex:77-96`
- `bedrock.ex:52-71`
- `google.ex:62-81`
- `google_vertex.ex:65-84`
- `google_gemini_cli.ex:91-110`
- `openai_responses.ex:70-86`
- `openai_codex_responses.ex:106-125`
- `azure_openai_responses.ex:81-97`

**Recommendation:**
Create macro or base helper in `Ai.Providers.StreamingHelper`:
```elixir
defmacro standard_stream_setup(do_stream_fun) do
  quote do
    @impl true
    def stream(%Model{} = model, %Context{} = context, %StreamOptions{} = opts) do
      owner = self()
      stream_timeout = opts.stream_timeout || 300_000

      {:ok, stream} =
        EventStream.start_link(
          owner: owner,
          max_queue: 10_000,
          timeout: stream_timeout
        )

      {:ok, task_pid} =
        Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
          unquote(do_stream_fun).(stream, model, context, opts)
        end)

      EventStream.attach_task(stream, task_pid)

      {:ok, stream}
    end
  end
end
```

Or provide a non-macro helper:
```elixir
@spec start_streaming(Model.t(), Context.t(), StreamOptions.t(), (pid(), Model.t(), Context.t(), StreamOptions.t() -> any())) :: {:ok, pid()}
def start_streaming(model, context, opts, do_stream_callback) do
  owner = self()
  stream_timeout = opts.stream_timeout || 300_000

  {:ok, stream} =
    EventStream.start_link(
      owner: owner,
      max_queue: 10_000,
      timeout: stream_timeout
    )

  {:ok, task_pid} =
    Task.Supervisor.start_child(Ai.StreamTaskSupervisor, fn ->
      do_stream_callback.(stream, model, context, opts)
    end)

  EventStream.attach_task(stream, task_pid)

  {:ok, stream}
end
```

**Impact:**
- Replace 15 lines × 8 providers = 120 lines duplicated
- Large simplification opportunity

---

## 8. REQUEST HEADER BUILDING

### Pattern: Common headers (Content-Type, Authorization, etc.)

**Similar structures** with provider-specific variations:

**Files:**
- `anthropic.ex:914` - `build_headers(api_key, model_headers, opts_headers, provider)`
- `openai_completions.ex:194` - `build_headers(model, context, api_key, opts)`
- `openai_responses.ex:257` - `build_headers(model, context, opts, api_key)`
- `google.ex:152` - `build_headers(api_key, model, opts)`
- Multiple Google variants with OAuth tokens

**General Pattern (example from google.ex):**
```elixir
defp build_headers(api_key, model, opts) do
  base = [
    {"Content-Type", "application/json"},
    {"x-goog-api-key", api_key}
  ]

  # Merge model headers
  merged = if model.headers, do: Enum.concat(base, model.headers), else: base

  # Merge options headers
  if opts.headers, do: Enum.concat(merged, opts.headers), else: merged
end
```

**Recommendation:**
Create `Ai.Providers.HeaderBuilder`:
```elixir
@spec merge_headers([tuple()], [tuple()] | nil, [tuple()] | nil) :: [tuple()]
def merge_headers(base_headers, model_headers, opts_headers) do
  merged = if model_headers, do: Enum.concat(base_headers, model_headers), else: base_headers
  if opts_headers, do: Enum.concat(merged, opts_headers), else: merged
end

@spec build_api_key_header(String.t()) :: tuple()
def build_api_key_header(api_key) when is_binary(api_key) do
  {"Authorization", "Bearer #{api_key}"}
end

@spec build_api_key_header_x_goog(String.t()) :: tuple()
def build_api_key_header_x_goog(api_key) when is_binary(api_key) do
  {"x-goog-api-key", api_key}
end
```

**Impact:**
- 5-15 lines of header logic in each of 8 providers
- Significant DRY improvement

---

## 9. STREAM TIMEOUT HANDLING

### Pattern: `stream_timeout = opts.stream_timeout || 300_000`

**Duplicated** in every provider's `stream/3` and/or `do_stream/4`:

**Files:**
- Every provider initializes timeout identically
- Default: 300,000 ms (5 minutes)

**Recommendation:**
Create constant in `Ai.Providers.StreamingHelper`:
```elixir
@default_stream_timeout 300_000

@spec get_stream_timeout(StreamOptions.t()) :: non_neg_integer()
def get_stream_timeout(%StreamOptions{stream_timeout: timeout}) when is_integer(timeout) and timeout > 0 do
  timeout
end

def get_stream_timeout(_), do: @default_stream_timeout
```

**Impact:**
- 1 line × 8 providers
- Minor but consistent

---

## 10. EXISTING SHARED HELPERS (ALREADY USED)

### Good Patterns - Expand On:

1. **`Ai.Providers.GoogleShared`** - Used by 3 Google providers
   - Content conversion
   - Tool/function declaration
   - Stop reason mapping
   - **Status:** Already exists, well-designed

2. **`Ai.Providers.OpenAIResponsesShared`** - Used by 2+ OpenAI variants
   - Message conversion
   - Tool conversion
   - Stream processing
   - **Status:** Already exists, good approach

3. **`Ai.Providers.HttpTrace`** - Tracing utilities
   - Used by: Anthropic, Bedrock
   - Should be used by more providers for consistency

4. **`Ai.Providers.TextSanitizer`** - Unicode sanitization
   - Used by: Bedrock
   - Small utility, already proper extraction

---

## Recommended Implementation Priority

### Phase 1: High-Impact Duplications (80% of benefit)
1. **AssistantMessageHelper** (19 files, 144 lines) - Creates `Ai.Providers.AssistantMessageHelper`
2. **SSEParser** (3 files, 63 lines) - Creates `Ai.Providers.SSEParser`
3. **StreamingHelper/Macro** (8 files, 120 lines) - Creates `Ai.Providers.StreamingHelper`

### Phase 2: Medium-Impact (15% of benefit)
4. **RetryHelper** (exponential backoff + transport errors + status codes)
5. **ErrorHandler** (error message extraction)
6. **HeaderBuilder** (header merging and API key headers)

### Phase 3: Minor Cleanups (5% of benefit)
7. **StreamingHelper constants** (timeout defaults)
8. Audit all providers to use shared helpers consistently

---

## Summary Statistics

| Category | Duplicated Lines | Files Affected | Priority |
|----------|-------------------|----------------|----------|
| Assistant Message Init | 144 | 8 | HIGH |
| SSE Parsing | 63 | 3 | HIGH |
| Stream Setup | 120 | 8 | HIGH |
| Retry Delays | 15 | 3 | MEDIUM |
| Transport Errors | 33 | 3+ | MEDIUM |
| Error Extraction | 45+ | 8 | MEDIUM |
| Header Building | 40+ | 8 | MEDIUM |
| Stream Timeout | 8 | 8 | LOW |
| **TOTAL** | **~468+** | **8 providers** | |

---

## Notes

- Anthropic provider has the most comprehensive implementations (retry, error handling, transport error detection) - use as reference
- OpenAI Responses/Codex/Azure triplet is prime candidate for further consolidation beyond SSE parser
- Google providers (3 variants) already have good shared helper pattern with `GoogleShared` - follow this model for other families
- Consider creating `Ai.Providers.CommonHelpers` module that re-exports all shared utilities for easier discovery
