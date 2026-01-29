defmodule CodingAgent.Tools.Truncate do
  @moduledoc """
  Truncate tool for the coding agent.

  Truncates long text to fit within token/character limits while
  preserving useful content. Supports multiple truncation strategies:

  - `head` - Keep beginning, truncate end
  - `tail` - Keep end, truncate beginning
  - `middle` - Keep beginning and end, truncate middle
  - `smart` - Analyze content and keep most relevant parts
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.TextContent

  @default_max_chars 50_000
  @default_strategy "smart"
  @default_preserve_structure true

  # Markers used in truncation
  @head_marker_template "\n... [%{count} truncated] ..."
  @tail_marker_template "... [%{count} truncated] ...\n"
  @middle_marker_template "\n... [%{count} truncated] ...\n"

  @doc """
  Returns the Truncate tool definition.

  ## Options

  No options currently supported.
  """
  @spec tool(opts :: keyword()) :: AgentTool.t()
  def tool(opts \\ []) do
    %AgentTool{
      name: "truncate",
      description: """
      Truncate long text to fit within character limits while preserving useful content.
      Supports strategies: "head" (keep beginning), "tail" (keep end), "middle" (keep both ends), "smart" (preserve code structure).
      """,
      label: "Truncate Text",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "text" => %{
            "type" => "string",
            "description" => "The text to truncate"
          },
          "max_chars" => %{
            "type" => "integer",
            "description" => "Maximum characters (default: 50000)"
          },
          "max_lines" => %{
            "type" => "integer",
            "description" => "Maximum lines (optional)"
          },
          "strategy" => %{
            "type" => "string",
            "enum" => ["head", "tail", "middle", "smart"],
            "description" => "Truncation strategy (default: smart)"
          },
          "preserve_structure" => %{
            "type" => "boolean",
            "description" => "Try to preserve code structure (default: true)"
          }
        },
        "required" => ["text"]
      },
      execute: &execute(&1, &2, &3, &4, opts)
    }
  end

  @doc """
  Execute the truncate tool.

  ## Parameters

  - `tool_call_id` - Unique identifier for this tool invocation
  - `params` - Parameters map with "text" and optional settings
  - `signal` - Abort signal for cancellation (can be nil)
  - `on_update` - Callback for streaming partial results (unused)
  - `opts` - Tool options

  ## Returns

  - `AgentToolResult.t()` - Result with truncated text and metadata
  - `{:error, term()}` - Error if truncation fails
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: function() | nil,
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, _on_update, _opts) do
    if aborted?(signal) do
      {:error, "Operation aborted"}
    else
      do_execute(params)
    end
  end

  defp do_execute(params) do
    text = Map.get(params, "text", "")
    max_chars = Map.get(params, "max_chars", @default_max_chars)
    max_lines = Map.get(params, "max_lines")
    strategy = Map.get(params, "strategy", @default_strategy)
    preserve_structure = Map.get(params, "preserve_structure", @default_preserve_structure)

    cond do
      text == "" ->
        build_result("", %{
          original_chars: 0,
          original_lines: 0,
          truncated_chars: 0,
          truncated_lines: 0,
          truncated: false,
          strategy: strategy
        })

      not valid_strategy?(strategy) ->
        {:error, "Invalid strategy: #{strategy}. Must be one of: head, tail, middle, smart"}

      true ->
        truncate_text(text, max_chars, max_lines, strategy, preserve_structure)
    end
  end

  defp valid_strategy?(strategy), do: strategy in ["head", "tail", "middle", "smart"]

  # ============================================================================
  # Main Truncation Logic
  # ============================================================================

  defp truncate_text(text, max_chars, max_lines, strategy, preserve_structure) do
    original_chars = String.length(text)
    original_lines = count_lines(text)

    # Apply line limit first if specified
    text_after_lines =
      if max_lines && original_lines > max_lines do
        apply_line_limit(text, max_lines, strategy)
      else
        text
      end

    # Then apply character limit
    {truncated, chars_removed} =
      if String.length(text_after_lines) > max_chars do
        apply_char_limit(text_after_lines, max_chars, strategy, preserve_structure)
      else
        {text_after_lines, 0}
      end

    truncated_chars = String.length(truncated)
    truncated_lines = count_lines(truncated)
    was_truncated = truncated_chars < original_chars || truncated_lines < original_lines

    build_result(truncated, %{
      original_chars: original_chars,
      original_lines: original_lines,
      truncated_chars: truncated_chars,
      truncated_lines: truncated_lines,
      chars_removed: chars_removed,
      truncated: was_truncated,
      strategy: strategy
    })
  end

  defp count_lines(text) do
    text
    |> String.split("\n")
    |> length()
  end

  # ============================================================================
  # Line Limit Application
  # ============================================================================

  defp apply_line_limit(text, max_lines, strategy) do
    lines = String.split(text, "\n")
    total_lines = length(lines)
    lines_to_remove = total_lines - max_lines

    case strategy do
      "head" ->
        kept = Enum.take(lines, max_lines)
        marker = format_marker(@head_marker_template, lines_to_remove, :lines)
        Enum.join(kept, "\n") <> marker

      "tail" ->
        kept = Enum.drop(lines, lines_to_remove)
        marker = format_marker(@tail_marker_template, lines_to_remove, :lines)
        marker <> Enum.join(kept, "\n")

      "middle" ->
        head_lines = div(max_lines, 2)
        tail_lines = max_lines - head_lines
        head = Enum.take(lines, head_lines)
        tail = Enum.take(lines, -tail_lines)
        marker = format_marker(@middle_marker_template, lines_to_remove, :lines)
        Enum.join(head, "\n") <> marker <> Enum.join(tail, "\n")

      "smart" ->
        # For smart strategy, try to keep structural elements
        apply_smart_line_limit(lines, max_lines, lines_to_remove)
    end
  end

  defp apply_smart_line_limit(lines, max_lines, lines_to_remove) do
    # Identify important lines (function defs, imports, module defs, etc.)
    indexed_lines = Enum.with_index(lines)
    important_indices = find_important_line_indices(indexed_lines)

    # Keep important lines plus fill remaining with head/tail
    important_count = min(length(important_indices), div(max_lines, 2))
    remaining_lines = max_lines - important_count

    head_count = div(remaining_lines, 2)
    tail_count = remaining_lines - head_count

    head_lines = Enum.take(lines, head_count)
    tail_lines = Enum.take(lines, -tail_count)

    # Get important lines that aren't in head or tail
    important_lines =
      important_indices
      |> Enum.take(important_count)
      |> Enum.filter(fn idx -> idx >= head_count and idx < length(lines) - tail_count end)
      |> Enum.map(fn idx -> Enum.at(lines, idx) end)

    marker = format_marker(@middle_marker_template, lines_to_remove, :lines)

    if important_lines == [] do
      Enum.join(head_lines, "\n") <> marker <> Enum.join(tail_lines, "\n")
    else
      Enum.join(head_lines, "\n") <>
        marker <>
        Enum.join(important_lines, "\n") <>
        marker <>
        Enum.join(tail_lines, "\n")
    end
  end

  defp find_important_line_indices(indexed_lines) do
    indexed_lines
    |> Enum.filter(fn {line, _idx} -> important_line?(line) end)
    |> Enum.map(fn {_line, idx} -> idx end)
  end

  defp important_line?(line) do
    trimmed = String.trim(line)

    cond do
      # Elixir/Erlang
      String.starts_with?(trimmed, "defmodule ") -> true
      String.starts_with?(trimmed, "def ") -> true
      String.starts_with?(trimmed, "defp ") -> true
      String.starts_with?(trimmed, "defmacro ") -> true
      String.starts_with?(trimmed, "import ") -> true
      String.starts_with?(trimmed, "alias ") -> true
      String.starts_with?(trimmed, "use ") -> true
      String.starts_with?(trimmed, "require ") -> true
      # Python
      String.starts_with?(trimmed, "def ") -> true
      String.starts_with?(trimmed, "class ") -> true
      String.starts_with?(trimmed, "import ") -> true
      String.starts_with?(trimmed, "from ") -> true
      # JavaScript/TypeScript
      String.starts_with?(trimmed, "function ") -> true
      String.starts_with?(trimmed, "export ") -> true
      String.starts_with?(trimmed, "import ") -> true
      String.starts_with?(trimmed, "const ") -> true
      String.starts_with?(trimmed, "class ") -> true
      String.contains?(trimmed, " = function") -> true
      String.contains?(trimmed, " => {") -> true
      # Rust
      String.starts_with?(trimmed, "fn ") -> true
      String.starts_with?(trimmed, "pub fn ") -> true
      String.starts_with?(trimmed, "impl ") -> true
      String.starts_with?(trimmed, "struct ") -> true
      String.starts_with?(trimmed, "enum ") -> true
      String.starts_with?(trimmed, "mod ") -> true
      String.starts_with?(trimmed, "use ") -> true
      # Go
      String.starts_with?(trimmed, "func ") -> true
      String.starts_with?(trimmed, "type ") -> true
      String.starts_with?(trimmed, "package ") -> true
      # General
      String.starts_with?(trimmed, "@doc") -> true
      String.starts_with?(trimmed, "@moduledoc") -> true
      String.starts_with?(trimmed, "//") and String.contains?(trimmed, "TODO") -> true
      String.starts_with?(trimmed, "#") and String.contains?(trimmed, "TODO") -> true
      true -> false
    end
  end

  # ============================================================================
  # Character Limit Application
  # ============================================================================

  defp apply_char_limit(text, max_chars, strategy, preserve_structure) do
    text_length = String.length(text)
    chars_to_remove = text_length - max_chars

    case strategy do
      "head" ->
        apply_head_truncation(text, max_chars, chars_to_remove)

      "tail" ->
        apply_tail_truncation(text, max_chars, chars_to_remove)

      "middle" ->
        apply_middle_truncation(text, max_chars, chars_to_remove)

      "smart" ->
        if preserve_structure do
          apply_smart_truncation(text, max_chars, chars_to_remove)
        else
          apply_middle_truncation(text, max_chars, chars_to_remove)
        end
    end
  end

  defp apply_head_truncation(text, max_chars, chars_to_remove) do
    marker = format_marker(@head_marker_template, chars_to_remove, :chars)
    marker_length = String.length(marker)
    keep_chars = max_chars - marker_length

    if keep_chars > 0 do
      truncated = String.slice(text, 0, keep_chars)
      # Try to break at a line boundary
      truncated = break_at_line_boundary(truncated, :tail)
      {truncated <> marker, chars_to_remove}
    else
      {marker, chars_to_remove}
    end
  end

  defp apply_tail_truncation(text, max_chars, chars_to_remove) do
    marker = format_marker(@tail_marker_template, chars_to_remove, :chars)
    marker_length = String.length(marker)
    keep_chars = max_chars - marker_length

    if keep_chars > 0 do
      text_length = String.length(text)
      truncated = String.slice(text, text_length - keep_chars, keep_chars)
      # Try to break at a line boundary
      truncated = break_at_line_boundary(truncated, :head)
      {marker <> truncated, chars_to_remove}
    else
      {marker, chars_to_remove}
    end
  end

  defp apply_middle_truncation(text, max_chars, chars_to_remove) do
    marker = format_marker(@middle_marker_template, chars_to_remove, :chars)
    marker_length = String.length(marker)
    keep_chars = max_chars - marker_length

    if keep_chars > 0 do
      head_chars = div(keep_chars, 2)
      tail_chars = keep_chars - head_chars

      text_length = String.length(text)
      head = String.slice(text, 0, head_chars)
      tail = String.slice(text, text_length - tail_chars, tail_chars)

      # Try to break at line boundaries
      head = break_at_line_boundary(head, :tail)
      tail = break_at_line_boundary(tail, :head)

      {head <> marker <> tail, chars_to_remove}
    else
      {marker, chars_to_remove}
    end
  end

  defp apply_smart_truncation(text, max_chars, chars_to_remove) do
    # Parse to find structural elements
    lines = String.split(text, "\n")

    # Find important sections
    {head_section, middle_important, tail_section} = extract_smart_sections(lines, max_chars)

    marker = format_marker(@middle_marker_template, chars_to_remove, :chars)

    result =
      if middle_important == "" do
        head_section <> marker <> tail_section
      else
        # Double marker when we have middle important content
        head_section <> marker <> middle_important <> marker <> tail_section
      end

    # Final check - if still too long, fall back to middle truncation
    if String.length(result) > max_chars do
      apply_middle_truncation(text, max_chars, chars_to_remove)
    else
      {result, chars_to_remove}
    end
  end

  defp extract_smart_sections(lines, max_chars) do
    # Allocate budget: 40% head, 20% important middle, 40% tail
    head_budget = div(max_chars * 4, 10)
    middle_budget = div(max_chars * 2, 10)
    tail_budget = div(max_chars * 4, 10)

    # Extract head section
    {head_lines, _} = take_lines_up_to_chars(lines, head_budget)
    head_section = Enum.join(head_lines, "\n")

    # Extract tail section
    reversed_lines = Enum.reverse(lines)
    {tail_lines_rev, _} = take_lines_up_to_chars(reversed_lines, tail_budget)
    tail_section = tail_lines_rev |> Enum.reverse() |> Enum.join("\n")

    # Find important lines in the middle
    head_count = length(head_lines)
    tail_count = length(tail_lines_rev)
    middle_lines = lines |> Enum.drop(head_count) |> Enum.take(length(lines) - head_count - tail_count)

    important_middle_lines =
      middle_lines
      |> Enum.filter(&important_line?/1)

    {important_middle, _} = take_lines_up_to_chars(important_middle_lines, middle_budget)
    middle_section = Enum.join(important_middle, "\n")

    {head_section, middle_section, tail_section}
  end

  defp take_lines_up_to_chars(lines, max_chars) do
    take_lines_up_to_chars(lines, max_chars, 0, [])
  end

  defp take_lines_up_to_chars([], _max_chars, acc_chars, acc_lines) do
    {Enum.reverse(acc_lines), acc_chars}
  end

  defp take_lines_up_to_chars([line | rest], max_chars, acc_chars, acc_lines) do
    line_chars = String.length(line) + 1  # +1 for newline

    if acc_chars + line_chars > max_chars and acc_lines != [] do
      {Enum.reverse(acc_lines), acc_chars}
    else
      take_lines_up_to_chars(rest, max_chars, acc_chars + line_chars, [line | acc_lines])
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp break_at_line_boundary(text, :tail) do
    # Find last newline in text and truncate there
    case :binary.match(String.reverse(text), "\n") do
      {pos, _} ->
        len = String.length(text)
        String.slice(text, 0, len - pos - 1)

      :nomatch ->
        text
    end
  end

  defp break_at_line_boundary(text, :head) do
    # Find first newline in text and start from there
    case :binary.match(text, "\n") do
      {pos, _} ->
        String.slice(text, pos + 1, String.length(text) - pos - 1)

      :nomatch ->
        text
    end
  end

  defp format_marker(template, count, unit) do
    unit_str = if unit == :lines, do: " lines", else: " chars"
    String.replace(template, "%{count}", "#{count}#{unit_str}")
  end

  defp build_result(truncated_text, metadata) do
    summary =
      if metadata.truncated do
        "Truncated from #{metadata.original_chars} to #{metadata.truncated_chars} chars " <>
          "(#{metadata.original_lines} to #{metadata.truncated_lines} lines) using #{metadata.strategy} strategy"
      else
        "No truncation needed (#{metadata.original_chars} chars, #{metadata.original_lines} lines)"
      end

    %AgentToolResult{
      content: [%TextContent{text: truncated_text}],
      details: Map.put(metadata, :summary, summary)
    }
  end

  # ============================================================================
  # Abort Signal Handling
  # ============================================================================

  defp aborted?(nil), do: false
  defp aborted?(signal), do: AgentCore.AbortSignal.aborted?(signal)
end
