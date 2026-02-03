defmodule LemonGateway.Telegram.Truncate do
  @moduledoc """
  Truncation logic for Telegram messages that preserves resume lines.

  Telegram has a message length limit of 4096 characters. When a message
  exceeds this limit, we need to truncate it while preserving any resume
  lines (e.g., "lemon resume abc123") at the end of the message so users
  can continue their session.

  ## Algorithm

  1. Split text into lines
  2. Identify resume lines at the end using engine.is_resume_line/1
  3. Calculate space needed for resume lines
  4. Truncate the remaining content to fit within the limit
  5. Add an ellipsis marker if truncation occurred
  """

  @telegram_max_length 4096
  @ellipsis "..."

  @doc """
  Truncate text to fit within Telegram's message limit while preserving resume lines.

  The engine module is used to identify resume lines via its `is_resume_line/1` callback.
  Resume lines at the end of the message are preserved even if truncation is needed.

  ## Parameters

  - `text` - The message text to potentially truncate
  - `engine_module` - The engine module implementing `is_resume_line/1`

  ## Returns

  The (possibly truncated) text that fits within Telegram's 4096 character limit.

  ## Examples

      iex> short_text = "Hello world"
      iex> Truncate.truncate_for_telegram(short_text, LemonGateway.Engines.Echo)
      "Hello world"

      iex> long_text = String.duplicate("x", 5000) <> "\\nlemon resume abc123"
      iex> result = Truncate.truncate_for_telegram(long_text, LemonGateway.Engines.Echo)
      iex> String.length(result) <= 4096
      true
      iex> String.ends_with?(result, "lemon resume abc123")
      true

  """
  @spec truncate_for_telegram(String.t(), module()) :: String.t()
  def truncate_for_telegram(text, engine_module) when is_binary(text) do
    if String.length(text) <= @telegram_max_length do
      text
    else
      do_truncate(text, engine_module)
    end
  end

  def truncate_for_telegram(text, _engine_module), do: text

  @doc """
  Truncate text to fit within Telegram's message limit (engine-agnostic version).

  Uses a generic resume line detector that recognizes all common resume patterns.

  ## Parameters

  - `text` - The message text to potentially truncate

  ## Returns

  The (possibly truncated) text that fits within Telegram's 4096 character limit.
  """
  @spec truncate_for_telegram(String.t()) :: String.t()
  def truncate_for_telegram(text) when is_binary(text) do
    if String.length(text) <= @telegram_max_length do
      text
    else
      do_truncate(text, nil)
    end
  end

  def truncate_for_telegram(text), do: text

  defp do_truncate(text, engine_module) do
    lines = String.split(text, "\n")

    # Find trailing resume lines
    {content_lines, resume_lines} = split_trailing_resume_lines(lines, engine_module)

    # Calculate space budget
    resume_text = Enum.join(resume_lines, "\n")
    resume_length = String.length(resume_text)

    # Reserve space for: ellipsis + newline (if we have content) + resume lines
    ellipsis_with_sep = @ellipsis <> if(resume_lines != [], do: "\n", else: "")
    ellipsis_len = String.length(ellipsis_with_sep)

    # Space available for content
    available_for_content =
      @telegram_max_length - resume_length - ellipsis_len -
        if(resume_lines != [], do: 1, else: 0)

    # If resume lines alone exceed the limit, truncate them too
    if available_for_content <= 0 do
      truncate_plain(text)
    else
      truncated_content = truncate_content(content_lines, available_for_content)

      cond do
        # Content fits without truncation
        truncated_content == Enum.join(content_lines, "\n") && resume_lines == [] ->
          text

        truncated_content == Enum.join(content_lines, "\n") ->
          # No content truncation needed, just rebuild
          if resume_lines == [] do
            truncated_content
          else
            truncated_content <> "\n" <> resume_text
          end

        resume_lines == [] ->
          # Truncated, no resume lines
          truncated_content <> @ellipsis

        true ->
          # Truncated with resume lines
          truncated_content <> @ellipsis <> "\n" <> resume_text
      end
    end
  end

  # Split lines into content and trailing resume lines
  defp split_trailing_resume_lines(lines, engine_module) do
    {resume_rev, content_rev} =
      lines
      |> Enum.reverse()
      |> Enum.reduce({[], nil}, fn line, {resume_acc, content_acc} ->
        cond do
          # Already found non-resume content, everything else is content
          content_acc != nil ->
            {resume_acc, [line | content_acc]}

          # Empty lines at the end - could be part of resume section
          String.trim(line) == "" && resume_acc != [] ->
            {[line | resume_acc], content_acc}

          # Check if this is a resume line
          is_resume_line?(line, engine_module) ->
            {[line | resume_acc], content_acc}

          # First non-resume line found
          true ->
            {resume_acc, [line]}
        end
      end)

    content_lines =
      case content_rev do
        nil -> []
        lines -> lines
      end

    {content_lines, resume_rev}
  end

  defp is_resume_line?(line, nil) do
    # Use the generic detector from AgentCore when no engine specified
    AgentCore.CliRunners.Types.ResumeToken.is_resume_line(line)
  end

  defp is_resume_line?(line, engine_module) when is_atom(engine_module) do
    engine_module.is_resume_line(line)
  end

  # Truncate content lines to fit within the budget
  defp truncate_content([], _budget), do: ""

  defp truncate_content(lines, budget) do
    full_content = Enum.join(lines, "\n")

    if String.length(full_content) <= budget do
      full_content
    else
      # Binary search for the right amount of content
      truncate_to_length(full_content, budget)
    end
  end

  # Truncate a string to fit within a character budget, trying to break at word boundaries
  defp truncate_to_length(_text, budget) when budget <= 0, do: ""

  defp truncate_to_length(text, budget) do
    if String.length(text) <= budget do
      text
    else
      # Take up to budget characters
      truncated = String.slice(text, 0, budget)

      # Try to find a good break point (newline or space)
      case find_break_point(truncated) do
        nil ->
          # No good break point, just use the hard cutoff
          truncated

        pos ->
          String.slice(truncated, 0, pos)
      end
    end
  end

  # Find the last newline or space in the string for a cleaner break
  defp find_break_point(text) do
    len = String.length(text)

    # Only look in the last 100 characters for a break point
    search_start = max(0, len - 100)
    search_text = String.slice(text, search_start, len - search_start)

    # Prefer newline, then space
    case :binary.match(String.reverse(search_text), "\n") do
      {pos, _} ->
        search_start + String.length(search_text) - pos - 1

      :nomatch ->
        case :binary.match(String.reverse(search_text), " ") do
          {pos, _} ->
            search_start + String.length(search_text) - pos - 1

          :nomatch ->
            nil
        end
    end
  end

  # Plain truncation without resume line preservation
  defp truncate_plain(text) do
    budget = @telegram_max_length - String.length(@ellipsis)
    truncate_to_length(text, budget) <> @ellipsis
  end

  @doc """
  Returns the Telegram message length limit.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @telegram_max_length
end
