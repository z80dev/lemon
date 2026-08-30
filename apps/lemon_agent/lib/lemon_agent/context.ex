defmodule LemonAgent.Context do
  @moduledoc """
  Context management utilities for agent conversations.

  This module provides functions for managing conversation context size,
  including estimation, truncation, and warnings. Context management is
  critical for:

  - **Memory efficiency**: Preventing unbounded message accumulation
  - **Token budget**: Staying within model context window limits
  - **Cost control**: Larger contexts cost more tokens/money
  - **Performance**: Smaller contexts stream faster

  ## Context Size Estimation

  Context size is estimated in "character units" which roughly correlate
  with tokens (approximately 4 characters per token for English text).
  This is a fast heuristic - actual token counts vary by model and content.

  ## Truncation Strategies

  Several truncation strategies are available:

  - `:sliding_window` - Keep most recent N messages (default)
  - `:keep_bookends` - Keep balanced oldest/newest messages within both limits
  - `:keep_system_user` - Keep system prompt + first user message + recent
  - `:summarize_old` - Replace old messages with a summary (requires LLM call)

  ## Usage

      # Estimate context size
      size = LemonAgent.Context.estimate_size(messages, system_prompt)

      # Check if context is large
      if LemonAgent.Context.large_context?(messages, system_prompt) do
        Logger.warning("Context is getting large")
      end

      # Truncate to fit budget
      truncated = LemonAgent.Context.truncate(messages, max_chars: 100_000)

  ## Telemetry Events

  The following telemetry events are emitted:

  - `[:lemon_agent, :context, :size]` - Emitted when context size is measured
    - Measurements: `%{char_count: integer, message_count: integer}`
    - Metadata: `%{has_system_prompt: boolean}`

  - `[:lemon_agent, :context, :warning]` - Emitted when context exceeds threshold
    - Measurements: `%{char_count: integer, threshold: integer}`
    - Metadata: `%{level: :warning | :critical}`
  """

  require Logger

  alias LemonAi.Tokens
  alias LemonAgent.Types

  # ============================================================================
  # Constants
  # ============================================================================

  # Default warning thresholds (in characters, ~tokens * 4)
  # Warning at ~50k tokens
  @warning_threshold 200_000
  # Critical at ~100k tokens
  @critical_threshold 400_000

  # Default max messages to keep when truncating
  @default_max_messages 100

  # Default max characters for context
  @default_max_chars 500_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Estimates the size of the context in characters.

  This is a fast heuristic that counts characters in all message content.
  For rough token estimation, divide by 4.

  ## Parameters

  - `messages` - List of agent messages
  - `system_prompt` - Optional system prompt string

  ## Returns

  Integer count of estimated characters.

  ## Examples

      iex> messages = [%{content: "Hello"}, %{content: "World"}]
      iex> LemonAgent.Context.estimate_size(messages, "Be helpful")
      20  # "Hello" + "World" + "Be helpful"
  """
  @spec estimate_size([Types.agent_message()], String.t() | nil) :: non_neg_integer()
  def estimate_size(messages, system_prompt \\ nil) do
    system_size = if system_prompt, do: String.length(system_prompt), else: 0

    message_size =
      messages
      |> Enum.reduce(0, fn msg, acc ->
        acc + message_char_count(msg)
      end)

    total = system_size + message_size

    # Emit telemetry
    LemonCore.Telemetry.emit(
      [:lemon_agent, :context, :size],
      %{char_count: total, message_count: length(messages)},
      %{has_system_prompt: system_prompt != nil}
    )

    total
  end

  @doc """
  Estimates the token count based on character count.

  Uses a conservative estimate of 4 characters per token.
  Actual token counts vary by model, language, and content type.

  ## Examples

      iex> LemonAgent.Context.estimate_tokens(4000)
      1000
  """
  @spec estimate_tokens(non_neg_integer()) :: non_neg_integer()
  def estimate_tokens(char_count) do
    Tokens.estimate_char_count(char_count)
  end

  @doc """
  Checks if the context is considered "large" (above warning threshold).

  A large context may indicate memory pressure or approaching model limits.
  Consider truncation when this returns true.

  ## Options

  - `:threshold` - Custom threshold in characters (default: #{@warning_threshold})

  ## Examples

      iex> LemonAgent.Context.large_context?(messages, "System prompt")
      false

      iex> LemonAgent.Context.large_context?(huge_messages, "Prompt", threshold: 1000)
      true
  """
  @spec large_context?([Types.agent_message()], String.t() | nil, keyword()) :: boolean()
  def large_context?(messages, system_prompt \\ nil, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @warning_threshold)
    estimate_size(messages, system_prompt) > threshold
  end

  @doc """
  Checks context size and emits warnings/telemetry if thresholds are exceeded.

  This function should be called periodically (e.g., before each LLM call)
  to monitor context growth and emit early warnings.

  ## Options

  - `:warning_threshold` - Chars for warning (default: #{@warning_threshold})
  - `:critical_threshold` - Chars for critical (default: #{@critical_threshold})
  - `:log` - Whether to log warnings (default: true)

  ## Returns

  - `:ok` - Context is within normal limits
  - `:warning` - Context exceeds warning threshold
  - `:critical` - Context exceeds critical threshold

  ## Examples

      case LemonAgent.Context.check_size(messages, system_prompt) do
        :ok -> :continue
        :warning -> Logger.info("Consider truncating context")
        :critical -> truncate_context()
      end
  """
  @spec check_size([Types.agent_message()], String.t() | nil, keyword()) ::
          :ok | :warning | :critical
  def check_size(messages, system_prompt \\ nil, opts \\ []) do
    warning_threshold = Keyword.get(opts, :warning_threshold, @warning_threshold)
    critical_threshold = Keyword.get(opts, :critical_threshold, @critical_threshold)
    log = Keyword.get(opts, :log, true)

    size = estimate_size(messages, system_prompt)

    cond do
      size > critical_threshold ->
        if log do
          Logger.warning(
            "Context size critical: #{size} chars (~#{estimate_tokens(size)} tokens), " <>
              "#{length(messages)} messages. Consider truncating."
          )
        end

        LemonCore.Telemetry.emit(
          [:lemon_agent, :context, :warning],
          %{char_count: size, threshold: critical_threshold},
          %{level: :critical}
        )

        :critical

      size > warning_threshold ->
        if log do
          Logger.info(
            "Context size warning: #{size} chars (~#{estimate_tokens(size)} tokens), " <>
              "#{length(messages)} messages."
          )
        end

        LemonCore.Telemetry.emit(
          [:lemon_agent, :context, :warning],
          %{char_count: size, threshold: warning_threshold},
          %{level: :warning}
        )

        :warning

      true ->
        :ok
    end
  end

  @doc """
  Truncates message history to fit within limits.

  Uses a sliding window strategy by default, keeping the most recent messages
  in their original order. The first user message is always preserved to
  maintain conversation context. Assistant tool-call messages and their
  contiguous tool-result messages are treated as atomic transcript units, so
  truncation never creates an orphaned call or result.

  ## Options

  - `:max_messages` - Maximum number of messages to keep (default: #{@default_max_messages})
  - `:max_chars` - Maximum total character count (default: #{@default_max_chars})
  - `:strategy` - Truncation strategy (default: `:sliding_window`)
  - `:keep_first_user` - Keep the first user message (default: true)

  ## Strategies

  - `:sliding_window` - Keep most recent messages within limits
  - `:keep_bookends` - Keep balanced oldest/newest messages within both limits

  ## Returns

  A tuple of `{truncated_messages, dropped_count}`.

  ## Examples

      {truncated, dropped} = LemonAgent.Context.truncate(messages, max_messages: 50)
      IO.puts("Dropped \#{dropped} messages")
  """
  @spec truncate([Types.agent_message()], keyword()) ::
          {[Types.agent_message()], non_neg_integer()}
  def truncate(messages, opts \\ []) do
    max_messages = Keyword.get(opts, :max_messages, @default_max_messages)
    max_chars = Keyword.get(opts, :max_chars, @default_max_chars)
    strategy = Keyword.get(opts, :strategy, :sliding_window)
    keep_first_user = Keyword.get(opts, :keep_first_user, true)

    original_count = length(messages)

    truncated =
      case strategy do
        :sliding_window ->
          truncate_sliding_window(messages, max_messages, max_chars, keep_first_user)

        :keep_bookends ->
          truncate_bookends(messages, max_messages, max_chars)

        _ ->
          truncate_sliding_window(messages, max_messages, max_chars, keep_first_user)
      end

    dropped = original_count - length(truncated)

    if dropped > 0 do
      LemonCore.Telemetry.emit(
        [:lemon_agent, :context, :truncated],
        %{dropped_count: dropped, remaining_count: length(truncated)},
        %{strategy: strategy}
      )
    end

    {truncated, dropped}
  end

  @doc """
  Creates a transform_context function for use with AgentLoopConfig.

  This wraps the truncation logic in a function suitable for the
  `transform_context` configuration option.

  ## Options

  Same as `truncate/2`, plus:

  - `:warn_on_truncation` - Log when truncation occurs (default: true)

  ## Examples

      config = %AgentLoopConfig{
        transform_context: LemonAgent.Context.make_transform(max_messages: 50),
        ...
      }
  """
  @spec make_transform(keyword()) ::
          ([Types.agent_message()], reference() | nil -> {:ok, [Types.agent_message()]})
  def make_transform(opts \\ []) do
    warn_on_truncation = Keyword.get(opts, :warn_on_truncation, true)
    truncate_opts = Keyword.drop(opts, [:warn_on_truncation])

    fn messages, _signal ->
      {truncated, dropped} = truncate(messages, truncate_opts)

      if dropped > 0 and warn_on_truncation do
        Logger.info("Truncated #{dropped} messages from context (#{length(truncated)} remaining)")
      end

      {:ok, truncated}
    end
  end

  @doc """
  Returns context statistics for monitoring/debugging.

  ## Returns

  A map with:
  - `:message_count` - Number of messages
  - `:char_count` - Total characters
  - `:estimated_tokens` - Approximate token count
  - `:by_role` - Message counts per role

  ## Examples

      stats = LemonAgent.Context.stats(messages, system_prompt)
      IO.inspect(stats)
      # %{
      #   message_count: 10,
      #   char_count: 5000,
      #   estimated_tokens: 1250,
      #   by_role: %{user: 5, assistant: 4, tool_result: 1}
      # }
  """
  @spec stats([Types.agent_message()], String.t() | nil) :: map()
  def stats(messages, system_prompt \\ nil) do
    char_count = estimate_size(messages, system_prompt)

    by_role =
      messages
      |> Enum.group_by(fn msg -> Map.get(msg, :role, :unknown) end)
      |> Enum.map(fn {role, msgs} -> {role, length(msgs)} end)
      |> Map.new()

    %{
      message_count: length(messages),
      char_count: char_count,
      estimated_tokens: estimate_tokens(char_count),
      by_role: by_role,
      system_prompt_chars: if(system_prompt, do: String.length(system_prompt), else: 0)
    }
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp message_char_count(msg) do
    content = Map.get(msg, :content, "")

    case content do
      text when is_binary(text) ->
        String.length(text)

      blocks when is_list(blocks) ->
        Enum.reduce(blocks, 0, fn block, acc ->
          acc + content_block_char_count(block)
        end)

      _ ->
        0
    end
  end

  defp content_block_char_count(%{type: :text, text: text}), do: String.length(text || "")
  defp content_block_char_count(%{type: :thinking, thinking: text}), do: String.length(text || "")
  defp content_block_char_count(%{type: :tool_call, arguments: args}), do: map_size_estimate(args)

  defp content_block_char_count(%{type: :image}),
    do: 100

  defp content_block_char_count(_), do: 0

  defp map_size_estimate(map) when is_map(map) do
    map
    |> Jason.encode!()
    |> String.length()
  rescue
    _ -> 50
  end

  defp map_size_estimate(_), do: 0

  defp truncate_sliding_window(messages, max_messages, max_chars, keep_first_user) do
    # If messages fit within limits, return as-is
    if length(messages) <= max_messages and estimate_size(messages, nil) <= max_chars do
      messages
    else
      units = transcript_units(messages)

      # Find first user message if we need to preserve it. A user message is a
      # standalone unit, but retaining the unit rather than the bare message
      # keeps this invariant explicit if message shapes evolve later.
      {_first_user, first_user_idx} =
        if keep_first_user do
          find_first_user_message(messages)
        else
          {nil, nil}
        end

      reserved_unit =
        Enum.find(units, fn unit ->
          is_integer(first_user_idx) and first_user_idx in unit.range
        end)

      recent_units =
        if reserved_unit do
          Enum.filter(units, &(&1.first_index > reserved_unit.first_index))
        else
          units
        end

      reserved_count = if reserved_unit, do: reserved_unit.count, else: 0
      reserved_chars = if reserved_unit, do: reserved_unit.chars, else: 0

      # Traversing newest-to-oldest while prepending produces chronological
      # order directly. Do not reverse this accumulator a second time.
      {kept_units, _count, _chars} =
        recent_units
        |> Enum.reverse()
        |> Enum.reduce({[], reserved_count, reserved_chars}, fn unit, {acc, count, chars} ->
          if count + unit.count <= max_messages and chars + unit.chars <= max_chars do
            {[unit | acc], count + unit.count, chars + unit.chars}
          else
            {acc, count, chars}
          end
        end)

      [reserved_unit]
      |> Enum.reject(&is_nil/1)
      |> Kernel.++(kept_units)
      |> flatten_units()
    end
  end

  defp truncate_bookends(messages, max_messages, max_chars) do
    if length(messages) <= max_messages and estimate_size(messages, nil) <= max_chars do
      messages
    else
      units = transcript_units(messages)

      {selected, _count, _chars} =
        units
        |> bookend_indices()
        |> Enum.reduce({MapSet.new(), 0, 0}, fn index, {selected, count, chars} ->
          unit = Enum.at(units, index)

          if count + unit.count <= max_messages and chars + unit.chars <= max_chars do
            {MapSet.put(selected, index), count + unit.count, chars + unit.chars}
          else
            {selected, count, chars}
          end
        end)

      units
      |> Enum.with_index()
      |> Enum.filter(fn {_unit, index} -> MapSet.member?(selected, index) end)
      |> Enum.map(&elem(&1, 0))
      |> flatten_units()
    end
  end

  # A tool transcript is valid only when the assistant call and its immediately
  # following results survive together. Grouping before either truncation
  # strategy makes that structural rule independent of size-selection policy.
  defp transcript_units(messages), do: transcript_units(messages, 0, [])

  defp transcript_units([], _index, acc), do: Enum.reverse(acc)

  defp transcript_units([message | rest], index, acc) do
    if assistant_tool_call_message?(message) do
      {results, remaining} = Enum.split_while(rest, &tool_result_message?/1)
      unit_messages = [message | results]
      count = length(unit_messages)

      unit = %{
        messages: unit_messages,
        count: count,
        chars: Enum.reduce(unit_messages, 0, &(message_char_count(&1) + &2)),
        first_index: index,
        range: index..(index + count - 1)
      }

      transcript_units(remaining, index + count, [unit | acc])
    else
      unit = %{
        messages: [message],
        count: 1,
        chars: message_char_count(message),
        first_index: index,
        range: index..index
      }

      transcript_units(rest, index + 1, [unit | acc])
    end
  end

  defp assistant_tool_call_message?(%{role: role, content: content})
       when role in [:assistant, "assistant"] and is_list(content),
       do: Enum.any?(content, &tool_call_block?/1)

  defp assistant_tool_call_message?(%{"role" => role, "content" => content})
       when role in [:assistant, "assistant"] and is_list(content),
       do: Enum.any?(content, &tool_call_block?/1)

  defp assistant_tool_call_message?(_message), do: false

  defp tool_call_block?(%{type: type}) when type in [:tool_call, "tool_call"], do: true
  defp tool_call_block?(%{"type" => type}) when type in [:tool_call, "tool_call"], do: true
  defp tool_call_block?(_block), do: false

  defp tool_result_message?(%{role: role}) when role in [:tool_result, "tool_result"], do: true

  defp tool_result_message?(%{"role" => role}) when role in [:tool_result, "tool_result"],
    do: true

  defp tool_result_message?(_message), do: false

  defp flatten_units(units), do: Enum.flat_map(units, & &1.messages)

  defp bookend_indices(units) do
    do_bookend_indices(0, length(units) - 1, :first, []) |> Enum.reverse()
  end

  defp do_bookend_indices(left, right, _side, acc) when left > right, do: acc

  defp do_bookend_indices(left, right, :first, acc),
    do: do_bookend_indices(left + 1, right, :last, [left | acc])

  defp do_bookend_indices(left, right, :last, acc),
    do: do_bookend_indices(left, right - 1, :first, [right | acc])

  defp find_first_user_message(messages) do
    messages
    |> Enum.with_index()
    |> Enum.find(fn {msg, _idx} -> Map.get(msg, :role) == :user end)
    |> case do
      {msg, idx} -> {msg, idx}
      nil -> {nil, nil}
    end
  end
end
