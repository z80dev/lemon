# AgentCore.Context - Conversation Context Management

This document describes the `AgentCore.Context` module for managing conversation context size in agent sessions.

## Overview

The `AgentCore.Context` module provides utilities for:

- **Estimating** context size (characters and tokens)
- **Checking** if context exceeds warning thresholds
- **Truncating** message history to fit within limits
- **Creating** transform functions for automatic context management

Context management is critical for:

- **Memory efficiency** - Preventing unbounded message accumulation
- **Token budget** - Staying within model context window limits
- **Cost control** - Larger contexts cost more tokens/money
- **Performance** - Smaller contexts stream faster

## Location

File: `apps/agent_core/lib/agent_core/context.ex`

## Size Estimation

### estimate_size/2

Estimates the total size of a conversation context in characters.

```elixir
# Estimate size of messages + system prompt
size = AgentCore.Context.estimate_size(messages, system_prompt)
# => 15000

# Without system prompt
size = AgentCore.Context.estimate_size(messages)
# => 12500
```

The function handles:
- Plain text content
- Content blocks (text, thinking, tool_call, image)
- System prompt

### estimate_tokens/1

Converts character count to approximate token count using a ratio of 4 characters per token.

```elixir
tokens = AgentCore.Context.estimate_tokens(4000)
# => 1000
```

**Note:** This is a heuristic. Actual token counts vary by model, language, and content type.

## Threshold Checking

### large_context?/3

Quick check if context exceeds a threshold (default: 200,000 characters / ~50k tokens).

```elixir
if AgentCore.Context.large_context?(messages, system_prompt) do
  Logger.warning("Context is getting large")
end

# With custom threshold
if AgentCore.Context.large_context?(messages, system_prompt, threshold: 100_000) do
  truncate_context()
end
```

### check_size/3

Comprehensive check that emits warnings and telemetry when thresholds are exceeded.

```elixir
case AgentCore.Context.check_size(messages, system_prompt) do
  :ok -> :continue
  :warning -> Logger.info("Consider truncating context")
  :critical -> truncate_context()
end
```

**Default thresholds:**
- Warning: 200,000 characters (~50k tokens)
- Critical: 400,000 characters (~100k tokens)

**Options:**
- `:warning_threshold` - Custom warning threshold in characters
- `:critical_threshold` - Custom critical threshold in characters
- `:log` - Whether to log warnings (default: true)

## Message Truncation

### truncate/2

Truncates message history to fit within limits while preserving context quality.

```elixir
{truncated, dropped_count} = AgentCore.Context.truncate(messages, max_messages: 50)
IO.puts("Dropped #{dropped_count} messages")
```

**Options:**
- `:max_messages` - Maximum number of messages to keep (default: 100)
- `:max_chars` - Maximum total character count (default: 500,000)
- `:strategy` - Truncation strategy (default: `:sliding_window`)
- `:keep_first_user` - Keep the first user message (default: true)

### Truncation Strategies

| Strategy | Description |
|----------|-------------|
| `:sliding_window` | Keep most recent messages within limits (default) |
| `:keep_bookends` | Keep first and last N messages, drop middle |

### make_transform/1

Creates a transform function for use with `AgentLoopConfig.transform_context`.

```elixir
config = %AgentLoopConfig{
  model: model,
  convert_to_llm: &convert/1,
  transform_context: AgentCore.Context.make_transform(
    max_messages: 100,
    max_chars: 500_000,
    strategy: :sliding_window,
    keep_first_user: true
  )
}
```

The transform function will automatically truncate messages at each loop iteration, keeping the context within bounds.

**Additional option:**
- `:warn_on_truncation` - Log when truncation occurs (default: true)

## Statistics

### stats/2

Returns comprehensive statistics about the current context.

```elixir
stats = AgentCore.Context.stats(messages, system_prompt)
# => %{
#   message_count: 50,
#   char_count: 25000,
#   estimated_tokens: 6250,
#   by_role: %{user: 25, assistant: 24, tool_result: 1},
#   system_prompt_chars: 1500
# }
```

## Telemetry Events

The module emits the following telemetry events:

### [:agent_core, :context, :size]

Emitted when `estimate_size/2` is called.

**Measurements:**
- `char_count` - Total character count
- `message_count` - Number of messages

**Metadata:**
- `has_system_prompt` - Boolean indicating if system prompt was included

### [:agent_core, :context, :warning]

Emitted when `check_size/3` detects context exceeding a threshold.

**Measurements:**
- `char_count` - Current character count
- `threshold` - The threshold that was exceeded

**Metadata:**
- `level` - `:warning` or `:critical`

### [:agent_core, :context, :truncated]

Emitted when `truncate/2` drops messages.

**Measurements:**
- `dropped_count` - Number of messages dropped
- `remaining_count` - Number of messages remaining

**Metadata:**
- `strategy` - The truncation strategy used

## Integration with Agent Loop

The agent loop automatically calls `check_size/2` at each iteration. To enable automatic truncation, configure `transform_context`:

```elixir
# In your session or agent configuration
config = %AgentLoopConfig{
  # ... other config ...
  transform_context: AgentCore.Context.make_transform(
    max_messages: 100,
    max_chars: 500_000
  )
}
```

## Examples

### Basic Usage

```elixir
alias AgentCore.Context

# Check context size before making LLM call
messages = session.messages
system_prompt = session.system_prompt

case Context.check_size(messages, system_prompt) do
  :ok ->
    # Context is fine, proceed
    make_llm_call(messages)

  :warning ->
    # Getting large, truncate to be safe
    {truncated, _} = Context.truncate(messages, max_messages: 80)
    make_llm_call(truncated)

  :critical ->
    # Very large, aggressive truncation
    {truncated, _} = Context.truncate(messages, max_messages: 50, max_chars: 200_000)
    make_llm_call(truncated)
end
```

### Monitoring Context Growth

```elixir
# Get detailed stats for monitoring
stats = Context.stats(messages, system_prompt)

Logger.info("""
Context stats:
  Messages: #{stats.message_count}
  Characters: #{stats.char_count}
  Est. tokens: #{stats.estimated_tokens}
  User messages: #{stats.by_role[:user] || 0}
  Assistant messages: #{stats.by_role[:assistant] || 0}
""")
```

### Custom Transform Function

```elixir
# Create a custom transform that also logs
my_transform = fn messages, _signal ->
  stats = Context.stats(messages, nil)

  if stats.message_count > 50 do
    Logger.info("Truncating #{stats.message_count} messages")
    {truncated, dropped} = Context.truncate(messages, max_messages: 50)
    Logger.info("Dropped #{dropped} messages")
    {:ok, truncated}
  else
    {:ok, messages}
  end
end

config = %AgentLoopConfig{
  transform_context: my_transform,
  # ...
}
```
