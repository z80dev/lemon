## 1) Where context is constructed and grows

### A) “Agent context” (system prompt + messages + tools)

The main flow for Lemon’s in-process agents is:

* **`CodingAgent.Session.refresh_system_prompt/1`** rebuilds the system prompt each time you prompt the agent.
* **`AgentCore.Loop.Streaming.stream_assistant_response/5`**:

  * takes the agent’s `context` (system_prompt + messages + tools),
  * transforms messages (e.g. drop internal ones),
  * converts to `%Ai.Types.Context{}` and calls `Ai.stream/3`.

That means any nondeterminism in:

* system prompt text
* tool list (including order)
* message serialization

…will change the prompt prefix and can tank prompt caching.

### B) Tool outputs are appended verbatim into context

Tool results become `ToolResultMessage`s and are appended directly (no global truncation), so any tool that returns big text can balloon the prompt.

See: `AgentCore.Loop.ToolCalls.emit_tool_result/4` in `apps/agent_core/lib/agent_core/loop/tool_calls.ex`.

### C) Compaction exists, but can be late

There’s a compaction system in `CodingAgent.Session` + `CodingAgent.Compaction`, but it generally triggers based on “near context window” heuristics. If you’re using a large-context model, you can still build *massive* prompts before compaction kicks in.

---

## 2) The biggest “prompt caching killer” I found

### ✅ Nondeterministic ordering in the system prompt (skills list)

`CodingAgent.SystemPrompt.build_skills_section/1` calls:

```elixir
skills = LemonSkills.list(cwd: cwd)
```

But `LemonSkills.Registry.handle_call({:list, cwd}, ...)` (pre-fix) returned:

```elixir
{:reply, Map.values(skills), state}
```

`Map.values/1` order is not guaranteed in a way you should rely on for stable prompt text. Because the **system prompt is rebuilt every prompt**, if the skill order changes, your system prompt changes, and your prompt prefix changes → **prompt cache misses**.

This is exactly the kind of subtle “everything is the same but caching stopped working” bug that makes subscriptions burn fast.

### Also likely: nondeterministic tool ordering for extension/wasm tools

Tools are part of the prompt prefix for function calling. If extension/wasm tool discovery order changes, the tool list changes → cache misses.

I patched this too (details below).

---

## 3) Concrete fixes I’d apply now

### Fix 1: Make skill list ordering deterministic

Patch: `apps/lemon_skills/lib/lemon_skills/registry.ex`

```diff
 def handle_call({:list, cwd}, _from, state) do
   {skills, state} = merge_skills(state, cwd)
-  {:reply, Map.values(skills), state}
+
+  # NOTE: Map iteration order is not guaranteed.
+  # We sort here to keep skill ordering deterministic across calls.
+  # This is important for stable system prompts (and prompt caching).
+  entries =
+    skills
+    |> Map.values()
+    |> Enum.sort_by(fn entry -> entry.key || "" end)
+
+  {:reply, entries, state}
 end
```

This is the single most suspicious “cache breaker” I found because it’s:

* in the system prompt
* rebuilt on every prompt
* order can drift with map merges/refreshes

### Fix 2: Make extension/wasm tool ordering deterministic

Patch: `apps/coding_agent/lib/coding_agent/tool_registry.ex`

```diff
 extension_tools =
   if include_extensions do
     {extensions, _load_errors} = extension_inventory(cwd, opts)

     Extensions.get_tools_with_source(extensions, cwd)
     |> Enum.map(fn {tool, ext_module} ->
       {tool.name, tool, {:extension, ext_module}}
     end)
+    # Keep tool ordering deterministic for stable prompts / prompt caching.
+    |> Enum.sort_by(fn {name, _tool, {:extension, ext_module}} ->
+      {name, Atom.to_string(ext_module)}
+    end)
   else
     []
   end
```

And:

```diff
 defp normalize_wasm_tools(tools) when is_list(tools) do
-  Enum.flat_map(tools, fn
+  tools
+  |> Enum.flat_map(fn
     ...
-  end)
+  end)
+  # Keep tool ordering deterministic for stable prompts / prompt caching.
+  |> Enum.sort_by(fn {name, _tool, {:wasm, meta}} ->
+    {name, wasm_identity(meta)}
+  end)
 end
```

This reduces “prompt prefix jitter” from tool inventory.

---

## 4) Diagnostic code: prompt size + token usage + cache hits

### What you want to see

You want per-LLM-call visibility into:

* how big your prompt is (bytes + a rough token estimate)
* how many tokens were *actually* used (input/output)
* how many tokens were served from cache (cache_read / cache_write)
* whether the “stable” parts of the prompt are stable (hashes)

OpenAI prompt caching is prefix-based and requires stable prefixes; it also reports cached token usage, and prompts must meet a minimum size for caching to kick in. ([OpenAI Platform][1])
Anthropic caching uses `cache_control` breakpoints and reports cache read/write token counts. ([Claude][2])

### Patch: Add `Ai.PromptDiagnostics` + hook it into streaming + non-streaming calls

I added a minimal, opt-in diagnostics module that:

* records **sizes/counts/hashes only** (no prompt text)
* logs one compact line per call
* records an introspection event `:ai_llm_call` with the full numeric breakdown

#### New file: `apps/ai/lib/ai/prompt_diagnostics.ex`

```elixir
defmodule Ai.PromptDiagnostics do
  @moduledoc """
  Lightweight, opt-in diagnostics for prompt size + token usage.

  This module is intentionally conservative about what it records:
  it captures **sizes, counts, and hashes** (no raw prompt text).

  Enable with:

      export LEMON_AI_PROMPT_DIAGNOSTICS=1

  Optionally set:

      export LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL=info
      export LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N=5

  Recorded introspection event type:
  - `:ai_llm_call`
  """

  alias Ai.Types.{AssistantMessage, Context, Model, StreamOptions}
  alias LemonCore.Introspection

  require Logger

  @default_top_n 5

  @doc "Return true if diagnostics are enabled via env var."
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS")
    |> to_string()
    |> String.downcase()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  @doc "Compute a conservative size breakdown for an LLM context."
  @spec stats(Context.t()) :: map()
  def stats(%Context{} = ctx) do
    system_prompt = ctx.system_prompt || ""
    system_prompt_bytes = byte_size(system_prompt)

    {messages_bytes, per_role_bytes, per_role_counts, largest_messages} =
      message_rollup(ctx.messages)

    {tools_bytes, tools_hash} = tools_bytes_and_hash(ctx.tools)

    total_bytes = system_prompt_bytes + messages_bytes + tools_bytes

    %{
      system_prompt_bytes: system_prompt_bytes,
      system_prompt_sha256: sha256_hex(system_prompt),
      message_count: length(ctx.messages),
      messages_bytes: messages_bytes,
      messages_bytes_by_role: per_role_bytes,
      messages_count_by_role: per_role_counts,
      largest_messages: largest_messages,
      tool_count: length(ctx.tools),
      tools_bytes: tools_bytes,
      tools_sha256: tools_hash,
      total_bytes: total_bytes,
      approx_input_tokens: approx_tokens_from_bytes(total_bytes)
    }
  end

  @doc """
  Record a combined prompt+usage snapshot for a completed LLM call.

  This records a single introspection event (`:ai_llm_call`) containing:
  - request sizing (bytes + hashes)
  - response usage (tokens, including cache read/write when available)
  """
  @spec record_llm_call(Model.t(), Context.t(), StreamOptions.t(), AssistantMessage.t()) :: :ok
  def record_llm_call(%Model{} = model, %Context{} = ctx, %StreamOptions{} = opts, %AssistantMessage{} = msg) do
    if enabled?() do
      prompt_stats = stats(ctx)
      usage_stats = usage_stats(msg)

      data =
        prompt_stats
        |> Map.merge(usage_stats)
        |> Map.merge(%{
          provider: to_string(model.provider),
          api: to_string(model.api),
          model: model.id,
          # helpful for debugging prompt caching on OpenAI-compatible endpoints
          prompt_cache_key: opts.session_id
        })

      record_introspection(data, opts)
      log_snapshot(data)
    end

    :ok
  end

  @doc "Record a combined prompt+usage snapshot for non-streaming calls."
  @spec record_complete_call(Model.t(), Context.t(), StreamOptions.t() | map(), AssistantMessage.t()) :: :ok
  def record_complete_call(%Model{} = model, %Context{} = ctx, opts, %AssistantMessage{} = msg) do
    stream_opts =
      case opts do
        %StreamOptions{} = so ->
          so

        m when is_map(m) ->
          allowed_keys = Map.keys(%StreamOptions{}) |> Enum.reject(&(&1 == :__struct__))
          struct(StreamOptions, Map.take(m, allowed_keys))

        _ ->
          %StreamOptions{}
      end

    record_llm_call(model, ctx, stream_opts, msg)
  end

  # --------------------------------------------------------------------------
  # Internal helpers
  # --------------------------------------------------------------------------

  defp usage_stats(%AssistantMessage{usage: nil, stop_reason: stop_reason, error_message: error}) do
    %{
      stop_reason: stop_reason,
      error_message: error,
      usage_present: false
    }
  end

  defp usage_stats(%AssistantMessage{usage: usage, stop_reason: stop_reason, error_message: error}) do
    %{
      stop_reason: stop_reason,
      error_message: error,
      usage_present: true,
      input_tokens: usage.input,
      output_tokens: usage.output,
      cache_read_tokens: usage.cache_read,
      cache_write_tokens: usage.cache_write,
      total_tokens: usage.total_tokens,
      total_input_tokens: usage.input + usage.cache_read + usage.cache_write
    }
  end

  defp record_introspection(data, %StreamOptions{} = opts) do
    headers = opts.headers || %{}

    Introspection.record(
      :ai_llm_call,
      data,
      engine: "ai",
      session_key: trace_header(headers, "x-lemon-session-key"),
      agent_id: trace_header(headers, "x-lemon-agent-id"),
      run_id: trace_header(headers, "x-lemon-run-id")
    )

    :ok
  end

  defp trace_header(headers, key) when is_map(headers) do
    case Map.get(headers, key) do
      "" -> nil
      nil -> nil
      v -> v
    end
  end

  defp log_snapshot(data) do
    # Keep the log line short-ish and non-sensitive.
    level =
      System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL")
      |> to_string()
      |> String.downcase()
      |> case do
        "debug" -> :debug
        "warning" -> :warning
        "warn" -> :warning
        "error" -> :error
        _ -> :info
      end

    msg =
      "ai_llm_call " <>
        "model=#{data.model} provider=#{data.provider} " <>
        "bytes=#{data.total_bytes} (~#{data.approx_input_tokens} tok est) " <>
        "msgs=#{data.message_count} tools=#{data.tool_count} " <>
        "usage_in=#{Map.get(data, :total_input_tokens, "?")} " <>
        "usage_out=#{Map.get(data, :output_tokens, "?")} " <>
        "cache_read=#{Map.get(data, :cache_read_tokens, "?")} " <>
        "cache_write=#{Map.get(data, :cache_write_tokens, "?")} " <>
        "stop=#{inspect(data.stop_reason)}"

    Logger.log(level, msg)
  end

  defp tools_bytes_and_hash(tools) when is_list(tools) do
    # Tools are structs (not JSON-encodable by default), so we normalize into
    # plain maps. We hash using `term_to_binary/1` so map key ordering doesn't
    # impact the fingerprint.
    normalized = Enum.map(tools, &normalize_tool/1)

    hash =
      normalized
      |> :erlang.term_to_binary()
      |> sha256_hex()

    bytes =
      case Jason.encode(normalized) do
        {:ok, json} -> byte_size(json)
        _ -> byte_size(:erlang.term_to_binary(normalized))
      end

    {bytes, hash}
  end

  defp normalize_tool(%{name: name, description: desc, parameters: params}) do
    %{
      name: to_string(name),
      description: to_string(desc),
      parameters: params
    }
  end

  defp normalize_tool(other), do: %{tool: inspect(other, limit: 5_000)}

  defp message_rollup(messages) when is_list(messages) do
    {bytes, per_role_bytes, per_role_counts, sized} =
      Enum.with_index(messages)
      |> Enum.reduce({0, %{}, %{}, []}, fn {msg, idx}, {total, role_bytes, role_counts, acc} ->
        role = message_role(msg)
        msg_bytes = message_bytes(msg)

        role_bytes = Map.update(role_bytes, role, msg_bytes, &(&1 + msg_bytes))
        role_counts = Map.update(role_counts, role, 1, &(&1 + 1))

        {total + msg_bytes, role_bytes, role_counts, [{msg_bytes, idx, role} | acc]}
      end)

    top_n = top_n()

    largest_messages =
      sized
      |> Enum.sort_by(fn {b, _idx, _role} -> -b end)
      |> Enum.take(top_n)
      |> Enum.map(fn {b, idx, role} -> %{index: idx, role: role, bytes: b} end)

    {bytes, per_role_bytes, per_role_counts, largest_messages}
  end

  defp top_n do
    case Integer.parse(to_string(System.get_env("LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N"))) do
      {n, _} when n > 0 and n < 50 -> n
      _ -> @default_top_n
    end
  end

  defp message_role(%{role: role}) when is_atom(role), do: role
  defp message_role(%{role: role}) when is_binary(role), do: role
  defp message_role(_), do: :unknown

  defp message_bytes(%Ai.Types.UserMessage{content: content}), do: content_bytes(content)
  defp message_bytes(%Ai.Types.ToolResultMessage{content: content}), do: content_bytes(content)
  defp message_bytes(%Ai.Types.AssistantMessage{content: content}), do: content_bytes(content)

  # Fallback for custom/unknown message types
  defp message_bytes(%{content: content}) when is_binary(content) or is_list(content),
    do: content_bytes(content)

  defp message_bytes(_), do: 0

  defp content_bytes(content) when is_binary(content), do: byte_size(content)

  defp content_bytes(content) when is_list(content) do
    Enum.reduce(content, 0, fn block, acc -> acc + content_block_bytes(block) end)
  end

  defp content_bytes(_), do: 0

  defp content_block_bytes(%Ai.Types.TextContent{text: text}), do: byte_size(text)
  defp content_block_bytes(%Ai.Types.ThinkingContent{thinking: thinking}), do: byte_size(thinking)
  defp content_block_bytes(%Ai.Types.ImageContent{data: data}), do: byte_size(data)

  defp content_block_bytes(%Ai.Types.ToolCall{name: name, id: id, arguments: args}) do
    args_bytes =
      case Jason.encode(args) do
        {:ok, json} -> byte_size(json)
        _ -> byte_size(inspect(args, limit: 50_000))
      end

    byte_size(to_string(name)) + byte_size(to_string(id)) + args_bytes
  end

  defp content_block_bytes(other) when is_map(other) do
    # Defensive fallback: avoid logging raw data, but account for some size.
    byte_size(inspect(other, limit: 5_000))
  end

  defp content_block_bytes(_), do: 0

  defp approx_tokens_from_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    # Very rough but directionally useful for regressions.
    # Most English text averages ~3-4 chars/token.
    div(bytes + 3, 4)
  end

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end
end
```

#### Hook 1: record per-call diagnostics for streaming agent calls

Patch: `apps/agent_core/lib/agent_core/loop/streaming.ex`

Key changes:

* call `AgentCore.Context.check_size/1` (so you get warnings when contexts balloon)
* record a combined prompt+usage snapshot when a stream completes

```diff
 def stream_assistant_response(context, config, signal, stream_fn, stream) do
   if aborted?(signal) do
     ...
   else
+    # Surface very large contexts early (telemetry warning only; no truncation here).
+    _ = AgentCore.Context.check_size(context)
+
     with {:ok, messages} <- transform_messages(context, config, signal),
          {:ok, llm_messages} <- convert_messages(config, messages) do
       ...
       case stream_function.(config.model, llm_context, options) do
         {:ok, response_stream} ->
-          process_stream_events(context, response_stream, stream, config, signal)
+          process_stream_events(context, response_stream, stream, config, signal, llm_context, options)

         response_stream when is_pid(response_stream) ->
-          process_stream_events(context, response_stream, stream, config, signal)
+          process_stream_events(context, response_stream, stream, config, signal, llm_context, options)
       end
     end
   end
 end

-defp process_stream_events(context, response_stream, stream, config, signal) do
+defp process_stream_events(context, response_stream, stream, config, signal, llm_context, options) do
   ...
   case result do
     {:done, final_message, ctx} ->
+      _ = Ai.PromptDiagnostics.record_llm_call(config.model, llm_context, options, final_message)
       {:ok, final_message, ctx}

     {partial, ctx, added} when partial != nil ->
       {final_message, final_ctx} = finalize_message(partial, ctx, added, stream)
+      _ = Ai.PromptDiagnostics.record_llm_call(config.model, llm_context, options, final_message)
       {:ok, final_message, final_ctx}
   end
 end
```

#### Hook 2: record diagnostics for `Ai.complete/3` (non-streaming)

Patch: `apps/ai/lib/ai.ex`

```diff
 def complete(%Model{} = model, %Context{} = context, opts \\ %{}) do
   with {:ok, stream} <- stream(model, context, opts) do
-    EventStream.result(stream)
+    case EventStream.result(stream) do
+      {:ok, %AssistantMessage{} = msg} = ok ->
+        _ = Ai.PromptDiagnostics.record_complete_call(model, context, opts, msg)
+        ok
+
+      other ->
+        other
+    end
   end
 end
```

### How to use it

Set:

```bash
export LEMON_AI_PROMPT_DIAGNOSTICS=1
export LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL=info
```

Then run your agent as normal. You’ll get log lines like:

```
ai_llm_call model=gpt-5.2 provider=openai bytes=81234 (~20309 tok est) msgs=42 tools=18 usage_in=19850 usage_out=1320 cache_read=19000 cache_write=0 stop=:completed
```

How to interpret:

* `cache_read` near `usage_in` → caching is working.
* `cache_read=0` repeatedly + large `usage_in` → caching is missing; check prompt stability and/or cache thresholds.
* For Anthropic, watch `cache_write` (creation tokens). If `cache_write` is huge every turn, you’re re-writing a large cache frequently (often a symptom of unstable prefix). ([Claude][2])

If you want to inspect the full recorded map (hashes + largest messages, etc), open an IEx session and query `LemonCore.Store.list_introspection_events/1`:

```elixir
# iex -S mix
events =
  LemonCore.Store.list_introspection_events(limit: 20, event_type: :ai_llm_call)

# Each event has :data with the full stats map
Enum.map(events, fn e -> e.data end)
```

---

## 5) What I’d check next (with the new diagnostics)

### A) Is your prompt prefix stable?

Compare `system_prompt_sha256` and `tools_sha256` across sequential calls where nothing changed.

If either hash changes frequently:

* you’ve found the cache buster
* caching will never hit well (prefix mismatch)

The two fixes above (skills ordering + tool ordering) should reduce that dramatically.

### B) Is the model changing?

Caching is model-specific; switching models often will show `cache_read=0`. The log line includes `model=` so it’s obvious.

### C) Is caching even eligible?

OpenAI’s prompt caching has a minimum prompt size before cached tokens show up and reports cached token usage in `cached_tokens`. ([OpenAI Platform][1])
If you’re below that threshold, “cache_read=0” might be expected.

### D) Are bootstrap files included in the system prompt changing constantly?

`CodingAgent.SystemPrompt` injects “bootstrap files” into the system prompt. If your agent frequently edits those files, the system prompt changes every turn, invalidating cache.

If that’s happening, one mitigation is:

* move fast-changing memory out of system prompt into a normal message that you **summarize/compact**, or
* inject only diffs / a short summary.

---

## 6) Quick win: verify Anthropic/OpenAI caching semantics

If you’re on Anthropic, caching uses `cache_control` breakpoints and counts `cache_read_input_tokens` and `cache_creation_input_tokens`. ([Claude][2])
If you’re on OpenAI, caching is prefix-based and `prompt_cache_key` helps routing/hit rates; cached tokens are reported. ([OpenAI Platform][1])

Your code already sets:

* OpenAI: `prompt_cache_key = session_id` (good)
* Anthropic: explicit `cache_control` blocks (worth re-checking with the new logs)

---

## TL;DR: most likely root cause + best immediate fix

**Most likely culprit:** nondeterministic skill ordering in the system prompt (due to `Map.values/1`) + system prompt rebuilt every prompt → **cache misses**.

**Do these first:**

1. sort skills in `LemonSkills.Registry.list` (patch above)
2. sort extension/wasm tools in `CodingAgent.ToolRegistry` (patch above)
3. enable `LEMON_AI_PROMPT_DIAGNOSTICS=1` and watch `cache_read` + hashes

If you want, I can also propose a “hard limit” guardrail (truncate or summarize tool outputs > N KB) at the point tool results are appended, so the context can’t silently explode even when compaction doesn’t trigger.

[1]: https://platform.openai.com/docs/guides/prompt-caching "Prompt caching | OpenAI API"
[2]: https://platform.claude.com/docs/en/build-with-claude/prompt-caching "Prompt caching - Claude API Docs"


Here’s a concrete “hard guardrail” design that will (a) **cap prompt growth deterministically** (so it stays cache‑friendly), (b) **spill big blobs to disk** so you don’t lose information, and (c) give you **telemetry + logs** when/why trimming happened.

The key idea: **never let large tool output / tool args / thinking blocks become permanent residents in the prompt**. If they’re needed, we keep a stable pointer (hash-based) and the agent can `read` the spilled file.

---

## What the hard guardrail should enforce

### 1) Per‑message caps (cheap, deterministic, cache‑friendly)

These run on every message before it crosses the “LLM boundary”.

**A. Tool result text cap**

* If a tool result text exceeds `max_tool_result_bytes`, replace it with:

  * a short header (tool name, original size, sha256, spill path)
  * head+tail excerpt
  * *never* include timestamps in the header (timestamps break caching)

**B. Tool result image cap**

* Base64 images are a token bomb.
* Default guardrail behavior: **spill image bytes to disk** and replace image blocks with small text placeholders:

  * `"[image spilled to ... sha256=...]"`

**C. Assistant thinking cap**

* Drop `ThinkingContent` from history entirely (or clamp to a tiny budget).
* It’s almost never worth paying to feed previous thinking back into the model.

**D. Tool call argument cap**

* Tool calls can contain enormous strings (`patch`, `content`, etc.).
* Don’t drop the tool call (providers often expect tool_call+tool_result structure), but **shrink huge string fields inside arguments**:

  * replace big strings with `"%{_truncated: true, bytes: ..., sha256: ..., head: ..., tail: ...}"`

This keeps JSON valid and preserves enough context to debug, without hauling megabytes forward forever.

---

### 2) Total prompt budget (hard stop)

Even if per‑message caps exist, you want a **global ceiling**:

* `max_input_tokens_est` (or bytes) for the whole request (system prompt + messages + tools)
* If exceeded:

  1. strip thinking (if not already)
  2. tighten tool result caps further (e.g. halve max)
  3. tighten tool call arg caps further
  4. if still exceeded:

     * either **trigger compaction** (expensive but preserves meaning)
     * or **fail fast** with a clear error (true hard guardrail mode)

I recommend: default `mode = "trim"`, with an optional `mode = "error"` you can turn on when debugging runaway growth.

---

## Where to hook it (minimal disruption)

You already have a pre‑LLM boundary: `transform_context` in `CodingAgent.Session` (currently wrapping `UntrustedToolBoundary.transform/2`).

That’s the cleanest place to enforce guardrails because:

* it affects only what is sent to the model
* it doesn’t mutate persisted history
* it’s deterministic (good for caching)

If you also want **spill-to-disk** with stable references without re-spilling every call, you can still do it here by using **hash-addressed filenames** (write once if missing).

---

## Proposed config shape

Add to your TOML (or whatever config you’re using via `LemonCore.Config`):

```toml
[agent.guardrails]
enabled = true
mode = "trim" # "trim" | "error"

# “Hard” caps (bytes, not chars)
max_tool_result_bytes = 60000
max_tool_result_images = 0          # 0 = spill images always
max_thinking_bytes = 0              # 0 = drop thinking blocks
max_tool_call_arg_string_bytes = 12000

# Global budget (estimate)
max_input_tokens_est = 45000        # ~ controls cost; << model context window

spill_dir = "~/.lemon/agent/spills" # per session subdir recommended
```

Defaults above are intentionally conservative if you’re trying to protect a subscription.

---

## Concrete Elixir guardrail module (drop-in)

This is written to be:

* deterministic
* stable (no timestamps)
* spill once (hash-addressed file paths)
* safe for UTF‑8

Create: `apps/coding_agent/lib/coding_agent/context_guardrails.ex`

```elixir
defmodule CodingAgent.ContextGuardrails do
  @moduledoc """
  Hard guardrails applied right before messages are sent to the LLM.

  Goals:
  - Cap tool outputs / images / tool-call args deterministically (cache-friendly)
  - Optionally spill large blobs to disk and replace with stable references
  - Drop or clamp thinking blocks
  """

  require Logger

  alias Ai.Types.{AssistantMessage, ToolResultMessage, UserMessage}
  alias Ai.Types.{TextContent, ImageContent, ThinkingContent, ToolCall}

  @type opts :: %{
          enabled: boolean(),
          mode: :trim | :error,
          max_tool_result_bytes: non_neg_integer(),
          max_tool_result_images: non_neg_integer(),
          max_thinking_bytes: non_neg_integer(),
          max_tool_call_arg_string_bytes: non_neg_integer(),
          spill_dir: String.t() | nil
        }

  @default_opts %{
    enabled: true,
    mode: :trim,
    max_tool_result_bytes: 60_000,
    max_tool_result_images: 0,
    max_thinking_bytes: 0,
    max_tool_call_arg_string_bytes: 12_000,
    spill_dir: nil
  }

  @doc """
  Transform messages for LLM input (AgentCore transform_context-compatible).

  Return value can be:
    - list(messages)
    - {:ok, list(messages)}

  This function never raises unless mode=:error and we detect an overflow we can't trim.
  """
  @spec transform([term()], reference() | nil, map() | keyword()) :: {:ok, [term()]} | [term()]
  def transform(messages, _signal \\ nil, opts \\ %{}) when is_list(messages) do
    opts = normalize_opts(opts)

    if opts.enabled do
      transformed =
        messages
        |> Enum.map(&guard_message(&1, opts))

      {:ok, transformed}
    else
      {:ok, messages}
    end
  end

  defp normalize_opts(opts) when is_list(opts),
    do: opts |> Enum.into(%{}) |> normalize_opts()

  defp normalize_opts(opts) when is_map(opts),
    do: Map.merge(@default_opts, opts)

  # ----------------------------------------------------------------------------
  # Message guards
  # ----------------------------------------------------------------------------

  defp guard_message(%ToolResultMessage{} = msg, opts), do: guard_tool_result(msg, opts)
  defp guard_message(%AssistantMessage{} = msg, opts), do: guard_assistant(msg, opts)
  defp guard_message(%UserMessage{} = msg, opts), do: guard_user(msg, opts)
  defp guard_message(other, _opts), do: other

  defp guard_user(%UserMessage{content: content} = msg, opts) do
    # Usually small. If user pastes huge logs, you can also cap here later.
    _ = opts
    msg
  end

  defp guard_assistant(%AssistantMessage{content: blocks} = msg, opts) do
    blocks =
      blocks
      |> Enum.flat_map(fn
        %ThinkingContent{} = t ->
          guard_thinking_block(t, opts)

        %ToolCall{} = tc ->
          [%{tc | arguments: guard_tool_call_args(tc.arguments, opts)}]

        other ->
          [other]
      end)

    %{msg | content: blocks}
  end

  defp guard_thinking_block(%ThinkingContent{thinking: thinking} = block, %{max_thinking_bytes: 0}),
    do: []

  defp guard_thinking_block(%ThinkingContent{thinking: thinking} = block, opts) do
    maxb = opts.max_thinking_bytes

    if byte_size(thinking) <= maxb do
      [block]
    else
      {tr, meta} = truncate_with_meta(thinking, maxb, spill_label: "assistant_thinking", opts: opts)

      Logger.warning("Thinking block truncated: #{inspect(meta)}")
      [%{block | thinking: tr}]
    end
  end

  defp guard_tool_call_args(args, opts) when is_map(args) do
    maxb = opts.max_tool_call_arg_string_bytes

    args
    |> Enum.map(fn {k, v} ->
      {k, guard_arg_value(v, maxb, opts)}
    end)
    |> Enum.into(%{})
  end

  defp guard_tool_call_args(other, _opts), do: other

  defp guard_arg_value(v, _maxb, _opts) when is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp guard_arg_value(v, maxb, opts) when is_binary(v) do
    if byte_size(v) <= maxb do
      v
    else
      {tr, meta} = truncate_with_meta(v, maxb, spill_label: "tool_call_arg", opts: opts)

      %{
        "_truncated" => true,
        "bytes" => meta.original_bytes,
        "sha256" => meta.sha256,
        "spill_path" => meta.spill_path,
        "head_tail_excerpt" => tr
      }
    end
  end

  defp guard_arg_value(v, maxb, opts) when is_list(v),
    do: Enum.map(v, &guard_arg_value(&1, maxb, opts))

  defp guard_arg_value(v, maxb, opts) when is_map(v) do
    v
    |> Enum.map(fn {k, vv} -> {k, guard_arg_value(vv, maxb, opts)} end)
    |> Enum.into(%{})
  end

  defp guard_arg_value(v, _maxb, _opts), do: v

  # ----------------------------------------------------------------------------
  # Tool result guards (text + images)
  # ----------------------------------------------------------------------------

  defp guard_tool_result(%ToolResultMessage{} = msg, opts) do
    {texts, images} =
      Enum.split_with(msg.content || [], fn
        %TextContent{} -> true
        _ -> false
      end)

    text =
      texts
      |> Enum.map(fn %TextContent{text: t} -> t end)
      |> Enum.join("\n")

    # Handle images first (spill by default)
    {image_placeholders, kept_images} =
      spill_or_keep_images(images, opts, tool_name(msg))

    # Then clamp text
    {clamped_text, _meta} =
      if text == "" do
        {"", nil}
      else
        if byte_size(text) <= opts.max_tool_result_bytes do
          {text, nil}
        else
          truncate_with_meta(text, opts.max_tool_result_bytes,
            spill_label: "tool_result:#{tool_name(msg)}",
            opts: opts
          )
        end
      end

    header =
      if clamped_text != text do
        # Important: deterministic header (no timestamps).
        sha = sha256_hex(text)
        spill_path = stable_spill_path(opts.spill_dir, "tool_result", sha, "txt")

        [
          "[tool_result truncated]",
          "tool=#{tool_name(msg)}",
          "original_bytes=#{byte_size(text)}",
          "sha256=#{sha}",
          (if spill_path, do: "spill_path=#{spill_path}", else: nil)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
      else
        nil
      end

    final_text =
      cond do
        header && clamped_text != "" -> header <> "\n" <> clamped_text
        header -> header
        true -> clamped_text
      end

    new_blocks =
      []
      |> maybe_add_text(final_text)
      |> Kernel.++(image_placeholders)
      |> Kernel.++(kept_images)

    %{msg | content: new_blocks}
  end

  defp tool_name(%ToolResultMessage{tool_name: t}) when is_binary(t) and t != "", do: t
  defp tool_name(_), do: "tool"

  defp maybe_add_text(blocks, text) when is_list(blocks) do
    if is_binary(text) and text != "" do
      blocks ++ [%TextContent{type: :text, text: text}]
    else
      blocks
    end
  end

  defp spill_or_keep_images(images, opts, tool_name) do
    # Keep at most N images as actual ImageContent; spill the rest to text placeholders.
    max_images = opts.max_tool_result_images || 0

    {keep, spill} = Enum.split(images, max_images)

    kept_images = keep

    placeholders =
      spill
      |> Enum.map(fn
        %ImageContent{data: b64, mime_type: mime} = img ->
          sha = sha256_hex(Base.decode64!(b64))
          ext = mime_to_ext(mime)
          path = stable_spill_path(opts.spill_dir, "tool_image", sha, ext)

          _ = maybe_write_spill(path, Base.decode64!(b64))

          %TextContent{
            type: :text,
            text:
              "[tool_result image spilled] tool=#{tool_name} mime=#{mime} sha256=#{sha}" <>
                if(path, do: " spill_path=#{path}", else: "")
          }

        other ->
          %TextContent{type: :text, text: "[tool_result image omitted] #{inspect(other)}"}
      end)

    {placeholders, kept_images}
  end

  defp mime_to_ext("image/png"), do: "png"
  defp mime_to_ext("image/jpeg"), do: "jpg"
  defp mime_to_ext("image/webp"), do: "webp"
  defp mime_to_ext(_), do: "bin"

  # ----------------------------------------------------------------------------
  # Truncation + spill helpers (deterministic)
  # ----------------------------------------------------------------------------

  defp truncate_with_meta(text, max_bytes, spill_label: label, opts: opts) do
    sha = sha256_hex(text)
    path = stable_spill_path(opts.spill_dir, label, sha, "txt")

    _ = maybe_write_spill(path, text)

    truncated = truncate_middle_utf8(text, max_bytes)

    meta = %{
      original_bytes: byte_size(text),
      truncated_bytes: byte_size(truncated),
      sha256: sha,
      spill_path: path,
      label: label
    }

    {truncated, meta}
  end

  defp stable_spill_path(nil, _label, _sha, _ext), do: nil

  defp stable_spill_path(dir, label, sha, ext) when is_binary(dir) do
    safe_label =
      label
      |> to_string()
      |> String.replace(~r/[^a-zA-Z0-9_\-:.]+/, "_")
      |> String.slice(0, 80)

    Path.join([expand_home(dir), safe_label, "#{sha}.#{ext}"])
  end

  defp expand_home(path) do
    case path do
      "~" <> rest -> Path.join(System.user_home!(), String.trim_leading(rest, "/"))
      other -> other
    end
  end

  defp maybe_write_spill(nil, _data), do: :ok

  defp maybe_write_spill(path, data) when is_binary(path) do
    try do
      File.mkdir_p!(Path.dirname(path))

      case File.stat(path) do
        {:ok, _} ->
          :ok

        {:error, :enoent} ->
          File.write!(path, data)
          :ok

        {:error, _} ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  defp sha256_hex(bin) when is_binary(bin) do
    :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower)
  end

  # Keep head + tail; deterministic; preserve UTF-8 validity.
  defp truncate_middle_utf8(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp truncate_middle_utf8(text, max_bytes) when max_bytes <= 0, do: ""

  defp truncate_middle_utf8(text, max_bytes) do
    marker_reserve = 256
    budget = max(max_bytes - marker_reserve, 0)

    head_bytes = div(budget * 70, 100)
    tail_bytes = budget - head_bytes

    head = trim_to_valid_utf8(binary_part(text, 0, head_bytes))
    tail = trim_to_valid_utf8(binary_part(text, byte_size(text) - tail_bytes, tail_bytes))

    removed = byte_size(text) - byte_size(head) - byte_size(tail)

    marker = "\n... [TRUNCATED #{removed} bytes] ...\n"

    out = head <> marker <> tail

    if byte_size(out) <= max_bytes do
      out
    else
      trim_to_valid_utf8(binary_part(out, 0, max_bytes))
    end
  end

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(bin) when is_binary(bin) do
    if String.valid?(bin) do
      bin
    else
      bin
      |> binary_part(0, byte_size(bin) - 1)
      |> trim_to_valid_utf8()
    end
  end
end
```

---

## Hook it into the existing transform pipeline

In `CodingAgent.Session`, your `build_transform_context/1` currently wraps `UntrustedToolBoundary.transform/2`.

Update it to add guardrails (ideally with options captured from config + session id).

Example minimal integration (no new settings plumbed yet):

```elixir
# coding_agent/session.ex

defp build_transform_context(nil) do
  fn messages, signal ->
    with {:ok, msgs} <- normalize_transform_result(CodingAgent.ContextGuardrails.transform(messages, signal)),
         {:ok, wrapped} <- normalize_transform_result(UntrustedToolBoundary.transform(msgs, signal)) do
      {:ok, wrapped}
    end
  end
end

defp build_transform_context(transform_fn) when is_function(transform_fn, 2) do
  fn messages, signal ->
    with {:ok, guarded} <- normalize_transform_result(CodingAgent.ContextGuardrails.transform(messages, signal)),
         {:ok, wrapped} <- normalize_transform_result(UntrustedToolBoundary.transform(guarded, signal)),
         {:ok, transformed} <- normalize_transform_result(transform_fn.(wrapped, signal)) do
      {:ok, transformed}
    end
  end
end
```

Notes on ordering:

* I put `ContextGuardrails` **before** `UntrustedToolBoundary` to avoid ever truncating in a way that could chop off external-content wrappers.
* If you prefer guardrails last, make sure truncation always preserves wrapper head+tail (the module above does).

---

## Add a true “hard stop” on total prompt size (optional but recommended)

This is the “subscription protection” lever.

You already added prompt diagnostics earlier; once you have `Ai.PromptDiagnostics.estimate_*`, the simplest hard stop is in `AgentCore.Loop.Streaming.stream_assistant_response/5` right after building `llm_context`:

```elixir
# Pseudocode (keep deterministic; no timestamps):
max_tokens = 45_000

estimate =
  Ai.PromptDiagnostics.estimate_prompt(llm_context.system_prompt, llm_context.messages, llm_context.tools, config.model)

if estimate.input_tokens_est > max_tokens do
  Logger.error("Hard guardrail: prompt too large tokens_est=#{estimate.input_tokens_est} max=#{max_tokens}")

  case guardrail_mode do
    :trim ->
      # apply second-pass stronger truncation, or trigger compaction
      ...
    :error ->
      {:error, {:prompt_too_large, estimate}}
  end
end
```

I’d implement this as a small `AgentCore.PromptGuardrail` module so it’s reusable across agents.

---

## What you’ll see when it works

With guardrails enabled:

* tool outputs stop ballooning the next request
* images stop silently dumping base64 into the prompt
* thinking blocks stop accumulating
* huge tool call args become small “hash + excerpt + spill_path” structs
* caching becomes more effective (stable prefix, smaller diffs)

And you’ll have stable spill files you can inspect:

* `~/.lemon/agent/spills/tool_result:<name>/<sha>.txt`
* `~/.lemon/agent/spills/tool_image/<sha>.png`


2. **Spill images; never include base64 in history**

```toml
max_tool_result_images = 0
```

Then clamp tool result text to something like 30–60KB.

---

## Current Status (updated by manager)

### Implementation Progress

| # | Fix | Status | File(s) |
|---|-----|--------|---------|
| 1 | Deterministic skill ordering | DONE | `apps/lemon_skills/lib/lemon_skills/registry.ex` |
| 2a | Deterministic extension tool ordering | DONE | `apps/coding_agent/lib/coding_agent/tool_registry.ex` |
| 2b | Deterministic WASM tool ordering | DONE | `apps/coding_agent/lib/coding_agent/tool_registry.ex` |
| 3 | Ai.PromptDiagnostics module | DONE | `apps/ai/lib/ai/prompt_diagnostics.ex` (NEW) |
| H1 | Diagnostics in streaming loop | DONE | `apps/agent_core/lib/agent_core/loop/streaming.ex` |
| H2 | Diagnostics in Ai.complete/3 | DONE | `apps/ai/lib/ai.ex` |
| 4 | CodingAgent.ContextGuardrails module | DONE | `apps/coding_agent/lib/coding_agent/context_guardrails.ex` (NEW) |
| 5 | Guardrails in Session pipeline | DONE | `apps/coding_agent/lib/coding_agent/session.ex` |

### Build Status
- `mix compile` - PASS (zero warnings)
- `mix compile --warnings-as-errors` - PASS

### Test Results
- ai: 1,958 tests, 0 failures
- lemon_skills: 107 tests, 0 failures
- agent_core: 1,607 tests, 27 failures (pre-existing MockCodexRunner issues)
- coding_agent: 3,574 tests, 45 failures (pre-existing StubRunOrchestrator issues)
- **Zero new failures introduced by our changes**
