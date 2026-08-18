defmodule CodingAgent.PythonRepl.Protocol do
  @moduledoc """
  Incremental parser and validator for the Python REPL runner control protocol.

  The runner emits frames on a private control descriptor (a non-inheritable
  duplicate of its original stdout). A frame is a record separator byte
  (0x1E), the literal `lemon-python`, a tab, a single-line JSON object, and a
  newline. `feed/2` accepts arbitrary byte chunks — frames may be split or
  coalesced — and returns every complete frame decoded in arrival order as
  atom-key maps:

      %{type: :ready, pid: pos_integer() | nil}
      %{type: :started, id: String.t()}
      %{type: :stream, id: String.t(), stream: :stdout | :stderr, data: binary()}
      %{type: :exception, id: String.t(), kind: exception_kind(), name: String.t(),
        message: String.t() | nil, traceback: String.t() | nil}
      %{type: :done, id: String.t()}
      %{type: :fatal, reason: String.t() | nil}
      %{type: :bye}

  On the wire, every `exception` frame carries its exception class in the
  required string field `name`.

  Cell correlation: `started` opens a cell and every `stream`, `exception`,
  and `done` frame must carry that cell's id. `exception` is informational
  (a cell may contain several); `done` is the sole cell closer and appears
  exactly once per `started`. `ready` is emitted once, in response to
  `init`. `bye` and `fatal` are process terminals and may each appear at
  most once; nothing may follow them.

  Validation fails closed: wrong prefix, wrong version, unknown types,
  missing or invalid fields, non-base64 stream data, oversized frames,
  stream chunks above the chunk cap, frames for the wrong id, duplicate or
  cell-less terminals, and any frame after a process terminal all return
  `{:error, reason}`. Unprefixed bytes are never treated as user output.
  After any error the caller must destroy the interpreter; the protocol
  instance must be discarded, never resumed.
  """

  @version 1

  @frame_prefix "\x1Elemon-python\t"
  @frame_max_bytes 256 * 1024
  @stream_chunk_max_bytes 64 * 1024

  @frame_types ~w(ready started stream exception done fatal bye)
  @streams ~w(stdout stderr)
  @exception_kinds ~w(error system_exit unsupported_input interrupted)

  defstruct buffer: "",
            cell_id: nil,
            ready_seen: false,
            process_closed: false

  @type exception_kind :: :error | :system_exit | :unsupported_input | :interrupted

  @type frame ::
          %{type: :ready, pid: pos_integer() | nil}
          | %{type: :started, id: String.t()}
          | %{
              type: :stream,
              id: String.t(),
              stream: :stdout | :stderr,
              data: binary()
            }
          | %{
              type: :exception,
              id: String.t(),
              kind: exception_kind(),
              name: String.t(),
              message: String.t() | nil,
              traceback: String.t() | nil
            }
          | %{type: :done, id: String.t()}
          | %{type: :fatal, reason: String.t() | nil}
          | %{type: :bye}

  @type error ::
          {:bad_prefix, binary()}
          | {:frame_too_large, non_neg_integer()}
          | {:invalid_json, term()}
          | {:invalid_version, term()}
          | {:unknown_type, term()}
          | {:missing_field, String.t()}
          | {:invalid_field, term()}
          | {:invalid_stream, term()}
          | {:invalid_base64, binary()}
          | {:stream_too_large, pos_integer()}
          | {:wrong_id, String.t(), String.t()}
          | :no_active_cell
          | {:cell_already_active, String.t()}
          | {:unexpected_frame, atom()}

  @type t :: %__MODULE__{
          buffer: binary(),
          cell_id: String.t() | nil,
          ready_seen: boolean(),
          process_closed: boolean()
        }

  @doc """
  The protocol version this parser implements (`#{@version}`).
  """
  @spec version() :: pos_integer()
  def version, do: @version

  @doc """
  Maximum accepted frame size in bytes, measured from the record separator
  up to (but not including) the trailing newline.
  """
  @spec frame_max_bytes() :: pos_integer()
  def frame_max_bytes, do: @frame_max_bytes

  @doc """
  Maximum decoded stream payload a single `stream` frame may carry.
  """
  @spec stream_chunk_max_bytes() :: pos_integer()
  def stream_chunk_max_bytes, do: @stream_chunk_max_bytes

  @doc """
  Creates a fresh protocol parser.
  """
  @spec new() :: {:ok, t(), [frame()]}
  def new, do: {:ok, %__MODULE__{}, []}

  @doc """
  Feeds raw control-descriptor bytes into the parser and returns every frame
  completed by this chunk, in arrival order.

  Frames may be split across any number of `feed/2` calls and several frames
  may arrive coalesced in one chunk. The first validation failure returns
  `{:error, reason}` immediately; no partial frames from that chunk are
  returned and the parser must be discarded.
  """
  @spec feed(t(), binary()) :: {:ok, t(), [frame()]} | {:error, error()}
  def feed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    buffer = state.buffer <> bytes

    with :ok <- check_prefix(buffer) do
      consume(state, buffer, [])
    end
  end

  defp check_prefix(<<>>), do: :ok

  defp check_prefix(buffer) do
    if String.starts_with?(buffer, @frame_prefix) or String.starts_with?(@frame_prefix, buffer) do
      :ok
    else
      {:error, {:bad_prefix, binary_sample(buffer)}}
    end
  end

  defp consume(state, buffer, frames) do
    case :binary.split(buffer, "\n") do
      [line, rest] ->
        case decode_line(state, line) do
          {:ok, state, frame} ->
            consume(state, rest, [frame | frames])

          {:error, _reason} = error ->
            error
        end

      [fragment] ->
        size = byte_size(fragment)

        if size > @frame_max_bytes do
          {:error, {:frame_too_large, size}}
        else
          {:ok, %{state | buffer: fragment}, Enum.reverse(frames)}
        end
    end
  end

  defp decode_line(state, line) do
    size = byte_size(line)

    cond do
      size > @frame_max_bytes ->
        {:error, {:frame_too_large, size}}

      not String.starts_with?(line, @frame_prefix) ->
        {:error, {:bad_prefix, binary_sample(line)}}

      true ->
        json = binary_part(line, byte_size(@frame_prefix), size - byte_size(@frame_prefix))

        with {:ok, doc} <- decode_json(json),
             :ok <- check_version(doc),
             {:ok, type} <- check_type(doc) do
          decode_frame(state, type, doc)
        end
    end
  end

  defp decode_json(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} -> {:ok, doc}
      {:ok, _other} -> {:error, {:invalid_json, :not_an_object}}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp check_version(doc) do
    case Map.fetch(doc, "v") do
      {:ok, @version} -> :ok
      {:ok, other} -> {:error, {:invalid_version, other}}
      :error -> {:error, {:missing_field, "v"}}
    end
  end

  defp check_type(doc) do
    case Map.fetch(doc, "type") do
      {:ok, type} when type in @frame_types -> {:ok, type}
      {:ok, other} -> {:error, {:unknown_type, other}}
      :error -> {:error, {:missing_field, "type"}}
    end
  end

  # Every frame is rejected once a process terminal (bye/fatal) was seen,
  # which also covers duplicate bye/fatal frames.
  defp decode_frame(%__MODULE__{process_closed: true} = _state, type, _doc),
    do: {:error, {:unexpected_frame, String.to_atom(type)}}

  defp decode_frame(state, "ready", doc) do
    if state.ready_seen do
      {:error, {:unexpected_frame, :ready}}
    else
      with {:ok, pid} <- optional_pid(doc) do
        {:ok, %{state | ready_seen: true}, %{type: :ready, pid: pid}}
      end
    end
  end

  defp decode_frame(state, "started", doc) do
    if state.cell_id do
      {:error, {:cell_already_active, state.cell_id}}
    else
      with {:ok, id} <- required_string(doc, "id") do
        {:ok, %{state | cell_id: id}, %{type: :started, id: id}}
      end
    end
  end

  defp decode_frame(state, "stream", doc) do
    with {:ok, id} <- cell_id(state, doc),
         {:ok, stream} <- required_stream(doc),
         {:ok, data} <- stream_data(doc) do
      {:ok, state, %{type: :stream, id: id, stream: stream, data: data}}
    end
  end

  defp decode_frame(state, "exception", doc) do
    with {:ok, id} <- cell_id(state, doc),
         {:ok, kind} <- exception_kind(doc),
         {:ok, name} <- required_string(doc, "name"),
         {:ok, message} <- optional_string(doc, "message"),
         {:ok, traceback} <- optional_string(doc, "traceback") do
      frame = %{
        type: :exception,
        id: id,
        kind: kind,
        name: name,
        message: message,
        traceback: traceback
      }

      {:ok, state, frame}
    end
  end

  defp decode_frame(state, "done", doc) do
    with {:ok, id} <- cell_id(state, doc) do
      {:ok, %{state | cell_id: nil}, %{type: :done, id: id}}
    end
  end

  defp decode_frame(state, "fatal", doc) do
    with {:ok, reason} <- optional_string(doc, "reason") do
      {:ok, %{state | process_closed: true}, %{type: :fatal, reason: reason}}
    end
  end

  defp decode_frame(state, "bye", _doc),
    do: {:ok, %{state | process_closed: true}, %{type: :bye}}

  defp decode_frame(_state, type, _doc), do: {:error, {:unknown_type, type}}

  # All id-bearing frames must reference the currently open cell. `started`
  # is handled above; stream/exception/done require an open cell whose id
  # matches, which is what makes wrong-id and cell-less terminal frames
  # protocol faults.
  defp cell_id(%__MODULE__{cell_id: nil}, _doc), do: {:error, :no_active_cell}

  defp cell_id(%__MODULE__{cell_id: active}, doc) do
    with {:ok, id} <- required_string(doc, "id") do
      if id == active, do: {:ok, id}, else: {:error, {:wrong_id, active, id}}
    end
  end

  defp required_string(doc, field) do
    case Map.fetch(doc, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, nil} -> {:error, {:missing_field, field}}
      {:ok, value} -> {:error, {:invalid_field, {field, value}}}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_string(doc, field) do
    case Map.fetch(doc, field) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_field, {field, value}}}
      :error -> {:ok, nil}
    end
  end

  defp optional_pid(doc) do
    case Map.fetch(doc, "pid") do
      {:ok, nil} -> {:ok, nil}
      {:ok, pid} when is_integer(pid) and pid > 0 -> {:ok, pid}
      {:ok, pid} -> {:error, {:invalid_field, {"pid", pid}}}
      :error -> {:ok, nil}
    end
  end

  defp required_stream(doc) do
    case Map.fetch(doc, "stream") do
      {:ok, stream} when stream in @streams -> {:ok, String.to_atom(stream)}
      {:ok, stream} -> {:error, {:invalid_stream, stream}}
      :error -> {:error, {:missing_field, "stream"}}
    end
  end

  defp exception_kind(doc) do
    case Map.fetch(doc, "kind") do
      {:ok, kind} when kind in @exception_kinds -> {:ok, String.to_atom(kind)}
      {:ok, kind} -> {:error, {:invalid_field, {"kind", kind}}}
      :error -> {:error, {:missing_field, "kind"}}
    end
  end

  defp stream_data(doc) do
    with {:ok, data} <- required_string(doc, "data") do
      case Base.decode64(data) do
        {:ok, bytes} ->
          size = byte_size(bytes)

          if size > @stream_chunk_max_bytes do
            {:error, {:stream_too_large, size}}
          else
            {:ok, bytes}
          end

        :error ->
          {:error, {:invalid_base64, data}}
      end
    end
  end

  defp binary_sample(binary, size \\ 32)

  defp binary_sample(binary, size) when byte_size(binary) <= size, do: binary

  defp binary_sample(binary, size),
    do: binary_part(binary, 0, size) <> "..."
end
