defmodule LemonControlPlane.SessionEventReplayTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{Connections, EventBridge}
  alias LemonControlPlane.Methods.{Registry, SessionsEvents, SessionsSnapshot}
  alias LemonControlPlane.Protocol.{Frames, Schemas}
  alias LemonCore.{AgentRuntime, Event}

  defmodule Runtime do
    @behaviour LemonCore.AgentRuntime.Provider

    def session_event_replay(key, cursor, limit) do
      state =
        Agent.get_and_update(owner(), fn state ->
          {state, Map.update!(state, :reads, &(&1 + 1))}
        end)

      send(state.observer, {:replay_read, key, cursor, limit})

      if state.barrier do
        send(state.observer, {:replay_barrier, self()})

        receive do
          :release_replay -> :ok
        after
          5_000 -> raise "replay barrier was not released"
        end
      end

      case state.result do
        :raise -> raise "private-provider-failure"
        :exit -> exit(:private_provider_failure)
        :throw -> throw(:private_provider_failure)
        result -> result
      end
    end

    def session_recovery_snapshot(_key, _cwd) do
      Agent.get_and_update(owner(), fn state ->
        [native | rest] = state.snapshots
        remaining = if rest == [], do: [native], else: rest
        {{:ok, native}, %{state | snapshots: remaining}}
      end)
    end

    def list_tasks, do: []
    def session_process_receipts(_owner), do: {:ok, []}
    def session_todos(_key, _cwd), do: {:ok, [], {0, nil}}
    defp owner, do: Application.fetch_env!(:lemon_control_plane, __MODULE__)
  end

  defmodule MissingRuntime do
    @behaviour LemonCore.AgentRuntime.Provider
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    original_runtime = Application.get_env(:lemon_control_plane, Runtime)
    observer = self()
    key = "agent:cursor_replay_#{System.unique_integer([:positive])}:main"
    conn_id = "cursor-connection-#{System.unique_integer([:positive])}"
    initial = cursor(0)

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             observer: observer,
             reads: 0,
             barrier: false,
             result: page([], initial),
             snapshots: [native(initial)]
           }
         end}
      )

    Application.put_env(:lemon_control_plane, Runtime, state)
    :ok = AgentRuntime.register(Runtime)
    if is_nil(Process.whereis(Registry)), do: start_supervised!(Registry)
    if is_nil(Process.whereis(Connections)), do: start_supervised!(Connections)
    if is_nil(Process.whereis(EventBridge)), do: start_supervised!(EventBridge)

    on_exit(fn ->
      restore_env(:lemon_core, :agent_runtime_provider, original)
      restore_env(:lemon_control_plane, Runtime, original_runtime)
    end)

    %{key: key, state: state, conn_id: conn_id, cursor: initial}
  end

  test "method, schema, event, and optional provider callback are registered", c do
    assert Registry.lookup("sessions.events") == {:ok, SessionsEvents}
    assert Registry.dispatch_mode("sessions.events") == :async
    assert SessionsEvents.scopes() == [:read]
    assert :ok = Schemas.validate("sessions.events", params(c))
    assert {:error, _} = Schemas.validate("sessions.events", %{"sessionKey" => c.key})
    assert "session.event" in Frames.supported_events()

    assert {:session_event_replay, 3} in LemonCore.AgentRuntime.Provider.behaviour_info(
             :optional_callbacks
           )

    assert {:ok, %{"status" => "ok", "entries" => [], "cursor" => cursor, "hasMore" => false}} =
             Registry.dispatch("sessions.events", params(c), ctx())

    assert cursor == c.cursor
    assert_receive {:replay_read, key, ^cursor, 50}
    assert key == c.key
  end

  test "shared TUI fixture matches the exact method JSON responses", c do
    fixture =
      Path.expand("../../../../clients/tui/test/fixtures/session-events.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    c = %{c | key: fixture["page"]["sessionKey"]}
    set_result(c, page([entry(1, [delta(c.key, "hello")]), entry(2, [])], cursor(2), true))
    assert {:ok, result} = SessionsEvents.handle(params(c), ctx())
    assert Jason.decode!(Jason.encode!(result)) == fixture["page"]

    set_result(c, page([], cursor(2)))
    assert {:ok, result} =
             SessionsEvents.handle(Map.put(params(c), "cursor", cursor(2)), ctx())
    assert Jason.decode!(Jason.encode!(result)) == fixture["empty"]

    set_result(c, {:error, :cursor_expired})
    assert {:ok, result} = SessionsEvents.handle(params(c), ctx())
    assert Jason.decode!(Jason.encode!(result)) == fixture["expired"]
  end

  test "replay preserves order, identity, empty batches, and exact live projections", c do
    first = entry(1, [delta(c.key, "a"), delta(c.key, "b")])
    second = entry(2, [])
    third = entry(3, [delta(c.key, "c")])
    set_result(c, page([first, second], second.cursor, true))

    assert {:ok, result} = SessionsEvents.handle(Map.put(params(c), "limit", 2), ctx())
    assert result["status"] == "ok"
    assert result["sessionKey"] == c.key
    assert result["cursor"] == second.cursor
    assert result["hasMore"]

    assert result["entries"] == [wire_entry(c.key, first), wire_entry(c.key, second)]
    assert Enum.at(result["entries"], 1)["events"] == []
    refute Jason.encode!(result) =~ "private-native-event"
    refute Map.has_key?(hd(result["entries"]), "event")

    # Re-reading the same cursor returns the same identity, never minted IDs.
    assert {:ok, ^result} = SessionsEvents.handle(Map.put(params(c), "limit", 2), ctx())
    set_result(c, page([third], third.cursor))

    assert {:ok, next} =
             SessionsEvents.handle(%{params(c) | "cursor" => second.cursor}, ctx())

    assert next["entries"] == [wire_entry(c.key, third)]
    refute next["hasMore"]
  end

  test "session_events bus forwards recursive projected batches but never to nodes", c do
    register(c, ctx().auth)
    bridge = Process.whereis(EventBridge)
    parent = self()
    node = start_supervised!({Task, fn -> collect_node(c.conn_id, parent) end})
    send(node, {:register_node, parent})
    assert_receive {:node_registered, ^node}

    inner = entry(1, [delta(c.key, "nested")])
    nested = envelope(c.key, inner)
    outer = entry(2, [nested, delta(c.key, "tail")])
    expected = wire_entry(c.key, outer) |> Map.put("sessionKey", c.key)
    assert :ok = Schemas.validate_event("session.event", expected)

    LemonCore.Bus.broadcast("session_events", envelope(c.key, outer))
    :sys.get_state(bridge)
    assert_receive {:event, "session.event", ^expected, _versions}, 1_000
    send(node, {:barrier, parent})
    assert_receive {:node_barrier, ^node}
    refute_receive {:node_session_event, _}, 0

    empty = entry(3, [])
    empty_payload = wire_entry(c.key, empty) |> Map.put("sessionKey", c.key)
    LemonCore.Bus.broadcast("session_events", envelope(c.key, empty))
    assert_receive {:event, "session.event", ^empty_payload, _versions}, 1_000
  end

  test "invalid bounded inputs and unsupported cursor versions never reach the provider", c do
    for invalid <- [
          nil,
          %{},
          "opaque",
          Map.put(c.cursor, "seq", -1),
          Map.put(c.cursor, "seq", 1.5)
        ] do
      assert {:error, {:invalid_params, _, _}} =
               SessionsEvents.handle(Map.put(params(c), "cursor", invalid), ctx())
    end

    for field <- ["sessionId", "streamId"],
        value <- ["", String.duplicate("x", 1025), "bad\0id"] do
      invalid = Map.put(c.cursor, field, value)

      assert {:error, {:invalid_params, _, _}} =
               SessionsEvents.handle(Map.put(params(c), "cursor", invalid), ctx())
    end

    for limit <- [0, 101, 1.5, "1", nil] do
      assert {:error, {:invalid_params, _, _}} =
               SessionsEvents.handle(Map.put(params(c), "limit", limit), ctx())
    end

    assert {:error, {:invalid_params, _, %{"reason" => "unsupported_cursor_version"}}} =
             SessionsEvents.handle(
               Map.put(params(c), "cursor", Map.put(c.cursor, "version", 2)),
               ctx()
             )

    assert {:error, {:invalid_params, _, _}} =
             SessionsEvents.handle(Map.put(params(c), "sessionKey", ""), ctx())

    assert Agent.get(c.state, & &1.reads) == 0

    for limit <- [1, 100] do
      assert {:ok, _} = SessionsEvents.handle(Map.put(params(c), "limit", limit), ctx())
    end
  end

  test "expiry is distinct from unavailable providers and unsupported versions", c do
    set_result(c, {:error, :cursor_expired})

    assert {:ok,
            %{
              "status" => "cursor_expired",
              "sessionKey" => key,
              "entries" => [],
              "cursor" => nil,
              "hasMore" => false
            }} = SessionsEvents.handle(params(c), ctx())

    assert key == c.key
    set_result(c, {:error, :unsupported_cursor_version})

    assert {:error, {:invalid_params, _, %{"reason" => "unsupported_cursor_version"}}} =
             SessionsEvents.handle(params(c), ctx())

    for failure <- [
          :raise,
          :exit,
          :throw,
          {:error, :unavailable},
          {:error, "private-failure"},
          nil
        ] do
      set_result(c, failure)

      assert {:error, {:unavailable, "Session event replay unavailable", nil}} =
               SessionsEvents.handle(params(c), ctx())
    end

    :ok = AgentRuntime.register(MissingRuntime)
    assert {:error, {:unavailable, _, nil}} = SessionsEvents.handle(params(c), ctx())
    Application.delete_env(:lemon_core, :agent_runtime_provider)
    assert {:error, {:unavailable, _, nil}} = SessionsEvents.handle(params(c), ctx())
  end

  test "malformed provider pages cannot skip sequence, switch owners, or leak raw fields", c do
    valid = entry(1, [delta(c.key, "safe")])

    for result <- [
          page([valid], c.cursor),
          page([], c.cursor, true),
          page([entry(2, [])], cursor(2)),
          page([%{valid | event_id: "wrong"}], valid.cursor),
          page([%{valid | cursor: Map.put(valid.cursor, "streamId", "foreign")}], valid.cursor),
          page([%{valid | cursor: Map.put(valid.cursor, "sessionId", "foreign")}], valid.cursor),
          page([Map.delete(valid, :events)], valid.cursor),
          {:ok, %{events: [], cursor: c.cursor, has_more: "yes"}}
        ] do
      set_result(c, result)
      assert {:error, {:unavailable, _, nil}} = SessionsEvents.handle(params(c), ctx())
    end

    set_result(c, page([valid, entry(2, [])], cursor(2)))

    assert {:error, {:unavailable, _, nil}} =
             SessionsEvents.handle(Map.put(params(c), "limit", 1), ctx())
  end

  test "only read-authorized operators may invoke the provider", c do
    for auth <- [%{role: :node, scopes: [:read]}, %{role: :operator, scopes: [:write]}, %{}] do
      assert {:error, _} = SessionsEvents.handle(params(c), %{auth: auth})
    end

    assert {:error, _} = SessionsEvents.handle(params(c), %{})
    assert Agent.get(c.state, & &1.reads) == 0
  end

  test "connection requests require current membership and authorization before reading", c do
    connection_ctx = connection_ctx(c)
    assert {:error, {:forbidden, _, _}} = SessionsEvents.handle(params(c), connection_ctx)

    for info <- [
          %{role: :operator},
          %{role: :operator, auth: %{role: :operator, scopes: []}},
          %{role: :node, auth: ctx().auth},
          %{role: :operator, auth: %{role: :node, scopes: [:read]}}
        ] do
      Connections.register(c.conn_id, Map.put(info, :pid, self()))
      assert {:error, _} = SessionsEvents.handle(params(c), connection_ctx)
    end

    register(c, ctx().auth)

    assert {:error, {:forbidden, _, _}} =
             SessionsEvents.handle(params(c), %{connection_ctx | conn_id: "replaced-connection"})

    assert {:error, {:forbidden, _, _}} =
             SessionsEvents.handle(params(c), %{connection_ctx | conn_pid: nil})

    assert Agent.get(c.state, & &1.reads) == 0
    assert {:ok, _} = SessionsEvents.handle(params(c), connection_ctx)
  end

  test "membership and authorization revocation during replay discard the provider result", c do
    Agent.update(c.state, &%{&1 | barrier: true})

    for revoke <- [:membership, :scopes, :role, :auth] do
      register(c, ctx().auth)
      connection_ctx = connection_ctx(c)
      task = Task.async(fn -> SessionsEvents.handle(params(c), connection_ctx) end)
      assert_receive {:replay_barrier, worker}
      assert worker == task.pid

      case revoke do
        :membership -> Connections.unregister(c.conn_id)
        :scopes -> register(c, %{role: :operator, scopes: []})
        :role -> register(c, %{role: :node, scopes: [:read]})
        :auth -> Connections.register(c.conn_id, %{role: :operator, pid: self()})
      end

      send(worker, :release_replay)
      assert {:error, _} = Task.await(task)
    end
  end

  test "connection owner death and expiry replies still undergo the post-read authorization fence",
       c do
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           register(c, ctx().auth)
           send(parent, {:owner_ready, self()})

           receive do
             :stop -> :ok
           end
         end}
      )

    assert_receive {:owner_ready, ^owner}
    monitor = Process.monitor(owner)
    Agent.update(c.state, &%{&1 | barrier: true, result: {:error, :cursor_expired}})
    connection_ctx = %{connection_ctx(c) | conn_pid: owner}
    task = Task.async(fn -> SessionsEvents.handle(params(c), connection_ctx) end)
    assert_receive {:replay_barrier, worker}
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    send(worker, :release_replay)
    assert {:error, {:forbidden, _, _}} = Task.await(task)
  end

  test "live snapshot exposes its cursor and cursor-only races preserve the double-read fence",
       c do
    assert {:ok, stable} = SessionsSnapshot.handle(%{"sessionKey" => c.key}, ctx())
    assert stable["consistency"]["eventCursor"] == c.cursor
    assert stable["consistency"]["boundary"] == "stable_owner_reads"
    refute stable["consistency"]["atomic"]

    Agent.update(c.state, &%{&1 | snapshots: [native(c.cursor), native(cursor(1))]})

    assert {:ok, raced} = SessionsSnapshot.handle(%{"sessionKey" => c.key}, ctx())
    assert raced["status"] == "retry"
    assert raced["reason"] == "snapshot_raced"
    refute Map.has_key?(raced, "snapshot")

    Agent.update(c.state, &%{&1 | snapshots: [%{native(c.cursor) | live: false}]})
    assert {:ok, offline} = SessionsSnapshot.handle(%{"sessionKey" => c.key}, ctx())
    assert offline["consistency"]["eventCursor"] == nil
  end

  @tag :tmp_dir
  test "native replay binds the logical key to its unique live owner incarnation", c do
    alias CodingAgent.Session
    alias CodingAgent.Session.Presentation

    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)
    register(c, ctx().auth)

    opts =
      Presentation.build_session_opts(
        [],
        c.tmp_dir,
        "cursor-run-#{System.unique_integer([:positive])}",
        c.key,
        LemonCore.SessionKey.agent_id(c.key)
      )
      |> Keyword.put(:tools, [])
      |> Keyword.put(:session_id, "cursor-native-#{System.unique_integer([:positive])}")

    owner = start_supervised!(Supervisor.child_spec({Session, opts}, id: :native_cursor_owner))

    assert {:ok, snapshot} =
             CodingAgent.ControlPlaneProvider.session_recovery_snapshot(c.key, nil)

    initial = snapshot.event_cursor
    request = %{"sessionKey" => c.key, "cursor" => initial}
    assert {:ok, %{"entries" => [], "cursor" => ^initial}} = SessionsEvents.handle(request, ctx())

    # A real owner broadcast is captured and projected without running a provider.
    send(owner, {:task_progress, "cursor-call", %{}})
    Session.get_state(owner)
    assert {:ok, replayed} = SessionsEvents.handle(request, ctx())
    assert [event] = replayed["entries"]
    assert event["cursor"]["seq"] == initial["seq"] + 1
    assert event["eventId"] == initial["streamId"] <> ":" <> to_string(event["cursor"]["seq"])
    live_payload = Map.put(event, "sessionKey", c.key)
    assert_receive {:event, "session.event", ^live_payload, _versions}, 1_000

    foreign = Map.put(request, "sessionKey", c.key <> "-foreign")
    assert {:ok, %{"status" => "cursor_expired"}} = SessionsEvents.handle(foreign, ctx())

    stop_supervised!(:native_cursor_owner)
    assert {:ok, %{"status" => "cursor_expired"}} = SessionsEvents.handle(request, ctx())
    start_supervised!(Supervisor.child_spec({Session, opts}, id: :native_cursor_owner))
    assert {:ok, %{"status" => "cursor_expired"}} = SessionsEvents.handle(request, ctx())

    assert {:ok, replacement} =
             CodingAgent.ControlPlaneProvider.session_recovery_snapshot(c.key, nil)

    assert replacement.event_cursor["sessionId"] == initial["sessionId"]
    refute replacement.event_cursor["streamId"] == initial["streamId"]

    second_opts =
      Keyword.put(opts, :session_id, "other-native-#{System.unique_integer([:positive])}")

    start_supervised!(Supervisor.child_spec({Session, second_opts}, id: :ambiguous_cursor_owner))
    assert {:error, {:unavailable, _, _}} = SessionsEvents.handle(request, ctx())
  end

  defp cursor(seq),
    do: %{
      "version" => 1,
      "sessionId" => "native-owner",
      "streamId" => "owner-stream",
      "seq" => seq
    }

  defp entry(seq, events) do
    %{
      cursor: cursor(seq),
      event_id: "owner-stream:#{seq}",
      event: {:private_native_event, "private-native-event"},
      events: events
    }
  end

  defp page(entries, cursor, more \\ false),
    do: {:ok, %{events: entries, cursor: cursor, has_more: more}}

  defp delta(key, text),
    do:
      Event.new(
        :delta,
        %LemonCore.Events.Delta{run_id: "replay-run", text: text, seq: 1},
        %{session_key: key, run_id: "replay-run"}
      )

  defp envelope(key, entry),
    do:
      Event.new(:session_event, Map.take(entry, [:cursor, :event_id, :events]), %{
        session_key: key
      })

  defp wire_entry(key, entry) do
    {"session.event", payload} = EventBridge.project(envelope(key, entry))
    Map.delete(payload, "sessionKey")
  end

  defp native(cursor) do
    %{
      session_id: cursor["sessionId"],
      event_cursor: cursor,
      branch_id: nil,
      revision: "unchanged-native-revision",
      run_id: nil,
      cwd: "/workspace",
      streaming: false,
      live: true,
      failed: false,
      partial: nil,
      pending: [],
      plan: %{"mode" => "code", "path" => nil, "content" => nil},
      entries: []
    }
  end

  defp params(c), do: %{"sessionKey" => c.key, "cursor" => c.cursor}
  defp ctx, do: %{auth: %{role: :operator, scopes: [:read]}}
  defp connection_ctx(c), do: Map.merge(ctx(), %{conn_id: c.conn_id, conn_pid: self()})
  defp set_result(c, result), do: Agent.update(c.state, &%{&1 | result: result})

  defp register(c, auth),
    do: Connections.register(c.conn_id, %{pid: self(), role: auth.role, auth: auth})

  defp collect_node(conn_id, parent) do
    receive do
      {:register_node, observer} ->
        Connections.register(conn_id <> "-node", %{pid: self(), role: :node})
        send(observer, {:node_registered, self()})
        collect_node(conn_id, observer)

      {:event, "session.event", payload, _versions} ->
        send(parent, {:node_session_event, payload})
        collect_node(conn_id, parent)

      {:barrier, observer} ->
        send(observer, {:node_barrier, self()})
        collect_node(conn_id, parent)
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
