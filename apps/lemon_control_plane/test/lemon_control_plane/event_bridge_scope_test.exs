defmodule LemonControlPlane.EventBridgeScopeTest do
  @moduledoc """
  Per-recipient authorization of the operator event stream: live fanout and
  `sessions.events` replay apply each connection's current scopes, so a
  read-only operator receives metadata, never transcript content, approvals or
  pairing codes.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.{Connections, EventBridge}
  alias LemonControlPlane.Methods.Registry
  alias LemonCore.{Bus, Event}

  @prose "the merger closes Friday at 41 dollars"
  @secret "PROMPT_SECRET_7Q2"
  @full [:admin, :read, :write, :approvals, :pairing, :content]

  defmodule Runtime do
    def session_event_replay(_key, _cursor, _limit),
      do: Application.fetch_env!(:lemon_control_plane, __MODULE__)
  end

  setup do
    for module <- [Registry, Connections, EventBridge] do
      if is_nil(Process.whereis(module)), do: start_supervised!(module)
    end

    clear_connections()
    on_exit(&clear_connections/0)

    suffix = System.unique_integer([:positive])
    %{run_id: "scope-run-#{suffix}", session_key: "agent:scope_#{suffix}:main"}
  end

  describe "live fanout" do
    test "read-only operators receive metadata without content, approvals or pairing codes", c do
      read = connect(:read_only, [:read])
      full = connect(:full, @full)
      bare = connect(:no_auth, nil)
      mismatched = connect(:node_auth, %{role: :node, scopes: [:read, :content]})

      publish_all(c)
      sync([read, full, bare, mismatched])

      read_events = events(:read_only)
      full_events = events(:full)

      # Full-scope operators keep today's content.
      full_text = dump(full_events)
      assert full_text =~ @prose
      assert full_text =~ @secret
      assert Enum.any?(full_events, &match?({"chat", %{"text" => _}}, &1))
      assert Enum.any?(full_events, &match?({"exec.approval.requested", _}, &1))

      assert Enum.any?(
               full_events,
               &match?({"node.pair.requested", %{"code" => "PAIR-CODE"}}, &1)
             )

      assert {"session.event", %{"events" => full_inner}} =
               Enum.find(full_events, &match?({"session.event", _}, &1))

      assert Enum.any?(full_inner, &match?(%{"event" => "chat"}, &1))

      # Read-only operators receive no frame carrying the content.
      read_text = dump(read_events)
      refute read_text =~ @prose
      refute read_text =~ @secret
      refute read_text =~ "PAIR-CODE"
      refute Enum.any?(read_events, &match?({"chat", _}, &1))
      refute Enum.any?(read_events, &match?({"exec.approval." <> _, _}, &1))
      refute Enum.any?(read_events, &match?({"node.pair." <> _, _}, &1))

      # ...but still observe run lifecycle metadata.
      assert {"agent", completed} =
               Enum.find(read_events, &match?({"agent", %{"type" => "completed"}}, &1))

      assert completed["ok"] == true
      assert completed["runId"] == c.run_id
      refute Map.has_key?(completed, "answer")

      assert {"agent", tool_use} =
               Enum.find(read_events, &match?({"agent", %{"type" => "tool_use"}}, &1))

      assert %{"id" => "tool-1", "kind" => :command} = tool_use["action"]
      assert map_size(tool_use["action"]) == 2
      refute Map.has_key?(tool_use, "message")

      # The batch is forwarded for cursor continuity without the delta.
      assert {"session.event", batch} = Enum.find(read_events, &match?({"session.event", _}, &1))
      assert batch["cursor"] == cursor(7)
      assert batch["eventId"] == "scope-stream:7"
      assert batch["sessionKey"] == c.session_key
      refute Enum.any?(batch["events"], &match?(%{"event" => "chat"}, &1))
      refute Enum.any?(batch["events"], &match?(%{"event" => "exec.approval." <> _}, &1))
      assert [%{"event" => "agent", "payload" => %{"type" => "started"}}] = batch["events"]

      # Connections without current operator authorization receive nothing.
      assert events(:no_auth) == []
      assert events(:node_auth) == []
    end

    test "approval events require :approvals and pairing events require :pairing", c do
      approvals = connect(:approvals, [:read, :approvals])
      content = connect(:content, [:read, :content])
      pairing = connect(:pairing, [:pairing])

      publish_all(c)
      sync([approvals, content, pairing])

      approval_events = events(:approvals)
      assert Enum.any?(approval_events, &match?({"exec.approval.requested", _}, &1))
      assert Enum.any?(approval_events, &match?({"exec.approval.resolved", _}, &1))
      refute Enum.any?(approval_events, &match?({"node.pair." <> _, _}, &1))
      # Approval payloads keep their review targets; everything else stays metadata.
      refute Enum.any?(approval_events, &match?({"chat", _}, &1))

      refute approval_events
             |> Enum.reject(&match?({"exec.approval." <> _, _}, &1))
             |> Enum.map(fn
               {"session.event", batch} ->
                 Enum.reject(batch["events"], &match?(%{"event" => "exec.approval." <> _}, &1))

               other ->
                 other
             end)
             |> dump() =~ @prose

      assert {"session.event", %{"events" => inner}} =
               Enum.find(approval_events, &match?({"session.event", _}, &1))

      assert Enum.any?(inner, &match?(%{"event" => "exec.approval.requested"}, &1))
      refute Enum.any?(inner, &match?(%{"event" => "chat"}, &1))

      content_events = events(:content)
      refute Enum.any?(content_events, &match?({"exec.approval." <> _, _}, &1))
      refute Enum.any?(content_events, &match?({"node.pair." <> _, _}, &1))
      assert dump(content_events) =~ @prose

      assert {"session.event", %{"events" => content_inner}} =
               Enum.find(content_events, &match?({"session.event", _}, &1))

      assert Enum.any?(content_inner, &match?(%{"event" => "chat"}, &1))
      refute Enum.any?(content_inner, &match?(%{"event" => "exec.approval." <> _}, &1))

      pairing_events = events(:pairing)
      assert [{"node.pair.requested", %{"code" => "PAIR-CODE"}}] = pairing_events
    end

    test "scope order and duplicates do not change a recipient's view", c do
      ordered = connect(:ordered, [:read, :approvals])
      shuffled = connect(:shuffled, [:approvals, :read, :approvals, :write])

      publish_all(c)
      sync([ordered, shuffled])

      # Presence frames depend on registration timing, not scopes.
      assert Enum.reject(events(:ordered), &match?({"presence", _}, &1)) ==
               Enum.reject(events(:shuffled), &match?({"presence", _}, &1))
    end
  end

  describe "sessions.events replay" do
    setup c do
      original = Application.get_env(:lemon_core, :agent_runtime_provider)
      original_runtime = Application.get_env(:lemon_control_plane, Runtime)

      entry = %{
        cursor: cursor(1),
        event_id: "scope-stream:1",
        events: [
          delta(c, @prose <> " " <> @secret),
          run_started(c),
          approval_requested(c),
          goal_verdict(c)
        ]
      }

      Application.put_env(
        :lemon_control_plane,
        Runtime,
        {:ok, %{events: [entry], cursor: cursor(1), has_more: false}}
      )

      :ok = Application.put_env(:lemon_core, :agent_runtime_provider, Runtime)

      on_exit(fn ->
        restore_env(:lemon_core, :agent_runtime_provider, original)
        restore_env(:lemon_control_plane, Runtime, original_runtime)
      end)

      :ok
    end

    test "read-only callers receive metadata-only entries", c do
      assert {:ok, %{"entries" => [entry]} = result} =
               Registry.dispatch("sessions.events", params(c), ctx([:read]))

      encoded = dump(result)
      refute encoded =~ @prose
      refute encoded =~ @secret
      assert entry["cursor"] == cursor(1)
      assert entry["eventId"] == "scope-stream:1"

      assert [
               %{"event" => "agent", "payload" => %{"type" => "started"}},
               %{"event" => "goal", "payload" => %{"loopVerdict" => verdict}}
             ] = entry["events"]

      # An unknown (here confidential) stored source is omitted, not forwarded.
      assert verdict == %{"action" => "done", "atMs" => 5}
    end

    test "content callers receive the text; approvals stay gated", c do
      assert {:ok, %{"entries" => [entry]}} =
               Registry.dispatch("sessions.events", params(c), ctx([:read, :content]))

      assert dump(entry) =~ @prose
      assert Enum.any?(entry["events"], &match?(%{"event" => "chat"}, &1))

      assert Enum.any?(
               entry["events"],
               &match?(
                 %{"event" => "goal", "payload" => %{"loopVerdict" => %{"reason" => _}}},
                 &1
               )
             )

      refute Enum.any?(entry["events"], &match?(%{"event" => "exec.approval." <> _}, &1))

      assert {:ok, %{"entries" => [full]}} =
               Registry.dispatch("sessions.events", params(c), ctx(@full))

      assert Enum.any?(full["events"], &match?(%{"event" => "exec.approval.requested"}, &1))
    end

    test "connection requests use the current connection scopes, not the request context", c do
      conn_id = "scope-replay-#{System.unique_integer([:positive])}"
      auth = %{role: :operator, scopes: [:read]}
      :ok = Connections.register(conn_id, %{role: :operator, auth: auth, pid: self()})

      stale = Map.merge(ctx(@full), %{conn_id: conn_id, conn_pid: self()})

      assert {:ok, %{"entries" => [entry]} = result} =
               Registry.dispatch("sessions.events", params(c), stale)

      refute dump(result) =~ @prose
      assert [%{"event" => "agent"}, %{"event" => "goal"}] = entry["events"]
    end
  end

  describe "goal loop verdicts" do
    test "read-only recipients get the verdict action, never the judge's reason", c do
      alias LemonAgent.Workspace.GoalStore

      read = connect(:read_only, [:read])
      full = connect(:full, @full)

      assert {:ok, _} =
               GoalStore.set(c.session_key, "Close the deal: #{@prose}",
                 authority: LemonAgent.Workspace.GoalAuthority.operator()
               )

      on_exit(fn -> GoalStore.clear(c.session_key) end)

      assert {:ok, _} =
               GoalStore.record_loop_verdict(c.session_key, %{
                 action: "continue",
                 reason: "Objective says #{@prose}; key #{@secret}",
                 source: "judge"
               })

      sync_bridge()
      sync([read, full])

      full_verdicts = for {"goal", %{"type" => "goal_loop_verdict"} = p} <- events(:full), do: p
      read_events = events(:read_only)
      read_verdicts = for {"goal", %{"type" => "goal_loop_verdict"} = p} <- read_events, do: p

      assert [%{"loopVerdict" => %{"reason" => reason}} = full_verdict] = full_verdicts
      assert reason =~ @prose and reason =~ @secret

      assert [%{"loopVerdict" => verdict} = read_verdict] = read_verdicts
      refute dump(read_events) =~ @prose
      refute dump(read_events) =~ @secret
      assert verdict["action"] == "continue"
      assert verdict["source"] == "judge"
      assert is_integer(verdict["atMs"])
      refute Map.has_key?(verdict, "reason")
      assert read_verdict["goalId"] == full_verdict["goalId"]

      # The same projection applies inside a nested session batch.
      batch = %{
        "sessionKey" => c.session_key,
        "eventId" => "scope-stream:9",
        "cursor" => cursor(9),
        "events" => [%{"event" => "goal", "payload" => full_verdict}]
      }

      assert {"session.event", %{"events" => [%{"payload" => nested}]}} =
               EventBridge.authorize_event("session.event", batch, [:read])

      assert nested["loopVerdict"] == verdict

      # Sources outside the known provenance enum (e.g. a stored model-written
      # value) are omitted; `judge:<model>` collapses to `judge`.
      assert {:ok, _} =
               GoalStore.record_loop_verdict(c.session_key, %{
                 action: "blocked",
                 reason: "waiting",
                 source: "#{@secret} #{@prose}"
               })

      sync_bridge()
      sync([read, full])

      assert [%{"loopVerdict" => blocked}] =
               for({"goal", %{"type" => "goal_loop_verdict"} = p} <- events(:read_only), do: p)

      assert blocked["action"] == "blocked"
      refute Map.has_key?(blocked, "source")
      refute dump(blocked) =~ @secret

      assert [%{"loopVerdict" => %{"source" => full_source}}] =
               for({"goal", %{"type" => "goal_loop_verdict"} = p} <- events(:full), do: p)

      assert full_source =~ @secret

      model_sourced = put_in(full_verdict, ["loopVerdict", "source"], "judge:judge-model")

      assert {"goal", %{"loopVerdict" => %{"source" => "judge"}}} =
               EventBridge.authorize_event("goal", model_sourced, [:read])
    end
  end

  describe "authorize_event/3" do
    test "read-only recipients get the metrics envelope without its free-form payload" do
      {"metrics", projected} =
        EventBridge.project(
          Event.new(:metrics, %{note: @prose, gauge: 3}, %{target: "run:metrics-run"})
        )

      assert {"metrics", read} = EventBridge.authorize_event("metrics", projected, [:read])
      refute Map.has_key?(read, "payload")
      assert read["runId"] == "metrics-run"
      assert is_integer(read["timestampMs"])
      refute inspect(read) =~ @prose

      assert {"metrics", ^projected} =
               EventBridge.authorize_event("metrics", projected, [:read, :content])

      assert projected["payload"]["note"] == @prose
    end
  end

  # Publishes real Bus events on the topics the bridge subscribes to.
  defp publish_all(c) do
    EventBridge.subscribe_run(c.run_id)
    sync_bridge()
    run_topic = "run:#{c.run_id}"

    Bus.broadcast(run_topic, delta(c, @prose <> " " <> @secret))

    Bus.broadcast(
      run_topic,
      Event.new(
        :run_completed,
        %{completed: %{ok: true, answer: "Answer: #{@prose} #{@secret}"}, duration_ms: 12},
        meta(c)
      )
    )

    Bus.broadcast(
      run_topic,
      Event.new(
        :engine_action,
        %{
          action: %{
            id: "tool-1",
            kind: "command",
            title: "echo #{@secret}",
            detail: %{command: "echo '#{@prose}'"}
          },
          phase: :completed,
          ok: true,
          message: "printed #{@prose}"
        },
        meta(c)
      )
    )

    Bus.broadcast("exec_approvals", approval_requested(c))

    Bus.broadcast(
      "exec_approvals",
      Event.new(
        :approval_resolved,
        %{
          approval_id: "scope-approval",
          decision: :approve_once,
          pending: %{
            id: "scope-approval",
            run_id: c.run_id,
            session_key: c.session_key,
            agent_id: "default",
            tool: "bash"
          }
        },
        %{}
      )
    )

    Bus.broadcast(
      "nodes",
      Event.new(:node_pair_requested, %{pairing_id: "pair-1", code: "PAIR-CODE"}, %{})
    )

    Bus.broadcast(
      "session_events",
      Event.new(
        :session_event,
        %{
          cursor: cursor(7),
          event_id: "scope-stream:7",
          events: [delta(c, "#{@prose} #{@secret}"), run_started(c), approval_requested(c)]
        },
        %{session_key: c.session_key}
      )
    )

    sync_bridge()
    EventBridge.unsubscribe_run(c.run_id)
  end

  defp delta(c, text),
    do: Event.new(:delta, %LemonCore.Events.Delta{run_id: c.run_id, text: text, seq: 1}, meta(c))

  defp run_started(c),
    do: Event.new(:run_started, %{run_id: c.run_id, session_key: c.session_key}, meta(c))

  # The shape `GoalStore.record_loop_verdict/3` publishes: the judge's free-text
  # `reason` beside its enumerated action.
  defp goal_verdict(c) do
    Event.new(
      :goal_loop_verdict,
      %LemonCore.Events.GoalChanged{
        goal_id: "goal-scope",
        session_key: c.session_key,
        status: "active",
        objective_bytes: 42,
        loop_status: "running",
        loop_verdict: %{
          "action" => "done",
          "reason" => "The judge read #{@prose} and #{@secret}",
          "source" => "#{@secret} #{@prose}",
          "atMs" => 5
        }
      },
      meta(c)
    )
  end

  defp approval_requested(c) do
    Event.new(
      :approval_requested,
      %{
        pending: %{
          id: "scope-approval",
          run_id: c.run_id,
          session_key: c.session_key,
          tool: "bash",
          action: %{command: "echo #{@secret}"},
          rationale: "needs #{@prose}"
        }
      },
      %{}
    )
  end

  defp meta(c), do: %{run_id: c.run_id, session_key: c.session_key}

  defp cursor(seq),
    do: %{
      "version" => 1,
      "sessionId" => "scope-owner",
      "streamId" => "scope-stream",
      "seq" => seq
    }

  defp params(c), do: %{"sessionKey" => c.session_key, "cursor" => cursor(0)}
  defp ctx(scopes), do: %{auth: %{role: :operator, scopes: scopes}}

  # Registers a fake WebSocket connection whose events are forwarded, labelled,
  # to the test process.
  defp connect(label, auth) do
    parent = self()
    collector = spawn_link(fn -> collect(parent, label) end)

    auth =
      case auth do
        nil -> nil
        scopes when is_list(scopes) -> %{role: :operator, scopes: scopes}
        map -> map
      end

    info = %{role: :operator, client_id: Atom.to_string(label), pid: collector}
    info = if auth, do: Map.put(info, :auth, auth), else: info
    :ok = Connections.register("scope-#{label}-#{System.unique_integer([:positive])}", info)
    collector
  end

  defp collect(parent, label) do
    receive do
      {:event, name, payload, _version} ->
        send(parent, {:scope_event, label, name, payload})
        collect(parent, label)

      {:barrier, ref} ->
        send(parent, {:barrier, ref, self()})
        collect(parent, label)

      _other ->
        collect(parent, label)
    end
  end

  defp sync(collectors) do
    for collector <- collectors do
      ref = make_ref()
      send(collector, {:barrier, ref})
      assert_receive {:barrier, ^ref, ^collector}, 1_000
    end
  end

  defp events(label), do: drain(label, [])

  defp drain(label, acc) do
    receive do
      {:scope_event, ^label, name, payload} -> drain(label, [{name, payload} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp sync_bridge, do: :sys.get_state(EventBridge)

  defp dump(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp clear_connections do
    if Process.whereis(Connections) do
      for {conn_id, _} <- Connections.list(), do: Connections.unregister(conn_id)
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
