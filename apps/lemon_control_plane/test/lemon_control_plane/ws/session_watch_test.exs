defmodule LemonControlPlane.WS.SessionWatchTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.{Connections, EventBridge}
  alias LemonControlPlane.Protocol.Frames
  alias LemonControlPlane.WS.Connection
  alias LemonCore.{Bus, Event, Events}

  test "a watched session gets one text delta and nothing from another session" do
    suffix = System.unique_integer([:positive])
    a = "agent:scope#{suffix}:a"
    b = "agent:scope#{suffix}:b"
    run = "run-#{suffix}"
    {:ok, state} = Connection.init([])
    auth = %{role: :operator, scopes: [:read, :content]}
    state = %{state | connected: true, auth: auth}

    :ok =
      Connections.register(state.conn_id, %{
        pid: self(),
        role: :operator,
        auth: auth,
        delivery: state.delivery
      })

    state = watch(state, a)
    :ok = EventBridge.subscribe_run(run)
    on_exit(fn -> EventBridge.unsubscribe_run(run) end)
    :sys.get_state(EventBridge)

    {batch, standalone} = delta(a, run, "x")
    {foreign, _} = delta(b, run, "foreign")
    :ok = Bus.broadcast(Bus.session_topic(b), foreign)
    :ok = Bus.broadcast(Bus.session_topic(a), batch)
    :ok = Bus.broadcast(Bus.run_topic(run), standalone)
    :sys.get_state(EventBridge)

    assert_receive ^batch
    assert {:push, {:text, text}, state} = Connection.handle_info(batch, state)

    assert %{
             "event" => "session.event",
             "payload" => %{
               "sessionKey" => ^a,
               "schemaVersion" => 1,
               "events" => [%{"event" => "chat", "payload" => %{"text" => "x"}}]
             }
           } = Jason.decode!(text)

    refute_receive %Event{type: :session_event}, 20
    refute_receive {:event, "chat", _, _}, 20
    assert {:ok, ^state} = Connection.handle_info(foreign, state)

    # Measure the previous two-frame wire shape with the same one-byte token and IDs.
    legacy_batch = %{batch | meta: Map.delete(batch.meta, :schema_version)}

    before =
      [legacy_batch, standalone]
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} ->
        {name, payload} = EventBridge.project(event)
        {name, payload} = EventBridge.authorize_event(name, payload, auth.scopes)
        byte_size(Frames.encode_event(name, payload, seq, %{}))
      end)

    assert byte_size(text) < Enum.sum(before)

    IO.puts(
      "session token wire bytes: before=#{inspect(before)} (2 frames); after=#{byte_size(text)} (1 frame)"
    )

    state = watch(state, b)
    :ok = Bus.broadcast(Bus.session_topic(a), batch)
    :ok = Bus.broadcast(Bus.session_topic(b), foreign)
    assert_receive ^foreign
    refute_receive ^batch, 20
    assert {:ok, ^state} = Connection.handle_info(batch, state)
  end

  defp watch(state, key) do
    request =
      Jason.encode!(%{
        type: "req",
        id: "watch",
        method: "sessions.watch",
        params: %{sessionKey: key}
      })

    assert {:push, {:text, response}, state} =
             Connection.handle_in({request, [opcode: :text]}, state)

    assert %{"ok" => true} = Jason.decode!(response)
    state
  end

  defp delta(key, run, text) do
    base = %{session_key: key, run_id: run}
    payload = Events.Delta.new(%{run_id: run, seq: 1, text: text})
    standalone = Event.new(:delta, payload, base)
    cursor = %{"version" => 1, "sessionId" => "native", "streamId" => "stream", "seq" => 1}

    meta =
      Map.merge(base, %{
        schema_version: 1,
        attempt_id: "#{run}:attempt:1",
        event_id: "stream:1",
        session_seq: 1
      })

    batch =
      Event.new(
        :session_event,
        %{cursor: cursor, event_id: "stream:1", events: [%{standalone | meta: meta}]},
        meta
      )

    {batch, standalone}
  end
end
