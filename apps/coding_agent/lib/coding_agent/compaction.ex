defmodule CodingAgent.Compaction do
  @moduledoc """
  Context compaction and branch summarization.

  This module handles automatic context compaction when conversations grow too large,
  as well as generating summaries for abandoned branches.

  ## Compaction Process

  1. Check if compaction is needed based on token usage and context window
  2. Find a valid cut point in the conversation history
  3. Generate a summary of the messages being compacted
  4. Extract file operations for context preservation

  ## Valid Cut Points

  Not all messages can be cut points. The compaction must not:
  - Cut in the middle of a tool call/result pair
  - Cut at points that would lose critical context

  Valid cut points are: user, assistant, custom, and bash_execution messages.
  """

  alias CodingAgent.Messages
  alias CodingAgent.Messages.ToolCall
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry

  # ============================================================================
  # Constants
  # ============================================================================

  @default_reserve_tokens 16384
  @default_keep_recent_tokens 20000
  @default_message_limit_trigger_ratio 0.9
  @default_message_limit_keep_ratio 0.6
  @default_message_limit_min_keep_messages 20

  @type message_budget :: %{
          request_limit: pos_integer(),
          trigger_count: pos_integer(),
          keep_recent_messages: pos_integer()
        }

  # ============================================================================
  # Compaction Decision
  # ============================================================================

  @doc """
  Check if compaction should be triggered.

  Compaction is triggered when the context tokens exceed the context window
  minus the reserve tokens (space for the model's response).

  ## Parameters

  - `context_tokens` - Current number of tokens in the context
  - `context_window` - Total context window size for the model
  - `settings` - Optional settings map with:
    - `:enabled` - Whether compaction is enabled (default: true)
    - `:reserve_tokens` - Tokens to reserve for output (default: 16384)

  ## Returns

  `true` if compaction should be triggered, `false` otherwise.
  """
  @spec should_compact?(non_neg_integer(), non_neg_integer(), map()) :: boolean()
  def should_compact?(context_tokens, context_window, settings \\ %{}) do
    enabled = Map.get(settings, :enabled, true)
    reserve_tokens = Map.get(settings, :reserve_tokens, @default_reserve_tokens)

    enabled && context_tokens > context_window - reserve_tokens
  end

  @doc """
  Build provider-specific message budget for preemptive compaction.

  Some providers cap request history by message count. When that limit is
  known, this returns thresholds that can trigger compaction before provider
  trimming starts dropping early context.
  """
  @spec message_budget(Ai.Types.Model.t() | map(), map()) :: message_budget() | nil
  def message_budget(model, settings \\ %{}) do
    case provider_request_message_limit(model) do
      limit when is_integer(limit) and limit > 1 ->
        trigger_ratio =
          ratio_or(
            Map.get(settings, :message_limit_trigger_ratio),
            @default_message_limit_trigger_ratio
          )

        keep_ratio =
          ratio_or(Map.get(settings, :message_limit_keep_ratio), @default_message_limit_keep_ratio)

        trigger_count =
          floor(limit * trigger_ratio)
          |> clamp_int(1, max(limit - 1, 1))

        keep_recent_messages =
          floor(limit * keep_ratio)
          |> max(@default_message_limit_min_keep_messages)
          |> min(max(trigger_count - 1, 1))

        %{
          request_limit: limit,
          trigger_count: trigger_count,
          keep_recent_messages: keep_recent_messages
        }

      _ ->
        nil
    end
  end

  @doc """
  Check if compaction should trigger based on provider message window limits.
  """
  @spec should_compact_for_message_limit?(non_neg_integer(), message_budget() | nil, map()) ::
          boolean()
  def should_compact_for_message_limit?(_message_count, nil, _settings), do: false

  def should_compact_for_message_limit?(message_count, %{trigger_count: trigger_count}, settings)
      when is_integer(message_count) do
    enabled = Map.get(settings, :enabled, true)
    enabled && message_count >= trigger_count
  end

  # ============================================================================
  # Cut Point Finding
  # ============================================================================

  # Default number of messages to keep as minimum context during forced compaction
  @default_min_keep_messages 5

  @doc """
  Find where to cut the conversation for compaction.

  Works backwards from the end of entries, counting tokens until reaching
  the `keep_recent_tokens` threshold. Returns the ID of the first entry
  to keep (everything before this will be compacted into a summary).

  ## Parameters

  - `branch_entries` - List of session entries on the current branch (path from root to leaf)
  - `keep_recent_tokens` - Number of tokens to keep uncompacted
  - `opts` - Options:
    - `:force` - When true, use fallback cut point if no valid cut point found based on tokens.
      The fallback keeps at least the last N messages (default 5) to preserve essential context.

  ## Returns

  - `{:ok, first_kept_entry_id}` - The ID of the first entry to keep
  - `{:error, :cannot_compact}` - Cannot find a valid cut point (only when force is false)

  ## Cut Point Rules

  Valid cut points are entries with messages of these roles:
  - `:user`
  - `:assistant` (only if not followed by tool_result)
  - `:custom`
  - `:bash_execution`

  Cannot cut in the middle of a tool call/result pair.
  """
  @spec find_cut_point([SessionEntry.t()], non_neg_integer(), keyword()) ::
          {:ok, String.t()} | {:error, :cannot_compact}
  def find_cut_point(
        branch_entries,
        keep_recent_tokens \\ @default_keep_recent_tokens,
        opts \\ []
      )

  def find_cut_point(branch_entries, keep_recent_tokens, opts) do
    force = Keyword.get(opts, :force, false)
    min_keep_messages = Keyword.get(opts, :min_keep_messages, @default_min_keep_messages)

    # Include both :message and :custom_message entries as valid candidates
    message_entries =
      branch_entries
      |> Enum.filter(fn entry -> entry.type in [:message, :custom_message] end)
      |> Enum.reject(fn entry ->
        # Reject :message entries with nil message, but keep all :custom_message entries
        entry.type == :message and is_nil(entry.message)
      end)

    if Enum.empty?(message_entries) do
      {:error, :cannot_compact}
    else
      case do_find_cut_point(message_entries, keep_recent_tokens) do
        {:ok, _} = result ->
          result

        {:error, :cannot_compact} when force ->
          # Force mode: find a fallback cut point that keeps minimal context
          find_forced_cut_point(message_entries, min_keep_messages)

        {:error, :cannot_compact} ->
          {:error, :cannot_compact}
      end
    end
  end

  defp do_find_cut_point(message_entries, keep_recent_tokens) do
    # Work backwards, accumulating tokens
    reversed = Enum.reverse(message_entries)

    {_total_tokens, cut_index} =
      Enum.reduce_while(reversed, {0, nil}, fn entry, {acc_tokens, _cut_idx} ->
        msg_tokens = estimate_entry_tokens(entry)
        new_total = acc_tokens + msg_tokens

        if new_total >= keep_recent_tokens do
          # We've accumulated enough tokens to keep, find valid cut point
          {:halt, {new_total, entry}}
        else
          {:cont, {new_total, entry}}
        end
      end)

    case cut_index do
      nil ->
        # Not enough tokens to warrant compaction
        {:error, :cannot_compact}

      entry ->
        # Find a valid cut point at or before this entry
        find_valid_cut_point(message_entries, entry)
    end
  end

  defp find_valid_cut_point(message_entries, target_entry) do
    # Find index of target entry
    target_idx = Enum.find_index(message_entries, fn e -> e.id == target_entry.id end)

    if is_nil(target_idx) or target_idx == 0 do
      {:error, :cannot_compact}
    else
      # Look backwards from target for a valid cut point
      entries_before_target = Enum.take(message_entries, target_idx)

      valid_cut =
        entries_before_target
        |> Enum.reverse()
        |> Enum.find(fn entry ->
          is_valid_cut_point?(entry, message_entries)
        end)

      case valid_cut do
        nil -> {:error, :cannot_compact}
        entry -> {:ok, entry.id}
      end
    end
  end

  defp is_valid_cut_point?(entry, all_entries) do
    # Handle custom_message entry type (different from :message with role "custom")
    if entry.type == :custom_message do
      # custom_message entries are always valid cut points
      # (they don't have tool calls that could create pairing issues)
      true
    else
      # Handle regular :message entries
      case entry.message do
        %{"role" => "user"} ->
          true

        %{"role" => "assistant"} = msg ->
          # Check if this assistant message has tool calls
          # If so, we need to ensure the tool results are included
          has_tool_calls = has_pending_tool_calls?(msg, entry, all_entries)
          not has_tool_calls

        %{"role" => "custom"} ->
          true

        %{"role" => "bash_execution"} ->
          true

        _ ->
          false
      end
    end
  end

  defp has_pending_tool_calls?(msg, entry, all_entries) do
    content = Map.get(msg, "content", [])

    tool_call_ids =
      content
      |> Enum.filter(fn
        %{"type" => "tool_call"} -> true
        %{type: :tool_call} -> true
        _ -> false
      end)
      |> Enum.map(fn tc -> Map.get(tc, "id") || Map.get(tc, :id) end)
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(tool_call_ids) do
      false
    else
      # Check if all tool calls have corresponding results after this entry
      entry_idx = Enum.find_index(all_entries, fn e -> e.id == entry.id end) || 0
      entries_after = Enum.drop(all_entries, entry_idx + 1)

      result_ids =
        entries_after
        |> Enum.filter(fn e ->
          case e.message do
            # Support both tool_call_id and tool_use_id for compatibility
            %{"role" => "tool_result", "tool_call_id" => id} -> id in tool_call_ids
            %{"role" => "tool_result", "tool_use_id" => id} -> id in tool_call_ids
            _ -> false
          end
        end)
        |> Enum.map(fn e ->
          # Extract ID from either field
          e.message["tool_call_id"] || e.message["tool_use_id"]
        end)

      # If any tool call doesn't have a result, this is not a valid cut point
      not Enum.all?(tool_call_ids, fn id -> id in result_ids end)
    end
  end

  # Find a fallback cut point for forced compaction.
  # Keeps at least min_keep_messages, ensuring we don't cut in the middle of
  # tool call/result pairs. Falls back to keeping the last user message
  # plus any trailing tool results if we can't keep the full min_keep_messages.
  defp find_forced_cut_point(message_entries, min_keep_messages) do
    total = length(message_entries)

    # We need at least 2 messages to compact (one to summarize, one to keep)
    if total < 2 do
      {:error, :cannot_compact}
    else
      # Try to keep min_keep_messages, but fall back to fewer if needed
      # Start from the position that would give us min_keep_messages to keep
      cut_position = max(1, total - min_keep_messages)

      # Find a valid cut point starting from cut_position and working backwards
      entries_to_check = Enum.take(message_entries, cut_position)

      valid_cut =
        entries_to_check
        |> Enum.reverse()
        |> Enum.find(fn entry ->
          is_valid_cut_point?(entry, message_entries)
        end)

      case valid_cut do
        nil ->
          # No valid cut point found in the preferred range.
          # Try to find ANY valid cut point from the first entry forward
          find_any_valid_cut_point(message_entries)

        entry ->
          {:ok, entry.id}
      end
    end
  end

  # Find the first valid cut point in the list (searching from start to end)
  # This is used as a last resort when forced compaction can't find a cut point
  # in the preferred range.
  defp find_any_valid_cut_point(message_entries) do
    # Skip the first entry (we need at least one message to compact)
    # and find the first valid cut point
    case message_entries do
      [_ | rest] when rest != [] ->
        valid_cut =
          rest
          |> Enum.find(fn entry ->
            is_valid_cut_point?(entry, message_entries)
          end)

        case valid_cut do
          nil -> {:error, :cannot_compact}
          entry -> {:ok, entry.id}
        end

      _ ->
        {:error, :cannot_compact}
    end
  end

  # ============================================================================
  # Token Calculation
  # ============================================================================

  @doc """
  Calculate total tokens from usage.

  Handles different usage formats:
  - Map with `:total_tokens` key
  - Map with `:input`, `:output`, `:cache_read`, `:cache_write` keys
  - Any other value returns 0
  """
  @spec total_tokens(map() | any()) :: non_neg_integer()
  def total_tokens(%{total_tokens: total}) when is_integer(total), do: total

  def total_tokens(%{input: i, output: o, cache_read: cr, cache_write: cw})
      when is_integer(i) and is_integer(o) and is_integer(cr) and is_integer(cw) do
    i + o + cr + cw
  end

  def total_tokens(%{input: i, output: o})
      when is_integer(i) and is_integer(o) do
    i + o
  end

  def total_tokens(_), do: 0

  @doc """
  Estimate tokens for a message.

  Uses a rough estimate of 4 characters per token.
  """
  @spec estimate_message_tokens(Messages.message()) :: non_neg_integer()
  def estimate_message_tokens(message) do
    text = Messages.get_text(message)
    div(String.length(text || ""), 4)
  end

  @doc """
  Estimate tokens for a list of messages.
  """
  @spec estimate_context_tokens([Messages.message()]) :: non_neg_integer()
  def estimate_context_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      acc + estimate_message_tokens(msg)
    end)
  end

  defp estimate_entry_tokens(%SessionEntry{message: nil, type: type})
       when type != :custom_message,
       do: 0

  # Handle custom_message entries which have content directly on the entry, not in a message field
  defp estimate_entry_tokens(%SessionEntry{type: :custom_message, content: content}) do
    text =
      case content do
        c when is_binary(c) -> c
        c when is_list(c) -> extract_text_from_content(c)
        _ -> inspect(content)
      end

    div(String.length(text || ""), 4)
  end

  defp estimate_entry_tokens(%SessionEntry{message: msg}) when is_map(msg) do
    # Estimate based on serialized message size
    text =
      case msg do
        %{"content" => content} when is_binary(content) -> content
        %{"content" => content} when is_list(content) -> extract_text_from_content(content)
        %{"output" => output} -> output
        %{"summary" => summary} -> summary
        _ -> Jason.encode!(msg)
      end

    div(String.length(text || ""), 4)
  end

  defp extract_text_from_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{type: :text, text: text} -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  # ============================================================================
  # Summary Generation
  # ============================================================================

  @doc """
  Generate a compaction summary using the LLM.

  Sends the messages to be compacted to the model with instructions to
  summarize the key information.

  ## Parameters

  - `messages_to_compact` - List of messages to summarize
  - `model` - The Ai.Types.Model to use for summarization
  - `opts` - Options:
    - `:custom_instructions` - Additional instructions for the summary
    - `:signal` - Abort signal for cancellation

  ## Returns

  - `{:ok, summary}` - The generated summary text
  - `{:error, reason}` - If summarization fails
  """
  @spec generate_summary([Messages.message()], Ai.Types.Model.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_summary(messages_to_compact, model, opts \\ []) do
    case Keyword.get(opts, :summary) do
      summary when is_binary(summary) and summary != "" ->
        {:ok, summary}

      _ ->
        custom_instructions = Keyword.get(opts, :custom_instructions)
        signal = Keyword.get(opts, :signal)

        # Check abort before starting
        if aborted?(signal) do
          {:error, :aborted}
        else
          do_generate_summary(messages_to_compact, model, custom_instructions, signal)
        end
    end
  end

  defp do_generate_summary(messages_to_compact, model, custom_instructions, signal) do
    system_prompt = build_summary_system_prompt(custom_instructions)

    # Convert messages to LLM format
    llm_messages = Messages.to_llm(messages_to_compact)

    # Build the summarization prompt
    messages_text =
      llm_messages
      |> Enum.map(&format_message_for_summary/1)
      |> Enum.join("\n\n---\n\n")

    user_prompt = """
    Please summarize the following conversation:

    #{messages_text}
    """

    # Create context for summarization
    context =
      Ai.Types.Context.new(system_prompt: system_prompt)
      |> Ai.Types.Context.add_user_message(user_prompt)

    # Check abort again before API call
    if aborted?(signal) do
      {:error, :aborted}
    else
      case Ai.complete(model, context, %{max_tokens: 2000}) do
        {:ok, response} ->
          summary = Ai.get_text(response)
          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_summary_system_prompt(custom_instructions) do
    base = """
    You are summarizing a conversation that is being compacted.
    Extract the key information that should be preserved for context:
    - What files were read or modified
    - Key decisions made
    - Important context about the task
    Keep the summary concise but complete.
    """

    if custom_instructions do
      base <> "\n\nAdditional instructions: #{custom_instructions}"
    else
      base
    end
  end

  defp format_message_for_summary(%Ai.Types.UserMessage{content: content}) do
    text =
      case content do
        c when is_binary(c) -> c
        c when is_list(c) -> extract_text_from_ai_content(c)
      end

    "[User]: #{text}"
  end

  defp format_message_for_summary(%Ai.Types.AssistantMessage{content: content}) do
    text = extract_text_from_ai_content(content)
    "[Assistant]: #{text}"
  end

  defp format_message_for_summary(%Ai.Types.ToolResultMessage{tool_name: name, content: content}) do
    text = extract_text_from_ai_content(content)
    "[Tool Result (#{name})]: #{String.slice(text, 0, 500)}..."
  end

  defp format_message_for_summary(_), do: ""

  defp extract_text_from_ai_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %Ai.Types.TextContent{text: text} -> text
      %{type: :text, text: text} -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_text_from_ai_content(content) when is_binary(content), do: content
  defp extract_text_from_ai_content(_), do: ""

  # ============================================================================
  # File Operations Extraction
  # ============================================================================

  @doc """
  Extract read/modified files from messages for compaction details.

  Scans tool calls for read, write, and edit operations and extracts
  the file paths.

  ## Parameters

  - `messages` - List of messages to scan

  ## Returns

  Map with:
  - `:read_files` - List of file paths that were read
  - `:modified_files` - List of file paths that were written or edited
  """
  @spec extract_file_operations([Messages.message()]) :: %{
          read_files: [String.t()],
          modified_files: [String.t()]
        }
  def extract_file_operations(messages) when is_list(messages) do
    initial = %{read_files: [], modified_files: []}

    messages
    |> Enum.reduce(initial, fn msg, acc ->
      tool_calls = Messages.get_tool_calls(msg)
      extract_ops_from_tool_calls(tool_calls, acc)
    end)
    |> Map.update!(:read_files, &Enum.uniq/1)
    |> Map.update!(:modified_files, &Enum.uniq/1)
  end

  defp extract_ops_from_tool_calls(tool_calls, acc) do
    Enum.reduce(tool_calls, acc, fn tool_call, inner_acc ->
      extract_op_from_tool_call(tool_call, inner_acc)
    end)
  end

  defp extract_op_from_tool_call(%ToolCall{name: "read", arguments: args}, acc) do
    case Map.get(args, "path") do
      nil -> acc
      path -> Map.update!(acc, :read_files, fn files -> [path | files] end)
    end
  end

  defp extract_op_from_tool_call(%ToolCall{name: "write", arguments: args}, acc) do
    case Map.get(args, "path") do
      nil -> acc
      path -> Map.update!(acc, :modified_files, fn files -> [path | files] end)
    end
  end

  defp extract_op_from_tool_call(%ToolCall{name: "edit", arguments: args}, acc) do
    case Map.get(args, "path") do
      nil -> acc
      path -> Map.update!(acc, :modified_files, fn files -> [path | files] end)
    end
  end

  defp extract_op_from_tool_call(_tool_call, acc), do: acc

  # ============================================================================
  # Branch Summarization
  # ============================================================================

  @doc """
  Generate a summary for an abandoned branch.

  Similar to compaction summary but focused on what was explored
  and why it was abandoned (if known).

  ## Parameters

  - `branch_entries` - List of session entries from the branch
  - `model` - The Ai.Types.Model to use for summarization
  - `opts` - Options:
    - `:custom_instructions` - Additional instructions for the summary
    - `:signal` - Abort signal for cancellation

  ## Returns

  - `{:ok, summary}` - The generated branch summary
  - `{:error, reason}` - If summarization fails
  """
  @spec generate_branch_summary([SessionEntry.t()], Ai.Types.Model.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_branch_summary(branch_entries, model, opts \\ []) do
    case Keyword.get(opts, :summary) do
      summary when is_binary(summary) and summary != "" ->
        {:ok, summary}

      _ ->
        custom_instructions = Keyword.get(opts, :custom_instructions)
        signal = Keyword.get(opts, :signal)

        if aborted?(signal) do
          {:error, :aborted}
        else
          do_generate_branch_summary(branch_entries, model, custom_instructions, signal)
        end
    end
  end

  defp do_generate_branch_summary(branch_entries, model, custom_instructions, signal) do
    system_prompt = build_branch_summary_prompt(custom_instructions)

    # Extract messages from entries
    messages =
      branch_entries
      |> Enum.filter(fn entry -> entry.type == :message end)
      |> Enum.map(fn entry -> entry.message end)
      |> Enum.reject(&is_nil/1)

    messages_text =
      messages
      |> Enum.map(&format_raw_message_for_summary/1)
      |> Enum.join("\n\n---\n\n")

    user_prompt = """
    Please summarize what was explored in this branch:

    #{messages_text}
    """

    context =
      Ai.Types.Context.new(system_prompt: system_prompt)
      |> Ai.Types.Context.add_user_message(user_prompt)

    if aborted?(signal) do
      {:error, :aborted}
    else
      case Ai.complete(model, context, %{max_tokens: 1000}) do
        {:ok, response} ->
          summary = Ai.get_text(response)
          {:ok, summary}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_branch_summary_prompt(custom_instructions) do
    base = """
    You are summarizing an abandoned conversation branch.
    Focus on:
    - What approach was being explored
    - What was tried
    - Why it may have been abandoned (if apparent)
    Keep the summary brief but informative.
    """

    if custom_instructions do
      base <> "\n\nAdditional instructions: #{custom_instructions}"
    else
      base
    end
  end

  defp format_raw_message_for_summary(%{"role" => "user", "content" => content})
       when is_binary(content) do
    "[User]: #{content}"
  end

  defp format_raw_message_for_summary(%{"role" => "assistant", "content" => content})
       when is_list(content) do
    text = extract_text_from_content(content)
    "[Assistant]: #{text}"
  end

  defp format_raw_message_for_summary(%{"role" => "tool_result", "content" => content}) do
    text = extract_text_from_content(content)
    "[Tool Result]: #{String.slice(text, 0, 200)}..."
  end

  defp format_raw_message_for_summary(_), do: ""

  # ============================================================================
  # Perform Compaction
  # ============================================================================

  @doc """
  Perform compaction on a session.

  This is the main entry point for compaction. It:
  1. Builds the session context to get messages
  2. Finds a valid cut point
  3. Generates a summary of compacted messages
  4. Extracts file operations

  ## Parameters

  - `session` - The SessionManager.Session to compact
  - `model` - The Ai.Types.Model to use for summarization
  - `opts` - Options:
    - `:keep_recent_tokens` - Number of tokens to keep (default: 20000)
    - `:force` - When true, forces compaction even if there isn't enough context
      to meet the keep_recent_tokens threshold. Falls back to keeping at least
      the last 5 messages (or fewer if not enough valid cut points exist).
      Default: false
    - `:min_keep_messages` - Minimum messages to keep during forced compaction (default: 5)
    - `:custom_instructions` - Custom instructions for summarization
    - `:signal` - Abort signal for cancellation

  ## Returns

  - `{:ok, compaction_result}` - Success with:
    - `:summary` - The generated summary
    - `:first_kept_entry_id` - ID of first entry to keep
    - `:tokens_before` - Token count before compaction
    - `:details` - File operations extracted
  - `{:error, :cannot_compact}` - When no valid cut point can be found (only when force: false)
  - `{:error, reason}` - If compaction fails for other reasons
  """
  @spec compact(SessionManager.Session.t(), Ai.Types.Model.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def compact(%SessionManager.Session{} = session, model, opts \\ []) do
    keep_recent_tokens = Keyword.get(opts, :keep_recent_tokens, @default_keep_recent_tokens)
    signal = Keyword.get(opts, :signal)

    if aborted?(signal) do
      {:error, :aborted}
    else
      do_compact(session, model, keep_recent_tokens, opts, signal)
    end
  end

  defp do_compact(session, model, keep_recent_tokens, opts, signal) do
    # Get the current branch (path from root to current leaf)
    # Compaction should only consider entries on this branch, not other branches
    branch = SessionManager.get_branch(session)

    # Get all messages from current branch for token estimation
    context = SessionManager.build_session_context(session)
    messages = context.messages

    # Build options for find_cut_point
    cut_point_opts = Keyword.take(opts, [:force, :min_keep_messages])

    with {:ok, first_kept_id} <- find_cut_point(branch, keep_recent_tokens, cut_point_opts),
         :ok <- check_abort(signal),
         messages_to_compact <- get_messages_before(branch, first_kept_id),
         :ok <- check_abort(signal),
         {:ok, summary} <- generate_summary(messages_to_compact, model, opts),
         :ok <- check_abort(signal) do
      file_ops = extract_file_operations(messages_to_compact)
      tokens_before = estimate_raw_context_tokens(messages)

      {:ok,
       %{
         summary: summary,
         first_kept_entry_id: first_kept_id,
         tokens_before: tokens_before,
         details: file_ops
       }}
    end
  end

  defp get_messages_before(branch_entries, first_kept_id) do
    # Get messages from the branch up to (but not including) the first kept entry
    {messages_before, _} =
      Enum.reduce(branch_entries, {[], false}, fn entry, {acc, found} ->
        if found do
          {acc, true}
        else
          if entry.id == first_kept_id do
            {acc, true}
          else
            case entry do
              %{type: :message, message: msg} when not is_nil(msg) ->
                # Convert raw message to proper message struct
                {[convert_raw_message(msg) | acc], false}

              %{type: :custom_message} = custom_entry ->
                # Convert custom_message entry to CustomMessage struct
                {[entry_to_custom_message(custom_entry) | acc], false}

              _ ->
                {acc, false}
            end
          end
        end
      end)

    Enum.reverse(messages_before)
  end

  defp entry_to_custom_message(%{type: :custom_message} = entry) do
    %Messages.CustomMessage{
      role: :custom,
      custom_type: entry.custom_type,
      content: entry.content,
      display: if(is_nil(entry.display), do: true, else: entry.display),
      details: entry.details,
      timestamp: entry.timestamp
    }
  end

  defp convert_raw_message(%{"role" => "user", "content" => content} = msg) do
    %Messages.UserMessage{
      role: :user,
      content: content,
      timestamp: Map.get(msg, "timestamp", 0)
    }
  end

  defp convert_raw_message(%{"role" => "assistant", "content" => content} = msg) do
    %Messages.AssistantMessage{
      role: :assistant,
      content: convert_content_blocks(content),
      provider: Map.get(msg, "provider", ""),
      model: Map.get(msg, "model", ""),
      api: Map.get(msg, "api", ""),
      timestamp: Map.get(msg, "timestamp", 0)
    }
  end

  defp convert_raw_message(%{"role" => "tool_result"} = msg) do
    # Support both tool_call_id and tool_use_id for compatibility
    tool_id = Map.get(msg, "tool_call_id") || Map.get(msg, "tool_use_id", "")

    %Messages.ToolResultMessage{
      role: :tool_result,
      tool_use_id: tool_id,
      content: convert_content_blocks(Map.get(msg, "content", [])),
      is_error: Map.get(msg, "is_error", false),
      timestamp: Map.get(msg, "timestamp", 0)
    }
  end

  defp convert_raw_message(%{"role" => "bash_execution"} = msg) do
    %Messages.BashExecutionMessage{
      role: :bash_execution,
      command: Map.get(msg, "command", ""),
      output: Map.get(msg, "output", ""),
      exit_code: Map.get(msg, "exit_code"),
      cancelled: Map.get(msg, "cancelled", false),
      truncated: Map.get(msg, "truncated", false),
      timestamp: Map.get(msg, "timestamp", 0)
    }
  end

  defp convert_raw_message(%{"role" => "custom"} = msg) do
    %Messages.CustomMessage{
      role: :custom,
      custom_type: Map.get(msg, "custom_type", ""),
      content: Map.get(msg, "content", ""),
      display: Map.get(msg, "display", true),
      details: Map.get(msg, "details"),
      timestamp: Map.get(msg, "timestamp", 0)
    }
  end

  defp convert_raw_message(msg), do: msg

  defp convert_content_blocks(content) when is_list(content) do
    Enum.map(content, &convert_content_block/1)
  end

  defp convert_content_blocks(content) when is_binary(content), do: content
  defp convert_content_blocks(_), do: []

  defp convert_content_block(%{"type" => "text", "text" => text}) do
    %Messages.TextContent{type: :text, text: text}
  end

  defp convert_content_block(%{"type" => "tool_call", "id" => id, "name" => name} = tc) do
    %Messages.ToolCall{
      type: :tool_call,
      id: id,
      name: name,
      arguments: Map.get(tc, "arguments", %{})
    }
  end

  defp convert_content_block(%{"type" => "thinking", "thinking" => thinking}) do
    %Messages.ThinkingContent{type: :thinking, thinking: thinking}
  end

  defp convert_content_block(block), do: block

  defp estimate_raw_context_tokens(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc ->
      text =
        case msg do
          %{"content" => content} when is_binary(content) -> content
          %{"content" => content} when is_list(content) -> extract_text_from_content(content)
          _ -> Jason.encode!(msg)
        end

      acc + div(String.length(text || ""), 4)
    end)
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  defp aborted?(nil), do: false

  defp aborted?(signal) do
    if function_exported?(AgentCore.AbortSignal, :aborted?, 1) do
      AgentCore.AbortSignal.aborted?(signal)
    else
      false
    end
  end

  defp check_abort(signal) do
    if aborted?(signal) do
      {:error, :aborted}
    else
      :ok
    end
  end
end
