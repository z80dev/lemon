defmodule Ai.ContextCompactor do
  @moduledoc """
  Automatic context compaction for handling ContextLengthExceeded errors.

  When an AI provider call fails due to exceeding the model's context window,
  this module provides strategies to compact the conversation context and
  enable automatic retry.

  ## Strategies

  - `:truncation` - Remove oldest messages while preserving critical context
  - `:summarization` - Summarize older messages using a lightweight model
  - `:hybrid` - Combine truncation for recent history with summarization for older messages

  ## Usage

      # Check if error is a context length error
      if Ai.ContextCompactor.context_length_error?(error) do
        # Compact the context
        {:ok, compacted_context} = Ai.ContextCompactor.compact(context, strategy: :truncation)
        # Retry with compacted context
      end

  ## Configuration

  Configure via application environment:

      config :ai, Ai.ContextCompactor,
        enabled: true,
        default_strategy: :truncation,
        max_compaction_attempts: 3,
        preserve_recent_messages: 4,
        min_context_tokens: 1000

  ## Telemetry

  The following telemetry events are emitted:

  - `[:ai, :context_compactor, :compaction_started]` - When compaction begins
  - `[:ai, :context_compactor, :compaction_succeeded]` - When compaction succeeds
  - `[:ai, :context_compactor, :compaction_failed]` - When compaction fails
  """

  require Logger

  alias Ai.Types.Context

  @type strategy :: :truncation | :summarization | :hybrid
  @type compaction_opts :: [
          strategy: strategy(),
          preserve_recent: non_neg_integer(),
          target_tokens: non_neg_integer(),
          summarizer_model: String.t()
        ]

  @default_strategy :truncation
  @default_preserve_recent 4
  @default_max_attempts 3

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Check if an error represents a context length exceeded error.

  Detects context length errors from various provider response formats.

  ## Examples

      iex> Ai.ContextCompactor.context_length_error?({:http_error, 400, %{"error" => %{"code" => "context_length_exceeded"}}})
      true

      iex> Ai.ContextCompactor.context_length_error?({:http_error, 429, "Rate limited"})
      false
  """
  @spec context_length_error?(term()) :: boolean()
  def context_length_error?({:http_error, status, body}) when is_map(body) do
    context_length_error_code?(body) or
      context_length_error_message?(status, body)
  end

  def context_length_error?({:http_error, status, body}) when is_binary(body) do
    context_length_error_string?(status, body)
  end

  def context_length_error?(:context_length_exceeded), do: true

  def context_length_error?(error) when is_binary(error) do
    context_length_error_string?(nil, error)
  end

  def context_length_error?(_), do: false

  @doc """
  Compact a context using the specified strategy.

  Returns `{:ok, compacted_context, metadata}` on success, or `{:error, reason}`
  if compaction fails or would violate safety limits.

  ## Options

  - `:strategy` - Compaction strategy (`:truncation`, `:summarization`, `:hybrid`)
  - `:preserve_recent` - Number of recent messages to always preserve (default: 4)
  - `:target_tokens` - Target token count after compaction (optional)
  - `:summarizer_model` - Model to use for summarization (default: "gpt-4o-mini")

  ## Examples

      {:ok, compacted, metadata} = Ai.ContextCompactor.compact(context, strategy: :truncation)
  """
  @spec compact(Context.t(), compaction_opts()) ::
          {:ok, Context.t(), map()} | {:error, term()}
  def compact(%Context{} = context, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, default_strategy())
    preserve_recent = Keyword.get(opts, :preserve_recent, @default_preserve_recent)

    emit_telemetry(:compaction_started, %{
      strategy: strategy,
      original_message_count: length(context.messages),
      preserve_recent: preserve_recent
    })

    # Safety check: ensure we have enough context to work with
    if length(context.messages) <= preserve_recent do
      emit_telemetry(:compaction_failed, %{reason: :insufficient_messages})
      {:error, :insufficient_messages}
    else
      do_compact(context, strategy, opts)
    end
  end

  @doc """
  Get the default compaction strategy from configuration.
  """
  @spec default_strategy() :: strategy()
  def default_strategy do
    Application.get_env(:ai, __MODULE__, [])
    |> Keyword.get(:default_strategy, @default_strategy)
  end

  @doc """
  Get the maximum number of compaction attempts from configuration.
  """
  @spec max_attempts() :: non_neg_integer()
  def max_attempts do
    Application.get_env(:ai, __MODULE__, [])
    |> Keyword.get(:max_compaction_attempts, @default_max_attempts)
  end

  @doc """
  Check if compaction is enabled in configuration.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:ai, __MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  # ============================================================================
  # Compaction Strategies
  # ============================================================================

  defp do_compact(context, :truncation, opts) do
    preserve_recent = Keyword.get(opts, :preserve_recent, @default_preserve_recent)
    _target_tokens = Keyword.get(opts, :target_tokens)

    messages = Context.get_messages_chronological(context)
    total_count = length(messages)

    # Keep system prompt, recent messages, and optionally summarize middle
    {preserved, removed} = split_messages(messages, preserve_recent)

    # Create summary of removed messages if there are enough
    summary = if length(removed) > 2 do
      create_truncation_summary(removed)
    else
      nil
    end

    # Build new message list
    new_messages = build_truncated_messages(preserved, summary)

    # Estimate token savings
    tokens_saved = estimate_tokens_removed(removed)

    compacted = %Context{
      context
      | messages: Enum.reverse(new_messages)
    }

    metadata = %{
      strategy: :truncation,
      original_count: total_count,
      new_count: length(new_messages),
      removed_count: length(removed),
      tokens_saved: tokens_saved,
      has_summary: summary != nil
    }

    emit_telemetry(:compaction_succeeded, metadata)
    {:ok, compacted, metadata}
  end

  defp do_compact(context, :summarization, opts) do
    # Summarization requires a model call - for now, fall back to truncation
    # with a summary message indicating what would be summarized
    Logger.warning(
      "Summarization strategy requested but not yet fully implemented. " <>
      "Falling back to truncation with summary."
    )

    do_compact(context, :truncation, opts)
  end

  defp do_compact(context, :hybrid, opts) do
    # Hybrid: truncate oldest, keep recent, summarize middle
    # For now, this is similar to truncation but with different thresholds
    opts = Keyword.put(opts, :preserve_recent, 6)
    {:ok, compacted, metadata} = do_compact(context, :truncation, opts)
    # Override the strategy in metadata to reflect the requested strategy
    {:ok, compacted, %{metadata | strategy: :hybrid}}
  end

  defp do_compact(_context, strategy, _opts) do
    {:error, {:unknown_strategy, strategy}}
  end

  # ============================================================================
  # Truncation Helpers
  # ============================================================================

  defp split_messages(messages, preserve_count) do
    total = length(messages)

    if total <= preserve_count + 2 do
      # Not enough messages to remove meaningfully
      {messages, []}
    else
      # Keep first message (usually system/user), remove middle, keep last N
      [first | rest] = messages
      remove_count = max(1, total - preserve_count - 1)

      {to_remove, to_keep} = Enum.split(rest, remove_count)
      {[first | to_keep], to_remove}
    end
  end

  defp build_truncated_messages(preserved, nil) do
    Enum.map(preserved, & &1)
  end

  defp build_truncated_messages(preserved, summary) do
    # Insert summary as a system message before preserved messages
    summary_message = %Ai.Types.UserMessage{
      content: "[Context compacted: #{summary}]",
      timestamp: System.system_time(:millisecond)
    }

    [hd(preserved), summary_message | tl(preserved)]
  end

  defp create_truncation_summary(removed_messages) do
    # Create a brief summary of what was removed
    count = length(removed_messages)
    turns = div(count, 2)

    "#{count} messages (#{turns} conversation turns) removed to fit context window"
  end

  defp estimate_tokens_removed(messages) do
    # Rough estimate: ~4 chars per token on average
    messages
    |> Enum.map(&message_token_estimate/1)
    |> Enum.sum()
  end

  defp message_token_estimate(%Ai.Types.UserMessage{content: content}) when is_binary(content) do
    div(String.length(content), 4) + 4
  end

  defp message_token_estimate(%Ai.Types.UserMessage{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> div(String.length(text), 4)
      _ -> 10
    end)
    |> Enum.sum()
    |> Kernel.+(4)
  end

  defp message_token_estimate(%Ai.Types.AssistantMessage{content: content}) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> div(String.length(text), 4)
      %{thinking: thinking} when is_binary(thinking) -> div(String.length(thinking), 4)
      _ -> 10
    end)
    |> Enum.sum()
    |> Kernel.+(4)
  end

  defp message_token_estimate(%Ai.Types.ToolResultMessage{content: content}) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> div(String.length(text), 4)
      _ -> 10
    end)
    |> Enum.sum()
    |> Kernel.+(4)
  end

  defp message_token_estimate(_), do: 10

  # ============================================================================
  # Error Detection Helpers
  # ============================================================================

  defp context_length_error_code?(%{"error" => %{"code" => code}}) do
    code in ["context_length_exceeded", "max_tokens_exceeded", "token_limit_exceeded"]
  end

  defp context_length_error_code?(%{"error" => %{"type" => type}}) do
    type in ["context_length_exceeded", "max_tokens_exceeded"]
  end

  defp context_length_error_code?(_), do: false

  defp context_length_error_message?(status, body) when status in [400, 413, 422] do
    message = extract_message_text(body) || ""
    downcased = String.downcase(message)

    String.contains?(downcased, "context length") or
      String.contains?(downcased, "maximum context") or
      String.contains?(downcased, "token limit") or
      String.contains?(downcased, "too many tokens") or
      String.contains?(downcased, "exceeds maximum")
  end

  defp context_length_error_message?(_, _), do: false

  defp context_length_error_string?(status, body) when is_binary(body) do
    downcased = String.downcase(body)

    String.contains?(downcased, "context_length_exceeded") or
      String.contains?(downcased, "context length") or
      (status in [400, 413, 422] and
         (String.contains?(downcased, "maximum context") or
            String.contains?(downcased, "token limit")))
  end

  defp context_length_error_string?(_, _), do: false

  defp extract_message_text(%{"error" => %{"message" => message}}) when is_binary(message) do
    message
  end

  defp extract_message_text(%{"message" => message}) when is_binary(message) do
    message
  end

  defp extract_message_text(_), do: nil

  # ============================================================================
  # Telemetry
  # ============================================================================

  defp emit_telemetry(event, metadata) do
    LemonCore.Telemetry.emit(
      [:ai, :context_compactor, event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
