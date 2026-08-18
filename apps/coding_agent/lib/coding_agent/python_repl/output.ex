defmodule CodingAgent.PythonRepl.Output do
  @moduledoc """
  Cell output capture for persistent Python sessions.

  `append/3` records decoded stream chunks in arrival order — stdout and
  stderr share one combined stream, exactly like `BashExecutor`'s merged
  capture. Sanitization is continuous within each logical stream: a bounded
  raw tail is carried only while a UTF-8 codepoint or ANSI escape may
  continue in a later chunk, so frame boundaries do not change the result.
  Bounded retention is deterministic: while the combined sanitized output
  fits `max_bytes` it is kept verbatim. Once it exceeds that budget the
  capture keeps the first 40% of `max_bytes` (head) plus a rolling last 60%
  (tail), and the full output is spilled to a `0600` temporary file created
  only at that moment. `finish/1` returns the retained output with a
  truncation marker between head and tail, the byte totals, and the spill
  path (present only when truncation happened).
  """

  alias CodingAgent.BashExecutor
  alias LemonAi.Text

  defmodule Result do
    @moduledoc """
    Final capture state for one cell.
    """

    defstruct output: "",
              truncated: false,
              total_bytes: 0,
              stdout_bytes: 0,
              stderr_bytes: 0,
              dropped_bytes: 0,
              full_output_path: nil

    @type t :: %__MODULE__{
            output: String.t(),
            truncated: boolean(),
            total_bytes: non_neg_integer(),
            stdout_bytes: non_neg_integer(),
            stderr_bytes: non_neg_integer(),
            dropped_bytes: non_neg_integer(),
            full_output_path: String.t() | nil
          }
  end

  @head_percent 40
  @max_pending_bytes 64
  @ansi_pending_regex ~r/\e(?:\[[0-9;]*)?\z/

  defstruct [
    :max_bytes,
    :spill,
    :spill_path,
    :spill_error,
    pending: "",
    pending_stream: nil,
    head: "",
    tail: "",
    total_bytes: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    truncated: false
  ]

  @type t :: %__MODULE__{
          max_bytes: pos_integer(),
          pending: binary(),
          pending_stream: :stdout | :stderr | nil,
          head: binary(),
          tail: binary(),
          total_bytes: non_neg_integer(),
          stdout_bytes: non_neg_integer(),
          stderr_bytes: non_neg_integer(),
          truncated: boolean(),
          spill: IO.device() | nil,
          spill_path: String.t() | nil,
          spill_error: term() | nil
        }

  @doc """
  Creates an empty capture bounded by `max_bytes` (positive integer).
  """
  @spec new(pos_integer()) :: t()
  def new(max_bytes) when is_integer(max_bytes) and max_bytes > 0 do
    %__MODULE__{max_bytes: max_bytes}
  end

  def new(max_bytes) do
    raise ArgumentError, "max_bytes must be a positive integer, got: #{inspect(max_bytes)}"
  end

  @doc """
  Appends one decoded stream chunk in arrival order.

  `stream` is `:stdout` or `:stderr`; `bytes` is the raw decoded frame
  payload. Sanitization is continuous across chunks from the same stream,
  and totals count bytes only after sanitization.
  """
  @spec append(t(), :stdout | :stderr, binary()) :: t()
  def append(%__MODULE__{} = output, stream, bytes)
      when stream in [:stdout, :stderr] and is_binary(bytes) do
    if bytes == "" do
      output
    else
      output
      |> prepare_stream(stream)
      |> append_chunk(stream, bytes)
    end
  end

  def append(%__MODULE__{}, stream, bytes) when stream in [:stdout, :stderr] do
    raise ArgumentError, "bytes must be a binary, got: #{inspect(bytes)}"
  end

  def append(%__MODULE__{}, stream, _bytes) do
    raise ArgumentError, "stream must be :stdout or :stderr, got: #{inspect(stream)}"
  end

  defp prepare_stream(%{pending: ""} = output, _stream), do: output
  defp prepare_stream(%{pending_stream: stream} = output, stream), do: output
  defp prepare_stream(output, _stream), do: flush_pending(output)

  defp append_chunk(output, stream, bytes) do
    {ready, pending} = split_pending(output.pending <> bytes)

    output = %{
      output
      | pending: pending,
        pending_stream: if(pending == "", do: nil, else: stream)
    }

    emit(output, stream, BashExecutor.sanitize_output(ready))
  end

  defp flush_pending(%{pending: ""} = output), do: output

  defp flush_pending(%{pending: pending, pending_stream: stream} = output)
       when stream in [:stdout, :stderr] do
    output = %{output | pending: "", pending_stream: nil}
    emit(output, stream, BashExecutor.sanitize_output(pending))
  end

  @doc """
  Finishes the capture.

  Returns a `Result` with the retained output (a truncation marker is
  inserted between head and tail when bytes were dropped), the combined and
  per-stream sanitized totals, the number of dropped bytes, and — only when
  the capture was truncated — the path of the `0600` spill file holding the
  full combined output.
  """
  @spec finish(t()) :: Result.t()
  def finish(%__MODULE__{} = output) do
    output = flush_pending(output)
    if output.spill, do: File.close(output.spill)

    if output.truncated do
      retained = byte_size(output.head) + byte_size(output.tail)
      dropped = max(output.total_bytes - retained, 0)

      %Result{
        output: output.head <> marker(dropped) <> output.tail,
        truncated: true,
        total_bytes: output.total_bytes,
        stdout_bytes: output.stdout_bytes,
        stderr_bytes: output.stderr_bytes,
        dropped_bytes: dropped,
        full_output_path: output.spill_path
      }
    else
      %Result{
        output: output.head,
        truncated: false,
        total_bytes: output.total_bytes,
        stdout_bytes: output.stdout_bytes,
        stderr_bytes: output.stderr_bytes,
        dropped_bytes: 0,
        full_output_path: nil
      }
    end
  end

  defp track(output, stream, size) do
    output = %{output | total_bytes: output.total_bytes + size}

    case stream do
      :stdout -> %{output | stdout_bytes: output.stdout_bytes + size}
      :stderr -> %{output | stderr_bytes: output.stderr_bytes + size}
    end
  end

  defp emit(output, _stream, ""), do: output

  defp emit(output, stream, sanitized) do
    output
    |> track(stream, byte_size(sanitized))
    |> retain(sanitized)
  end

  defp split_pending(bytes) do
    size = byte_size(bytes)
    pending_start = min(ansi_pending_start(bytes, size), incomplete_utf8_start(bytes))

    {
      binary_part(bytes, 0, pending_start),
      binary_part(bytes, pending_start, size - pending_start)
    }
  end

  defp ansi_pending_start(bytes, size) do
    case Regex.run(@ansi_pending_regex, bytes, return: :index) do
      [{start, length}] when length <= @max_pending_bytes -> start
      _ -> size
    end
  end

  defp incomplete_utf8_start(""), do: 0

  defp incomplete_utf8_start(bytes) do
    size = byte_size(bytes)
    continuation_count = trailing_continuation_count(bytes, size - 1, 0)
    lead_index = size - continuation_count - 1

    if lead_index >= 0 do
      lead = :binary.at(bytes, lead_index)
      width = utf8_width(lead)
      seen = continuation_count + 1

      if width != nil and seen < width and valid_partial_utf8?(bytes, lead_index, seen) do
        lead_index
      else
        size
      end
    else
      size
    end
  end

  defp trailing_continuation_count(bytes, index, count) when index >= 0 and count < 3 do
    if :binary.at(bytes, index) in 0x80..0xBF do
      trailing_continuation_count(bytes, index - 1, count + 1)
    else
      count
    end
  end

  defp trailing_continuation_count(_bytes, _index, count), do: count

  defp utf8_width(byte) when byte in 0xC2..0xDF, do: 2
  defp utf8_width(byte) when byte in 0xE0..0xEF, do: 3
  defp utf8_width(byte) when byte in 0xF0..0xF4, do: 4
  defp utf8_width(_byte), do: nil

  defp valid_partial_utf8?(_bytes, _lead_index, 1), do: true

  defp valid_partial_utf8?(bytes, lead_index, _seen) do
    lead = :binary.at(bytes, lead_index)
    first_continuation = :binary.at(bytes, lead_index + 1)

    cond do
      lead == 0xE0 -> first_continuation >= 0xA0
      lead == 0xED -> first_continuation <= 0x9F
      lead == 0xF0 -> first_continuation >= 0x90
      lead == 0xF4 -> first_continuation <= 0x8F
      true -> true
    end
  end

  defp tail_cap(max_bytes), do: max_bytes - div(max_bytes * @head_percent, 100)

  # Retention phase 1: everything is kept verbatim while it fits the budget.
  defp retain(%{truncated: false} = output, chunk) do
    combined = output.head <> chunk

    if byte_size(combined) <= output.max_bytes do
      %{output | head: combined}
    else
      head_cap = div(output.max_bytes * @head_percent, 100)

      head = Text.trim_to_valid_utf8(binary_part(combined, 0, head_cap))

      rest = binary_part(combined, byte_size(head), byte_size(combined) - byte_size(head))

      tail =
        rest
        |> keep_last(tail_cap(output.max_bytes))
        |> drop_leading_partial()

      output
      |> open_spill(combined)
      |> Map.put(:head, head)
      |> Map.put(:tail, tail)
      |> Map.put(:truncated, true)
    end
  end

  # Retention phase 2: the head is frozen; only the rolling tail window and
  # the spill file keep growing.
  defp retain(%{truncated: true} = output, chunk) do
    tail =
      (output.tail <> chunk)
      |> keep_last(tail_cap(output.max_bytes))
      |> drop_leading_partial()

    output = write_spill(output, chunk)
    %{output | tail: tail}
  end

  defp keep_last(binary, cap) when byte_size(binary) <= cap, do: binary

  defp keep_last(binary, cap) when byte_size(binary) > cap,
    do: binary_part(binary, byte_size(binary) - cap, cap)

  # A byte-window cut can split a multi-byte sequence at the start of the
  # tail; drop up to three leading continuation bytes so retained text is
  # always valid UTF-8.
  defp drop_leading_partial(binary, attempts \\ 3)

  defp drop_leading_partial(binary, 0), do: binary

  defp drop_leading_partial(binary, attempts) do
    if String.valid?(binary) do
      binary
    else
      drop_leading_partial(binary_part(binary, 1, byte_size(binary) - 1), attempts - 1)
    end
  end

  defp open_spill(output, combined) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "pi-python-repl-#{random}.log")

    case File.open(path, [:write, :binary]) do
      {:ok, io} ->
        with :ok <- File.chmod(path, 0o600),
             :ok <- IO.binwrite(io, combined) do
          %{output | spill: io, spill_path: path, spill_error: nil}
        else
          {:error, reason} ->
            spill_failed(output, io, path, reason)
        end

      {:error, reason} ->
        %{output | spill: nil, spill_path: nil, spill_error: reason}
    end
  end

  defp spill_failed(output, io, path, reason) do
    File.close(io)
    File.rm(path)
    %{output | spill: nil, spill_path: nil, spill_error: reason}
  end

  defp write_spill(%{spill: nil} = output, _chunk), do: output

  defp write_spill(%{spill: io, spill_path: path} = output, chunk) do
    case IO.binwrite(io, chunk) do
      :ok ->
        output

      {:error, reason} ->
        # The spill file can no longer claim to hold the full output; stop
        # writing and drop the path rather than returning a partial file.
        spill_failed(output, io, path, reason)
    end
  end

  defp marker(dropped) do
    "\n... [#{dropped} bytes truncated] ...\n"
  end
end
