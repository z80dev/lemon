defmodule CodingAgent.Session.EventIdentityContractTest do
  @moduledoc """
  Lifecycle identity contract for native session events (#86, #560).

  Live `session_events` envelopes and cursor replay carry one identity: schema
  version 1, `event_id` (`streamId:seq`), a gap-free `session_seq` scoped to one
  owner stream, and the replay cursor. Consumers deduplicate by `event_id` and
  order by `session_seq` within a stream; a branch epoch or a replacement owner
  starts a new stream, so identities never repeat.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Session.{EventLog, Notifier}
  alias LemonCore.{Bus, Event}

  defmodule Owner do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      session_id = Keyword.fetch!(opts, :session_id)
      session_key = Keyword.fetch!(opts, :session_key)

      {:ok,
       %{
         event_log: EventLog.new(session_id, session_key, "run-1", System.tmp_dir!()),
         session_manager: %{header: %{id: session_id}},
         session_key: session_key,
         run_id: "run-1",
         event_listeners: [],
         event_streams: %{}
       }}
    end

    @impl true
    def handle_call(:cursor, _from, state), do: {:reply, EventLog.cursor(state.event_log), state}

    def handle_call({:append, event}, _from, state) do
      :ok = Notifier.broadcast_event(state, event)
      {:reply, EventLog.cursor(state.event_log), state}
    end

    def handle_call({:run, run_id}, _from, state), do: {:reply, :ok, %{state | run_id: run_id}}

    def handle_call({:replay, cursor}, _from, state),
      do: {:reply, EventLog.replay(state.event_log, cursor, 100), state}

    def handle_call(:invalidate, _from, state) do
      session_id = state.session_manager.header.id
      :ok = EventLog.invalidate(state.event_log, session_id, state.run_id)
      {:reply, EventLog.cursor(state.event_log), state}
    end
  end

  setup do
    n = System.unique_integer([:positive])
    session_key = "agent:identity_contract_#{n}:main"
    session_id = "native-identity-#{n}"
    :ok = Bus.subscribe("session_events")
    on_exit(fn -> Bus.unsubscribe("session_events") end)
    %{session_key: session_key, session_id: session_id}
  end

  test "live envelopes and replay carry one versioned lifecycle identity", c do
    pid = owner(c, :owner)
    initial = GenServer.call(pid, :cursor)

    append(pid, {:agent_start})
    append(pid, {:message_update, {:text_delta, 0, "hello"}})
    GenServer.call(pid, {:run, "run-2"})
    append(pid, {:observed, :untranslated})

    live = receive_live(c.session_key, 3)
    assert {:ok, %{events: replayed, has_more: false}} = GenServer.call(pid, {:replay, initial})

    for {%Event{payload: payload, meta: meta}, seq} <- Enum.with_index(live, 1) do
      assert meta.schema_version == 1
      assert meta.session_seq == seq
      assert meta.cursor["version"] == 1
      assert meta.cursor["seq"] == seq
      assert meta.event_id == meta.cursor["streamId"] <> ":" <> Integer.to_string(seq)
      assert payload.event_id == meta.event_id
      assert payload.cursor == meta.cursor

      # Every translated lifecycle event inherits its batch identity unchanged.
      for %Event{meta: inner} <- payload.events do
        assert Map.take(inner, [:schema_version, :event_id, :session_seq, :cursor, :run_id]) ==
                 Map.take(meta, [:schema_version, :event_id, :session_seq, :cursor, :run_id])
      end
    end

    # Replay returns the identical identity and projected events, never minted IDs.
    assert Enum.map(replayed, &Map.take(&1, [:cursor, :event_id, :events])) ==
             Enum.map(live, & &1.payload)

    assert Enum.map(live, & &1.meta.run_id) == ["run-1", "run-1", "run-2"]

    assert [[%Event{type: :run_started}], [%Event{type: :delta}], []] =
             Enum.map(live, & &1.payload.events)
  end

  test "identities are unique and ordered across branch epochs and owner replacement", c do
    pid = owner(c, :first)
    append(pid, {:observed, 1})
    append(pid, {:observed, 2})
    GenServer.call(pid, :invalidate)
    append(pid, {:observed, 3})

    replacement = owner(c, :replacement)
    append(replacement, {:observed, 4})

    live = receive_live(c.session_key, 4)
    ids = Enum.map(live, & &1.meta.event_id)
    streams = Enum.map(live, & &1.meta.cursor["streamId"])

    assert ids == Enum.uniq(ids)
    [first, first, branch, replaced] = streams
    assert Enum.uniq([first, branch, replaced]) == [first, branch, replaced]

    # One owner never reuses a sequence across branch epochs; a replacement
    # owner starts its own stream, so its seq is comparable only within it.
    assert Enum.map(live, & &1.meta.session_seq) == [1, 2, 3, 1]

    # A consumer applying `seq <= last` per stream drops exact redeliveries only.
    applied =
      Enum.reduce(live ++ live, {%{}, []}, fn %Event{meta: meta}, {last, acc} ->
        stream = meta.cursor["streamId"]

        if meta.session_seq <= Map.get(last, stream, 0),
          do: {last, acc},
          else: {Map.put(last, stream, meta.session_seq), [meta.event_id | acc]}
      end)
      |> elem(1)
      |> Enum.reverse()

    assert applied == ids
  end

  defp owner(c, id) do
    start_supervised!(
      Supervisor.child_spec(
        {Owner, session_id: c.session_id, session_key: c.session_key},
        id: id
      )
    )
  end

  defp append(pid, event), do: GenServer.call(pid, {:append, event})

  defp receive_live(session_key, count) do
    for _ <- 1..count do
      receive do
        %Event{type: :session_event, meta: %{session_key: ^session_key}} = event -> event
      after
        1_000 -> flunk("missing live session_events envelope")
      end
    end
  end
end
