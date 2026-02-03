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
    {content_lines, resume_lines} = split_trailing_resume_lines(lines, engine_module)

    {content_lines, resume_lines} =
      case resume_lines do
        [] ->
          case extract_trailing_resume_line(text) do
            nil ->
              {content_lines, resume_lines}

            resume_line ->
              content_text =
                text
                |> String.replace_suffix(resume_line, "")
                |> String.trim_trailing("\n")

              content_lines =
                case content_text do
                  "" -> []
                  _ -> String.split(content_text, "\n")
                end

              {content_lines, [resume_line]}
          end

        _ ->
          {content_lines, resume_lines}
      end

    # Calculate space budget
    resume_text = Enum.join(resume_lines, "\n")
    resume_length = String.length(resume_text)

    # Reserve space for: ellipsis + newline (if we have content) + resume lines
    ellipsis_with_sep = @ellipsis <> if(resume_lines != [], do: "\n", else: "")
    ellipsis_len = String.length(ellipsis_with_sep)

    # Space available for content
    available_for_content = @telegram_max_length - resume_length - ellipsis_len

    # If resume lines alone exceed the limit, truncate them too
    if available_for_content < 0 do
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
    {resume_rev, content_rev} = split_resume_lines(Enum.reverse(lines), engine_module, [])
    {Enum.reverse(content_rev), resume_rev}
  end

  defp split_resume_lines([], _engine_module, resume_acc), do: {resume_acc, []}

  defp split_resume_lines([line | rest], engine_module, resume_acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" && resume_acc != [] ->
        split_resume_lines(rest, engine_module, [line | resume_acc])

      is_resume_line?(line, engine_module) ->
        split_resume_lines(rest, engine_module, [line | resume_acc])

      true ->
        {resume_acc, [line | rest]}
    end
  end

  defp is_resume_line?(line, nil) do
    # Use the generic detector from AgentCore when no engine specified
    AgentCore.CliRunners.Types.ResumeToken.is_resume_line(line) ||
      fallback_resume_prefix?(line)
  end

  defp is_resume_line?(line, engine_module) when is_atom(engine_module) do
    engine_module.is_resume_line(line) ||
      AgentCore.CliRunners.Types.ResumeToken.is_resume_line(line) ||
      fallback_resume_prefix?(line)
  end

  defp fallback_resume_prefix?(line) when is_binary(line) do
    line = String.trim(String.downcase(line))

    String.starts_with?(line, "codex resume ") ||
      String.starts_with?(line, "lemon resume ") ||
      String.starts_with?(line, "claude --resume ") ||
      Regex.match?(~r/^[a-z0-9_-]+\s+resume\s+/i, line)
  end

  defp extract_trailing_resume_line(text) when is_binary(text) do
    regex =
      ~r/(?:^|\n)(`?(?:codex|lemon)\s+resume\s+[a-zA-Z0-9_-]+`?|`?claude\s+--resume\s+[a-zA-Z0-9_-]+`?)\s*$/i

    case Regex.run(regex, text) do
      [_, line] -> line
      _ -> nil
    end
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
