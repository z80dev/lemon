defmodule CodingAgent.Tools.ReadText do
  @moduledoc false

  # Scan fixed-size chunks, retaining only the requested window. Even a single
  # multi-megabyte line never needs to be materialized to display its preview.
  @chunk_bytes 64 * 1024

  def read(path, offset, limit, max_lines, max_bytes, signal, retain_snapshot? \\ false) do
    state = new_state(offset, limit, max_lines, max_bytes)
    state = if retain_snapshot?, do: %{state | snapshot_chunks: []}, else: state

    case File.open(path, [:read, :binary], fn file -> scan(file, state, signal) end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, "Failed to read file: #{path} (#{reason})"}
    end
  end

  def from_content(content, max_lines, max_bytes) do
    cond do
      :binary.match(content, <<0>>) != :nomatch ->
        {:error, "File is binary; use bash for binary inspection or conversion."}

      not String.valid?(content) ->
        {:error, "File contains invalid UTF-8; use bash for binary inspection or conversion."}

      true ->
        state = consume(content, new_state(0, nil, max_lines, max_bytes)) |> finish_eof()

        {:ok,
         %{lines: Enum.reverse(state.lines), total_lines: state.line, truncation: state.truncated}}
    end
  end

  defp finish_eof(%{line: line, current_bytes: 0} = state) when line > 0, do: state
  defp finish_eof(state), do: finish_line(state)

  defp new_state(offset, limit, max_lines, max_bytes) do
    %{
      line: 0,
      start: offset,
      limit: limit,
      max_lines: max_lines,
      max_bytes: max_bytes,
      lines: [],
      shown: 0,
      bytes: 0,
      current: [],
      current_bytes: 0,
      current_saved: 0,
      truncated: nil,
      utf8_tail: "",
      snapshot_chunks: nil,
      snapshot_bytes: 0,
      digest: :crypto.hash_init(:md5)
    }
  end

  defp scan(file, state, signal) do
    with :ok <- LemonAgent.Tools.AbortHelpers.check_abort(signal) do
      case IO.binread(file, @chunk_bytes) do
        :eof ->
          if state.utf8_tail == "" do
            state = finish_eof(state)

            {:ok,
             %{
               lines: Enum.reverse(state.lines),
               total_lines: state.line,
               truncation: state.truncated,
               digest: :crypto.hash_final(state.digest),
               snapshot_content:
                 if(state.snapshot_chunks,
                   do: state.snapshot_chunks |> Enum.reverse() |> IO.iodata_to_binary(),
                   else: nil
                 )
             }}
          else
            {:error, "File contains invalid UTF-8; use bash for binary inspection or conversion."}
          end

        {:error, reason} ->
          {:error, "Failed to read file (#{reason})"}

        chunk ->
          with {:ok, tail} <- validate_text(state.utf8_tail <> chunk) do
            state = %{state | utf8_tail: tail, digest: :crypto.hash_update(state.digest, chunk)}
            state = retain_snapshot(state, chunk)
            scan(file, consume(chunk, state), signal)
          end
      end
    end
  end

  defp retain_snapshot(state, chunk) do
    bytes = state.snapshot_bytes + byte_size(chunk)

    chunks =
      if state.snapshot_chunks && bytes <= CodingAgent.FileReadTracker.snapshot_byte_limit(),
        do: [chunk | state.snapshot_chunks],
        else: nil

    %{state | snapshot_bytes: bytes, snapshot_chunks: chunks}
  end

  defp validate_text(bytes) do
    if :binary.match(bytes, <<0>>) != :nomatch do
      {:error,
       "File is binary (contains NUL bytes); use bash for binary inspection or conversion."}
    else
      case :unicode.characters_to_binary(bytes, :utf8, :utf8) do
        text when is_binary(text) ->
          {:ok, ""}

        {:incomplete, _valid, tail} ->
          {:ok, tail}

        {:error, _valid, _rest} ->
          {:error, "File contains invalid UTF-8; use bash for binary inspection or conversion."}
      end
    end
  end

  defp consume(chunk, state) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        append(chunk, state)

      {index, 1} ->
        <<part::binary-size(^index), _newline, rest::binary>> = chunk
        state = part |> append(state) |> finish_line()
        consume(rest, state)
    end
  end

  defp selected?(state) do
    state.line >= state.start and
      (is_nil(state.limit) or state.line < state.start + state.limit)
  end

  defp append(part, state) do
    remaining =
      max(
        state.max_bytes - byte_size(Integer.to_string(state.line + 1)) - 3 - state.current_saved,
        0
      )

    keep =
      if selected?(state) and is_nil(state.truncated),
        do: min(byte_size(part), remaining),
        else: 0

    current = if keep > 0, do: [binary_part(part, 0, keep) | state.current], else: state.current

    %{
      state
      | current: current,
        current_saved: state.current_saved + keep,
        current_bytes: state.current_bytes + byte_size(part)
    }
  end

  defp finish_line(state) do
    state =
      if selected?(state) and is_nil(state.truncated) do
        text =
          state.current |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim_trailing("\r")

        numbered_bytes = state.current_bytes + byte_size(Integer.to_string(state.line + 1)) + 3

        cond do
          state.shown >= state.max_lines ->
            %{state | truncated: "max_lines"}

          state.lines == [] and
              state.current_bytes + byte_size(Integer.to_string(state.line + 1)) + 3 >
                state.max_bytes ->
            # Never emit an incomplete UTF-8 codepoint at the preview boundary.
            preview = valid_prefix(text)
            %{state | lines: [preview], shown: 1, truncated: "long_line"}

          state.bytes + numbered_bytes > state.max_bytes ->
            %{state | truncated: "max_bytes"}

          true ->
            %{
              state
              | lines: [text | state.lines],
                shown: state.shown + 1,
                bytes: state.bytes + numbered_bytes
            }
        end
      else
        state
      end

    %{state | line: state.line + 1, current: [], current_bytes: 0, current_saved: 0}
  end

  defp valid_prefix(text) do
    case :unicode.characters_to_binary(text, :utf8, :utf8) do
      text when is_binary(text) -> text
      {:incomplete, valid, _tail} -> IO.iodata_to_binary(valid)
      {:error, valid, _rest} -> IO.iodata_to_binary(valid)
    end
  end
end
