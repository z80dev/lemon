defmodule Ai.Text do
  @moduledoc """
  Generic text truncation primitives.

  The helpers here preserve UTF-8 validity for byte-based head and middle
  truncation. Callers still own domain-specific markers, notices, metadata, and
  thresholds.
  """

  @default_marker "..."
  @default_tail_max_bytes 50_000
  @default_tail_max_lines 2000
  @default_middle_marker_reserve 256
  @default_middle_head_percent 70

  @doc """
  Truncates text by Unicode characters and appends a marker.

  Options:

    * `:marker` - marker appended after the kept prefix, default `"..."`.
    * `:force` - append the marker even when the text is not longer than `max`.
  """
  @spec truncate_chars(String.t(), non_neg_integer(), keyword()) :: String.t()
  def truncate_chars(text, max, opts \\ []) when is_binary(text) and is_integer(max) do
    marker = Keyword.get(opts, :marker, @default_marker)
    force? = Keyword.get(opts, :force, false)

    if force? or String.length(text) > max do
      String.slice(text, 0, max) <> marker
    else
      text
    end
  end

  @doc """
  Truncates text to a UTF-8-safe byte prefix and appends a marker.

  The marker may be a binary or a function receiving the removed byte count.
  Pass `marker: ""` for markerless truncation. This keeps the byte-size check in
  bytes, unlike `truncate_chars/3`.
  """
  @spec truncate_bytes_utf8(String.t(), non_neg_integer(), keyword()) :: String.t()
  def truncate_bytes_utf8(text, max_bytes, opts \\ [])
      when is_binary(text) and is_integer(max_bytes) do
    if byte_size(text) <= max_bytes do
      text
    else
      prefix =
        text
        |> binary_part(0, max(max_bytes, 0))
        |> trim_to_valid_utf8()

      prefix <>
        marker_text(
          Keyword.get(opts, :marker, @default_marker),
          byte_size(text) - byte_size(prefix)
        )
    end
  end

  @doc """
  Keeps a UTF-8-safe head and tail within `max_bytes`, inserting a marker.

  Options:

    * `:marker` - marker binary or function receiving removed byte count.
    * `:marker_reserve` - byte budget reserved before splitting head/tail.
    * `:head_percent` - percentage of the remaining budget used for the head.
  """
  @spec truncate_middle_utf8(String.t(), integer(), keyword()) :: String.t()
  def truncate_middle_utf8(text, max_bytes, opts \\ [])

  def truncate_middle_utf8(text, max_bytes, _opts)
      when is_binary(text) and is_integer(max_bytes) and byte_size(text) <= max_bytes,
      do: text

  def truncate_middle_utf8(_text, max_bytes, _opts) when is_integer(max_bytes) and max_bytes <= 0,
    do: ""

  def truncate_middle_utf8(text, max_bytes, opts)
      when is_binary(text) and is_integer(max_bytes) do
    marker_reserve = Keyword.get(opts, :marker_reserve, @default_middle_marker_reserve)
    head_percent = Keyword.get(opts, :head_percent, @default_middle_head_percent)
    budget = max(max_bytes - marker_reserve, 0)

    head_bytes = div(budget * head_percent, 100)
    tail_bytes = budget - head_bytes

    head = trim_to_valid_utf8(binary_part(text, 0, head_bytes))
    tail = trim_to_valid_utf8(binary_part(text, byte_size(text) - tail_bytes, tail_bytes))
    removed = byte_size(text) - byte_size(head) - byte_size(tail)
    marker = marker_text(Keyword.get(opts, :marker, @default_marker), removed)

    out = head <> marker <> tail

    if byte_size(out) <= max_bytes do
      out
    else
      out
      |> binary_part(0, max_bytes)
      |> trim_to_valid_utf8()
    end
  end

  @doc """
  Truncates content to the last lines and bytes, returning metadata.

  Options:

    * `:max_bytes` - maximum bytes to keep before adding the notice.
    * `:max_lines` - maximum lines to keep.
    * `:notice` - function receiving `{total_lines, total_bytes}`.
  """
  @spec truncate_tail(String.t(), keyword()) :: {String.t(), boolean(), map()}
  def truncate_tail(content, opts \\ []) when is_binary(content) do
    max_bytes = Keyword.get(opts, :max_bytes, @default_tail_max_bytes)
    max_lines = Keyword.get(opts, :max_lines, @default_tail_max_lines)

    total_bytes = byte_size(content)
    lines = String.split(content, "\n")
    total_lines = length(lines)

    needs_line_truncation = total_lines > max_lines
    needs_byte_truncation = total_bytes > max_bytes

    if not needs_line_truncation and not needs_byte_truncation do
      info = %{
        total_lines: total_lines,
        total_bytes: total_bytes,
        output_lines: total_lines,
        output_bytes: total_bytes
      }

      {content, false, info}
    else
      truncated_lines =
        if needs_line_truncation do
          Enum.take(lines, -max_lines)
        else
          lines
        end

      truncated_content = Enum.join(truncated_lines, "\n")

      truncated_content =
        if byte_size(truncated_content) > max_bytes do
          binary_part(truncated_content, byte_size(truncated_content) - max_bytes, max_bytes)
        else
          truncated_content
        end

      output_lines = length(String.split(truncated_content, "\n"))
      output_bytes = byte_size(truncated_content)

      info = %{
        total_lines: total_lines,
        total_bytes: total_bytes,
        output_lines: output_lines,
        output_bytes: output_bytes
      }

      notice =
        marker_text(
          Keyword.get(opts, :notice, fn lines, bytes ->
            "[Output truncated. Total: #{lines} lines, #{bytes} bytes]\n\n"
          end),
          total_lines,
          total_bytes
        )

      {notice <> truncated_content, true, info}
    end
  end

  @doc false
  @spec trim_to_valid_utf8(binary()) :: String.t()
  def trim_to_valid_utf8(<<>>), do: ""

  def trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end

  defp marker_text(marker, removed) when is_function(marker, 1), do: marker.(removed)
  defp marker_text(marker, _removed) when is_binary(marker), do: marker

  defp marker_text(marker, total_lines, total_bytes) when is_function(marker, 2),
    do: marker.(total_lines, total_bytes)

  defp marker_text(marker, _total_lines, _total_bytes) when is_binary(marker), do: marker
end
