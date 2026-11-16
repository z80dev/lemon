defmodule CodingAgent.Session.EventLogCursorTest do
  use ExUnit.Case, async: true

  defmodule Owner do
    use GenServer
    alias CodingAgent.Session.{EventLog, Notifier}

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      log = EventLog.new("native-1", "session-key", "run-1", System.tmp_dir!(), opts)

      {:ok,
       %{
         event_log: log,
         session_manager: %{header: %{id: "native-1"}},
         session_key: "session-key",
         run_id: "run-1",
         event_listeners: [],
         event_streams: %{}
       }}
    end

    @impl true
    def handle_call(:cursor, _from, state), do: {:reply, EventLog.cursor(state.event_log), state}
    def handle_call(:table, _from, state), do: {:reply, state.event_log, state}

    def handle_call({:append, event}, _from, state) do
      :ok = Notifier.broadcast_event(state, event)
      {:reply, EventLog.cursor(state.event_log), state}
    end

    def handle_call({:replay, cursor, limit}, _from, state),
      do: {:reply, EventLog.replay(state.event_log, cursor, limit), state}

    def handle_call({:subscribe, pid}, _from, state) do
      {unsubscribe, state} = Notifier.subscribe_direct(state, pid, self())
      {:reply, unsubscribe, state}
    end

    def handle_call(:invalidate, _from, state) do
      :ok = EventLog.invalidate(state.event_log, "native-1", "run-1")
      {:reply, EventLog.cursor(state.event_log), state}
    end

    def handle_call(:usage, _from, state) do
      rows = :ets.tab2list(state.event_log)
      entries = for {seq, bytes, _entry} <- rows, is_integer(seq), do: bytes
      {:reply, %{count: length(entries), bytes: Enum.sum(entries)}, state}
    end
  end

  defmodule SnapshotAgent do
    use GenServer
    def start_link(_opts), do: GenServer.start_link(__MODULE__, nil)
    def init(nil), do: {:ok, nil}

    def handle_call(:get_state, {owner, _tag}, state) do
      send(owner, {:agent_event, {:observed, :before_snapshot}})

      snapshot = %{
        messages: [],
        is_streaming: false,
        stream_message: nil,
        pending_tool_calls: MapSet.new(),
        error: nil
      }

      {:reply, snapshot, state}
    end
  end

  test "snapshot replies cannot overtake pending agent broadcasts and their cursor" do
    alias CodingAgent.Session
    alias CodingAgent.Session.{EventLog, Notifier}

    agent = start_supervised!({SnapshotAgent, []})
    manager = CodingAgent.SessionManager.new(System.tmp_dir!())
    log = EventLog.new(manager.header.id, "session-key", "run-1", System.tmp_dir!())

    state = %Session{
      agent: agent,
      session_manager: manager,
      event_log: log,
      session_key: "session-key",
      run_id: "run-1",
      event_listeners: [],
      event_streams: %{},
      is_streaming: false,
      turn_index: 0
    }

    reply_ref = make_ref()

    assert {:noreply, pending} =
             Session.handle_call(:recovery_snapshot, {self(), reply_ref}, state)

    assert_receive {:agent_event, event}
    # This is the owner processing the preceding broadcast, not an ETS-only
    # observation of the producer. The agent response follows it in the mailbox.
    :ok = Notifier.broadcast_event(pending, event)

    response =
      receive do
        message -> message
      after
        1_000 -> flunk("missing asynchronous agent state response")
      end

    assert {:noreply, resolved} = Session.handle_info(response, pending)
    assert resolved.recovery_requests == %{}
    assert_receive {^reply_ref, {:ok, snapshot}}
    assert snapshot.event_cursor["seq"] == 1
    assert {:ok, %{events: []}} = EventLog.replay(log, snapshot.event_cursor, 100)
  end

  defp owner(opts \\ []), do: start_supervised!({Owner, opts})
  defp append(pid, event), do: GenServer.call(pid, {:append, event})
  defp replay(pid, cursor, limit \\ 100), do: GenServer.call(pid, {:replay, cursor, limit})

  test "broadcasts have gap-free identity and replay preserves identical events in order" do
    pid = owner()
    initial = GenServer.call(pid, :cursor)
    GenServer.call(pid, {:subscribe, self()})
    cursors = for n <- 1..5, do: append(pid, {:observed, n})
    assert Enum.map(cursors, & &1["seq"]) == Enum.to_list(1..5)

    for n <- 1..5 do
      assert_receive {:session_event, "native-1", {:observed, ^n}, cursor}
      assert cursor == Enum.at(cursors, n - 1)
    end

    assert {:ok, first} = replay(pid, initial, 2)
    assert first.has_more
    assert Enum.map(first.events, & &1.event) == [{:observed, 1}, {:observed, 2}]
    assert {:ok, second} = replay(pid, first.cursor)
    refute second.has_more
    assert Enum.map(second.events, & &1.event) == [{:observed, 3}, {:observed, 4}, {:observed, 5}]
    assert {:ok, again} = replay(pid, initial, 2)
    assert again == first

    assert Enum.map(first.events, & &1.event_id) ==
             Enum.map(Enum.take(cursors, 2), fn cursor ->
               cursor["streamId"] <> ":" <> to_string(cursor["seq"])
             end)
  end

  test "the same retained projected events carry schema and stable lifecycle identity" do
    pid = owner()
    cursor = GenServer.call(pid, :cursor)
    append(pid, {:agent_start})
    append(pid, {:message_update, {:text_delta, 0, "hello"}})
    assert {:ok, %{events: [started, delta]}} = replay(pid, cursor)
    assert [%LemonCore.Event{type: :run_started, meta: meta}] = started.events
    assert meta.schema_version == 1
    assert meta.event_id == started.event_id
    assert meta.cursor == started.cursor
    assert meta.session_seq == 1
    assert meta.run_id == "run-1"
    assert [%LemonCore.Event{type: :delta, payload: %{seq: 1, text: "hello"}}] = delta.events
  end

  test "count eviction expires only the missing prefix, never the oldest valid boundary" do
    pid = owner(event_log_max_count: 2)
    cursor = GenServer.call(pid, :cursor)
    first = append(pid, {:observed, 1})
    append(pid, {:observed, 2})
    append(pid, {:observed, 3})
    assert {:error, :cursor_expired} = replay(pid, cursor)
    assert {:ok, %{events: entries}} = replay(pid, first)
    assert Enum.map(entries, & &1.cursor["seq"]) == [2, 3]
    assert %{count: 2} = GenServer.call(pid, :usage)
  end

  test "encoded byte budget evicts oversized events without hiding their sequence" do
    pid = owner(event_log_max_count: 100, event_log_max_bytes: 1_024)
    initial = GenServer.call(pid, :cursor)
    oversized = append(pid, {:observed, String.duplicate("x", 4_096)})
    assert %{count: 0, bytes: 0} = GenServer.call(pid, :usage)
    assert {:error, :cursor_expired} = replay(pid, initial)
    assert {:ok, %{events: []}} = replay(pid, oversized)
    append(pid, {:observed, :small})
    assert {:ok, %{events: [entry]}} = replay(pid, oversized)
    assert entry.cursor["seq"] == 2
    assert %{count: 1, bytes: bytes} = GenServer.call(pid, :usage)
    assert bytes <= 1_024
  end

  test "branch changes invalidate cursors without reusing sequence numbers" do
    pid = owner()
    before = append(pid, {:observed, 1})
    after_branch = GenServer.call(pid, :invalidate)
    assert after_branch["seq"] == 1
    refute after_branch["streamId"] == before["streamId"]
    assert {:error, :cursor_expired} = replay(pid, before)
    next = append(pid, {:observed, 2})
    assert next["seq"] == 2
    assert {:ok, %{events: [entry]}} = replay(pid, after_branch)
    assert entry.cursor == next
  end

  test "owner death destroys the protected ordered set and replacement expires old identity" do
    pid = owner()
    table = GenServer.call(pid, :table)
    assert :ets.info(table, :owner) == pid
    assert :ets.info(table, :type) == :ordered_set
    assert :ets.info(table, :protection) == :protected
    cursor = append(pid, {:observed, 1})
    ref = Process.monitor(pid)
    stop_supervised!(Owner)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert :ets.info(table) == :undefined
    replacement = owner()
    assert {:error, :cursor_expired} = replay(replacement, cursor)
  end

  test "unsupported versions and future or foreign cursors fail explicitly" do
    pid = owner()
    cursor = GenServer.call(pid, :cursor)
    assert {:error, :unsupported_cursor_version} = replay(pid, %{cursor | "version" => 2})
    assert {:error, :cursor_expired} = replay(pid, %{cursor | "sessionId" => "foreign"})
    assert {:error, :cursor_expired} = replay(pid, %{cursor | "seq" => 1})
    assert {:error, :invalid_cursor} = replay(pid, %{})
  end
end
