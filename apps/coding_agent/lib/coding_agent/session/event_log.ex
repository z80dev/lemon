defmodule CodingAgent.Session.EventLog do
  @moduledoc """
  Session-owned, volatile cursor replay. Each broadcast gets one gap-free sequence
  in a native session process. Branch changes expire the stream without reusing
  a sequence. A cursor is version 1 plus the native
  session ID, an opaque stream ID and sequence; `streamId:seq` is the stable event
  ID. It is not a global order or the run-local text delta sequence.

  The protected ETS ordered_set dies with its session. Count and encoded-term byte
  budgets are caller policy (defaults match subscriber admission: 1,000 events and
  1 MiB). Oversized events are delivered live but evict themselves and all older
  events, so replay truthfully expires rather than skipping a sequence. Reads and
  writes must run in the session owner, including cursor validation and paging.
  """

  alias CodingAgent.Session.RunTranslator
  alias LemonCore.Event

  defmodule Emitter do
    @moduledoc false
    @behaviour CodingAgent.Session.RunTranslator.Emitter

    def emit_started(state, fields), do: record(state, :run_started, fields)

    def emit_action_event(state, fields) do
      record(state, :engine_action, %{
        action: Map.take(fields, [:id, :kind, :title, :detail]),
        phase: fields.phase,
        ok: fields.ok,
        message: fields.message
      })
    end

    def emit_delta(state, _text, fields), do: record(state, :delta, fields)
    def emit_completed(state, fields), do: record(state, :run_completed, %{completed: fields})

    defp record(state, type, payload), do: [Event.new(type, payload) | state]
  end

  def new(session_id, session_key, run_id, cwd, opts \\ []) do
    max_count = Keyword.get(opts, :event_log_max_count, 1_000)
    max_bytes = Keyword.get(opts, :event_log_max_bytes, 1_048_576)

    unless is_integer(max_count) and max_count > 0 and is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError, "event log limits must be positive integers"
    end

    table = :ets.new(__MODULE__, [:ordered_set, :protected])
    stream_id = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

    translator =
      RunTranslator.new(
        emitter: Emitter,
        emitter_state: [],
        engine: "lemon",
        label: "lemon",
        session_id: session_id,
        run_id: run_id,
        cwd: cwd
      )

    :ets.insert(
      table,
      {:state,
       %{
         session_id: session_id,
         stream_id: stream_id,
         session_key: session_key,
         run_id: run_id,
         seq: 0,
         count: 0,
         bytes: 0,
         max_count: max_count,
         max_bytes: max_bytes,
         translator: translator
       }}
    )

    table
  end

  def cursor(table), do: table |> state() |> cursor_for()

  @doc "Expire prior-branch cursors without reusing a session sequence."
  def invalidate(table, session_id, run_id) do
    state = state(table)
    :ets.select_delete(table, [{{:"$1", :_, :_}, [{:is_integer, :"$1"}], [true]}])
    translator = fresh_translator(state.translator, session_id, run_id)

    :ets.insert(
      table,
      {:state,
       %{
         state
         | session_id: session_id,
           run_id: run_id,
           stream_id: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
           count: 0,
           bytes: 0,
           translator: translator
       }}
    )

    :ok
  end

  def append(table, event), do: append(table, event, state(table).run_id)

  def append(table, event, run_id) do
    state = %{state(table) | run_id: run_id}
    seq = state.seq + 1

    translator =
      case event do
        {:agent_start} ->
          fresh_translator(state.translator, state.session_id, state.run_id)

        _ ->
          state.translator
      end

    state = %{state | seq: seq}
    cursor = cursor_for(state)
    event_id = state.stream_id <> ":" <> Integer.to_string(seq)

    translator = RunTranslator.handle_event(translator, event)

    meta = %{
      session_key: state.session_key,
      run_id: state.run_id,
      schema_version: 1,
      event_id: event_id,
      session_seq: seq,
      cursor: cursor
    }

    events =
      translator.emitter_state
      |> Enum.reverse()
      |> Enum.map(fn %Event{} = event -> %{event | meta: Map.merge(event.meta || %{}, meta)} end)

    entry = %{cursor: cursor, event_id: event_id, event: event, events: events}
    bytes = :erlang.external_size(entry)
    :ets.insert(table, {seq, bytes, entry})

    state = %{
      state
      | count: state.count + 1,
        bytes: state.bytes + bytes,
        translator: %{translator | emitter_state: []}
    }

    state = evict(table, state)
    :ets.insert(table, {:state, state})
    entry
  end

  def replay(table, cursor, limit) when is_integer(limit) and limit in 1..100 do
    state = state(table)

    with :ok <- validate_cursor(cursor, state) do
      seq = cursor["seq"]
      first = state.seq - state.count + 1

      if seq < first - 1 or seq > state.seq do
        {:error, :cursor_expired}
      else
        entries = page(table, seq + 1, state.seq, limit, [])

        next =
          case List.last(entries) do
            nil -> cursor
            entry -> entry.cursor
          end

        {:ok, %{events: entries, cursor: next, has_more: next["seq"] < state.seq}}
      end
    end
  end

  def replay(_table, _cursor, _limit), do: {:error, :invalid_cursor}

  defp validate_cursor(%{"version" => version}, _state) when version != 1,
    do: {:error, :unsupported_cursor_version}

  defp validate_cursor(
         %{"version" => 1, "sessionId" => session_id, "streamId" => stream_id, "seq" => seq},
         state
       )
       when is_integer(seq) and seq >= 0 do
    if session_id == state.session_id and stream_id == state.stream_id,
      do: :ok,
      else: {:error, :cursor_expired}
  end

  defp validate_cursor(_, _state), do: {:error, :invalid_cursor}

  defp fresh_translator(previous, session_id, run_id) do
    RunTranslator.new(
      emitter: Emitter,
      emitter_state: [],
      engine: "lemon",
      label: "lemon",
      session_id: session_id,
      run_id: run_id,
      cwd: previous.cwd
    )
  end

  defp state(table) do
    [{:state, state}] = :ets.lookup(table, :state)
    state
  end

  defp cursor_for(state) do
    %{
      "version" => 1,
      "sessionId" => state.session_id,
      "streamId" => state.stream_id,
      "seq" => state.seq
    }
  end

  defp evict(table, state) when state.count > state.max_count or state.bytes > state.max_bytes do
    key = :ets.first(table)
    [{^key, bytes, _entry}] = :ets.lookup(table, key)
    :ets.delete(table, key)
    evict(table, %{state | count: state.count - 1, bytes: state.bytes - bytes})
  end

  defp evict(_table, state), do: state

  defp page(_table, seq, last, _limit, acc) when seq > last, do: Enum.reverse(acc)
  defp page(_table, _seq, _last, 0, acc), do: Enum.reverse(acc)

  defp page(table, seq, last, limit, acc) do
    [{^seq, _bytes, entry}] = :ets.lookup(table, seq)
    page(table, seq + 1, last, limit - 1, [entry | acc])
  end
end
