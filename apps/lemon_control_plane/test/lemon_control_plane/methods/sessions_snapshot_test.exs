Code.require_file(Path.expand("../../../../lemon_agent/test/support/mocks.ex", __DIR__))

defmodule LemonControlPlane.Methods.SessionsSnapshotTest do
  use ExUnit.Case, async: false

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Methods.{Registry, SessionsSnapshot}
  alias LemonCore.{AgentRuntime, ExecApprovalStore, RunStore, Store}

  # Fault injection lives at the existing runtime seam. Real run/approval owners
  # remain authoritative; barriers replace sleeps and synchronize the lost-event
  # window before a second collection.
  defmodule MissingRuntime do
    @behaviour LemonCore.AgentRuntime.Provider
  end

  defmodule Runtime do
    @behaviour LemonCore.AgentRuntime.Provider

    def session_recovery_snapshot(_key, _cwd) do
      pid = Application.fetch_env!(:lemon_control_plane, __MODULE__)

      state =
        Agent.get_and_update(pid, fn state ->
          next = Map.update!(state, :reads, &(&1 + 1))
          {next, next}
        end)

      if state[:barrier] == state.reads do
        send(state.observer, {:snapshot_barrier, state.reads, self()})

        receive do
          {:release_snapshot, count} when count == state.reads -> :ok
        after
          5_000 -> raise "snapshot barrier was not released"
        end
      end

      state.native_result
    end

    def list_tasks, do: state().tasks

    def session_process_receipts(owner) do
      send(state().observer, {:process_owner, owner})
      state().processes
    end

    def session_todos(_key, _cwd), do: state().todos
    defp state, do: Agent.get(Application.fetch_env!(:lemon_control_plane, __MODULE__), & &1)
  end

  setup do
    original = Application.get_env(:lemon_core, :agent_runtime_provider)
    original_runtime = Application.get_env(:lemon_control_plane, Runtime)
    key = "agent:snapshot_#{System.unique_integer([:positive])}:main"
    id = "run_#{System.unique_integer([:positive])}"
    native = native(id)
    observer = self()

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{
             native_result: {:ok, native},
             reads: 0,
             observer: observer,
             tasks: [],
             processes: {:ok, []},
             todos: {:ok, [], {0, nil}}
           }
         end}
      )

    Application.put_env(:lemon_control_plane, Runtime, state)
    :ok = AgentRuntime.register(Runtime)
    :ok = RunStore.create_session_index(key, LemonCore.SessionKey.agent_id(key), :tui)
    if Process.whereis(Registry) == nil, do: start_supervised!(Registry)

    on_exit(fn ->
      if original,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, original),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)

      if original_runtime,
        do: Application.put_env(:lemon_control_plane, Runtime, original_runtime),
        else: Application.delete_env(:lemon_control_plane, Runtime)

      Store.delete(:runs, id)
      RunStore.delete_session_index(key)
      RunStore.delete_history(key)

      ExecApprovalStore.list_pending()
      |> Enum.each(fn {approval_id, p} ->
        if p[:session_key] == key, do: ExecApprovalStore.delete_pending(approval_id)
      end)
    end)

    %{key: key, id: id, native: native, state: state}
  end

  test "fresh native owners recover before a finalized lifecycle index without borrowing another owner",
       c do
    alias CodingAgent.Tools.Task.Params

    :ok = RunStore.delete_session_index(c.key)
    dir = Path.join(System.tmp_dir!(), "snapshot-fresh-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)

    # Force the historical direct-key lookup to encounter a delegated session.
    # Task children share the routing key but own a distinct invocation/journal.
    child_opts =
      Params.build_session_opts(
        dir,
        [session_key: c.key, child_run_id: "child-#{c.id}"],
        %{}
      )
      |> Keyword.put(:session_id, c.key)
      |> Keyword.put(:tools, [])

    child =
      start_supervised!(
        Supervisor.child_spec({CodingAgent.Session, child_opts}, id: :same_key_child)
      )

    child_owner = CodingAgent.Session.get_state(child).session_manager.header.id

    pid =
      start_supervised!(
        {CodingAgent.Session,
         CodingAgent.Session.Presentation.build_session_opts(
           [],
           dir,
           c.id,
           c.key,
           LemonCore.SessionKey.agent_id(c.key)
         )}
      )

    assert {:ok, nil} = LemonCore.SessionLifecycle.fetch(c.key)
    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())
    assert result["status"] == "ok"
    assert result["identity"]["sessionKey"] == c.key

    assert result["identity"]["sessionId"] ==
             CodingAgent.Session.get_state(pid).session_manager.header.id

    refute result["identity"]["sessionId"] == child_owner

    foreign = "agent:snapshot_foreign_#{System.unique_integer([:positive])}:main"

    assert {:error, {:not_found, _, _}} =
             SessionsSnapshot.handle(%{"sessionKey" => foreign, "cwd" => dir}, ctx())
  end

  @tag :tmp_dir
  test "real task approval retains child invocation and is visible in its root snapshot", c do
    alias CodingAgent.Session.Presentation
    alias LemonAgent.Test.Mocks

    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)
    :ok = LemonCore.Bus.subscribe("exec_approvals")
    on_exit(fn -> LemonCore.Bus.unsubscribe("exec_approvals") end)
    File.write!(Path.join(c.tmp_dir, "child.txt"), "child-owned read")

    stream =
      Mocks.mock_stream_fn([
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("task", %{
            "prompt" => "Read child.txt",
            "description" => "approval child",
            "tool_policy" => %{"allow" => ["read"], "require_approval" => ["read"]},
            "async" => false,
            "auto_followup" => false
          })
        ]),
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("read", %{"path" => "child.txt"})
        ]),
        Mocks.assistant_message("Child read completed"),
        Mocks.assistant_message("Root completed")
      ])

    policy = CodingAgent.ToolPolicy.custom(allow: ["task", "read"], require_approval: ["read"])

    opts =
      Presentation.build_session_opts(
        [tool_policy: policy, stream_fn: stream, model: Mocks.mock_model()],
        c.tmp_dir,
        c.id,
        c.key,
        LemonCore.SessionKey.agent_id(c.key)
      )
      |> Keyword.put(:settings_manager, %CodingAgent.SettingsManager{compaction_enabled: false})

    on_exit(fn ->
      CodingAgent.TaskStore.list(:all)
      |> Enum.each(fn {id, task} ->
        if task[:session_key] == c.key, do: CodingAgent.TaskStore.delete_task(id)
      end)
    end)

    root = start_supervised!({CodingAgent.Session, opts})
    root_owner = CodingAgent.Session.get_state(root).session_manager.header.id
    unsubscribe = CodingAgent.Session.subscribe(root)
    on_exit(fn -> if Process.alive?(root), do: unsubscribe.() end)
    assert :ok = CodingAgent.Session.prompt(root, "Delegate the read")

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{approval_id: approval_id, pending: pending}
                   },
                   5_000

    assert pending.session_key == c.key
    assert is_binary(pending.run_id)
    refute pending.run_id == c.id
    refute pending.session_id == root_owner

    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx([:read, :approvals]))
    assert result["identity"]["sessionId"] == root_owner
    assert result["identity"]["runId"] == c.id

    assert [%{"id" => ^approval_id, "runId" => child_run}] =
             result["snapshot"]["approvals"]["items"]

    assert child_run == pending.run_id

    assert {:ok, %{approval_id: ^approval_id, outcome: :approved}} =
             LemonCore.ExecApprovals.resolve(approval_id, :approve_once)

    assert_receive {:session_event, ^root_owner, {:agent_end, messages}}, 5_000
    answer = messages |> Enum.filter(&match?(%{role: :assistant}, &1)) |> List.last()
    assert LemonAi.get_text(answer) == "Root completed"
  end

  @tag :tmp_dir
  test "two live root owners are unavailable rather than choosing registration order", c do
    alias CodingAgent.Session.Presentation

    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)

    for id <- [:first_root, :second_root] do
      opts =
        Presentation.build_session_opts(
          [tools: []],
          c.tmp_dir,
          "#{c.id}-#{id}",
          c.key,
          LemonCore.SessionKey.agent_id(c.key)
        )

      start_supervised!(Supervisor.child_spec({CodingAgent.Session, opts}, id: id))
    end

    assert {:error, :unavailable} =
             CodingAgent.ControlPlaneProvider.session_recovery_snapshot(c.key, c.tmp_dir)
  end

  test "approval recovery admits only active descendants of the selected native root", c do
    records =
      for {name, parent, owner, status} <- [
            {"child", c.id, "native-owner", :running},
            {"nested", "child-#{c.id}", "child-native", :running},
            {"foreign", c.id, "foreign-native", :running},
            {"unrelated", "older-root", "native-owner", :running},
            {"finished", c.id, "native-owner", :completed}
          ] do
        run_id = "#{name}-#{c.id}"

        task_id =
          CodingAgent.TaskStore.new_task(%{
            session_key: c.key,
            parent_session_id: owner,
            run_id: run_id,
            parent_run_id: parent
          })

        :ok = CodingAgent.TaskStore.mark_running(task_id)
        if status == :completed, do: CodingAgent.TaskStore.finish(task_id, "finished")
        pending = %{approval(c, name) | run_id: run_id, session_id: "#{name}-native"}
        :ok = ExecApprovalStore.put_pending(pending.id, pending)
        task_id
      end

    on_exit(fn -> Enum.each(records, &CodingAgent.TaskStore.delete_task/1) end)
    tasks = CodingAgent.TaskStore.list(:all) |> Enum.filter(fn {id, _} -> id in records end)
    Agent.update(c.state, &%{&1 | tasks: tasks})
    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx([:read, :approvals]))
    assert Enum.map(result["snapshot"]["approvals"]["items"], & &1["id"]) == ["child", "nested"]

    Agent.update(c.state, &%{&1 | tasks: :unavailable})
    assert {:ok, unavailable} = SessionsSnapshot.handle(params(c), ctx([:read, :approvals]))
    assert unavailable["snapshot"]["approvals"] == %{"status" => "unavailable"}
  end

  test "only read-authorized operators can collect native owner recovery", c do
    assert {:error, _} =
             Registry.dispatch("sessions.snapshot", params(c), %{
               auth: Authorize.node_context("foreign")
             })

    assert {:error, _} =
             SessionsSnapshot.handle(params(c), %{auth: %{role: :node, scopes: [:read]}})

    assert {:error, _} =
             SessionsSnapshot.handle(params(c), %{auth: %{role: :operator, scopes: [:write]}})

    assert Agent.get(c.state, & &1.reads) == 0

    assert {:error, {:invalid_params, _, _}} =
             SessionsSnapshot.handle(Map.put(params(c), "limit", 101), ctx())

    assert {:error, {:invalid_params, _, _}} =
             SessionsSnapshot.handle(
               Map.put(params(c), "expectedIdentity", %{"revision" => "old"}),
               ctx()
             )

    assert {:ok, result} = Registry.dispatch("sessions.snapshot", params(c), ctx())
    assert result["snapshot"]["approvals"] == %{"status" => "forbidden"}
    assert result["consistency"]["atomic"] == false
    assert result["consistency"]["eventCursor"] == nil
  end

  test "dropped tool progress converges once to real terminal output, not a running action", c do
    assert {:ok, before} = SessionsSnapshot.handle(params(c), ctx())
    assert before["snapshot"]["phase"] == "running"
    assert [%{"phase" => "started"}] = before["snapshot"]["actions"]
    # No transient progress is replayed. Only the owner's terminal event/summary
    # is published while the client is disconnected.
    :ok =
      RunStore.append_event(c.id, %{
        phase: :completed,
        ok: true,
        action: %{
          id: "tool_call",
          kind: :tool,
          title: "bash",
          detail: %{tool_call_id: "call", name: "bash", result_full: "ACTUAL RESULT"}
        }
      })

    finalize(c, %{ok: true, answer: "Canonical answer"})

    Agent.update(c.state, fn state ->
      %{state | native_result: {:ok, %{c.native | streaming: false, revision: "terminal"}}}
    end)

    assert {:ok, recovered} = SessionsSnapshot.handle(params(c), ctx())
    assert recovered["snapshot"]["phase"] == "completed"
    assert recovered["snapshot"]["terminal"]

    assert recovered["snapshot"]["answer"] == %{
             "text" => "Canonical answer",
             "canonical" => true,
             "truncated" => false
           }

    assert [%{"phase" => "completed", "content" => "ACTUAL RESULT", "toolCallId" => "call"}] =
             recovered["snapshot"]["actions"]

    assert {:ok, ^recovered} = SessionsSnapshot.handle(params(c), ctx())

    assert Enum.all?(
             Enum.filter(recovered["snapshot"]["messages"], &(&1["role"] == "assistant")),
             &(&1["runId"] == c.id)
           )

    assert {:ok, %{"status" => "retry", "reason" => "identity_changed"} = stale} =
             SessionsSnapshot.handle(
               Map.put(params(c), "expectedIdentity", before["identity"]),
               ctx()
             )

    refute Map.has_key?(stale, "snapshot")
  end

  test "terminal continuation proves full journal ancestry across leaf/revision and retained attempt changes",
       c do
    ancestor = %{type: :custom, id: "old-leaf", custom_type: "smoke", data: %{}}
    live = %{c.native | branch_id: ancestor.id, entries: c.native.entries ++ [ancestor]}
    live = Map.put(live, :attempt, "opaque-live-attempt")
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, live}))
    assert {:ok, before} = SessionsSnapshot.handle(params(c), ctx())

    request =
      params(c)
      |> Map.put("limit", 1)
      |> Map.put("continuationFrom", %{"identity" => before["identity"], "runId" => c.id})

    assert {:ok, %{"continuation" => false}} = SessionsSnapshot.handle(request, ctx())
    finalize(c, %{ok: true, answer: "Canonical continuation"})

    terminal =
      live
      |> Map.delete(:attempt)
      |> Map.merge(%{
        streaming: false,
        live: false,
        run_id: nil,
        branch_id: "terminal-leaf",
        revision: "terminal-revision",
        entries:
          live.entries ++
            [
              %{
                type: :message,
                id: "terminal-leaf",
                message: %{
                  role: :assistant,
                  content: [%{type: :text, text: "Canonical continuation"}]
                }
              }
            ]
      })

    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, terminal}))

    assert {:ok, result} = SessionsSnapshot.handle(request, ctx())
    assert result["continuation"]
    assert result["identity"]["attempt"] == c.id
    assert result["identity"]["branchId"] != before["identity"]["branchId"]
    assert result["identity"]["revision"] != before["identity"]["revision"]
    refute Enum.any?(result["snapshot"]["messages"], &(&1["id"] == ancestor.id))
    assert {:ok, ^result} = SessionsSnapshot.handle(request, ctx())

    # A new acknowledged run can follow an older accepted snapshot without a
    # running snapshot of its own. Its fixed ID, owner and ancestry still bind it.
    previous = put_in(before, ["identity", "runId"], "previous-run")
    newer = put_in(request, ["continuationFrom", "identity"], previous["identity"])
    assert {:ok, %{"continuation" => true}} = SessionsSnapshot.handle(newer, ctx())

    # expectedIdentity keeps its original retry semantics even with a proof request.
    assert {:ok, %{"status" => "retry", "reason" => "identity_changed"}} =
             SessionsSnapshot.handle(
               Map.put(request, "expectedIdentity", before["identity"]),
               ctx()
             )
  end

  test "continuation refuses other owners, runs, live attempts and non-descendant branches", c do
    live = %{c.native | branch_id: "assistant"} |> Map.put(:attempt, "live-attempt")
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, live}))
    assert {:ok, before} = SessionsSnapshot.handle(params(c), ctx())
    finalize(c, %{ok: true, answer: "Terminal"})
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, %{live | streaming: false}}))
    proof = %{"identity" => before["identity"], "runId" => c.id}

    assert {:ok, %{"continuation" => true}} =
             SessionsSnapshot.handle(Map.put(params(c), "continuationFrom", proof), ctx())

    invalid = [
      put_in(proof, ["identity", "sessionKey"], "foreign-key"),
      put_in(proof, ["identity", "sessionId"], "replacement-owner"),
      put_in(proof, ["identity", "branchId"], "abandoned-leaf"),
      put_in(proof, ["identity", "attempt"], "other-live-attempt"),
      put_in(proof, ["identity", "attempt"], nil),
      Map.put(proof, "runId", "unacknowledged-run")
    ]

    for candidate <- invalid do
      assert {:ok, %{"continuation" => false}} =
               SessionsSnapshot.handle(Map.put(params(c), "continuationFrom", candidate), ctx())
    end

    for candidate <- [%{}, %{"identity" => nil, "runId" => c.id}, Map.put(proof, "extra", true)] do
      assert {:error, {:invalid_params, _, _}} =
               SessionsSnapshot.handle(Map.put(params(c), "continuationFrom", candidate), ctx())
    end

    unknown = %{live | streaming: false} |> Map.delete(:attempt)
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, unknown}))

    assert {:ok, %{"continuation" => false}} =
             SessionsSnapshot.handle(Map.put(params(c), "continuationFrom", proof), ctx())

    retained = %{unknown | live: false}
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, retained}))
    missing_attempt = put_in(proof, ["identity", "attempt"], nil)

    assert {:ok, %{"continuation" => false}} =
             SessionsSnapshot.handle(
               Map.put(params(c), "continuationFrom", missing_attempt),
               ctx()
             )
  end

  test "approval decided between owner reads yields retry then never reappears", c do
    approval = approval(c, "pending")
    :ok = ExecApprovalStore.put_pending(approval.id, approval)
    Agent.update(c.state, &Map.put(&1, :barrier, 2))
    request = Task.async(fn -> SessionsSnapshot.handle(params(c), ctx([:read, :approvals])) end)
    assert_receive {:snapshot_barrier, 2, reader}, 5_000

    assert {:ok, %{decision: :deny}} =
             LemonCore.ExecApprovals.resolve(approval.id, :deny, expected_pending: approval)

    send(reader, {:release_snapshot, 2})

    assert {:ok, %{"status" => "retry", "reason" => "snapshot_raced"} = raced} =
             Task.await(request)

    refute Map.has_key?(raced, "snapshot")
    assert {:ok, current} = SessionsSnapshot.handle(params(c), ctx([:read, :approvals]))

    assert current["snapshot"]["approvals"] == %{
             "status" => "ok",
             "items" => [],
             "truncated" => false
           }
  end

  test "run completion racing the native read cannot expose a mixed stable snapshot", c do
    Agent.update(c.state, &Map.put(&1, :barrier, 1))
    request = Task.async(fn -> SessionsSnapshot.handle(params(c), ctx()) end)
    assert_receive {:snapshot_barrier, 1, reader}, 5_000
    finalize(c, %{ok: true, answer: "Finished while disconnected"})

    Agent.update(
      c.state,
      &Map.put(&1, :native_result, {:ok, %{c.native | streaming: false, revision: "done"}})
    )

    send(reader, {:release_snapshot, 1})
    assert {:ok, %{"status" => "retry", "reason" => "snapshot_raced"}} = Task.await(request)
    assert {:ok, stable} = SessionsSnapshot.handle(params(c), ctx())
    assert stable["snapshot"]["terminal"]
  end

  test "exact owner filtering keeps foreign children and approvals out and process lost stays unknown",
       c do
    attrs = %{
      session_key: c.key,
      parent_session_id: "native-owner",
      run_id: "child-fixed",
      parent_run_id: c.id
    }

    child = CodingAgent.TaskStore.new_task(attrs)
    foreign = CodingAgent.TaskStore.new_task(%{attrs | parent_session_id: "foreign"})

    :ok =
      CodingAgent.TaskStore.finish(child, %{answer: "Visible child result", thinking: "hidden"})

    :ok = CodingAgent.TaskStore.finish(foreign, "FOREIGN SECRET")

    on_exit(fn ->
      CodingAgent.TaskStore.delete_task(child)
      CodingAgent.TaskStore.delete_task(foreign)
    end)

    tasks =
      CodingAgent.TaskStore.list(:all) |> Enum.filter(fn {id, _} -> id in [child, foreign] end)

    Agent.update(c.state, fn state ->
      %{
        state
        | tasks: tasks,
          processes:
            {:ok,
             [
               %{
                 identity: "proc-fixed",
                 classification: :outcome_unknown,
                 reason: :tracking_lost,
                 status: :lost,
                 command: "PRIVATE COMMAND"
               }
             ]}
      }
    end)

    pending = approval(c, "mine")
    :ok = ExecApprovalStore.put_pending(pending.id, pending)

    :ok =
      ExecApprovalStore.put_pending("foreign-#{c.id}", %{
        pending
        | id: "foreign-#{c.id}",
          session_key: "foreign"
      })

    on_exit(fn -> ExecApprovalStore.delete_pending("foreign-#{c.id}") end)
    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx([:read, :approvals]))
    assert_receive {:process_owner, "native-owner"}

    assert [%{"taskId" => ^child, "terminal" => true, "answer" => "Visible child result"}] =
             result["snapshot"]["children"]["items"]

    assert [
             %{
               "identity" => "proc-fixed",
               "classification" => "outcome_unknown",
               "status" => "lost"
             }
           ] = result["snapshot"]["processes"]["items"]

    assert [%{"id" => "mine"}] = result["snapshot"]["approvals"]["items"]
    encoded = Jason.encode!(result)
    refute encoded =~ "FOREIGN SECRET"
    refute encoded =~ "PRIVATE COMMAND"
    refute encoded =~ "hidden"
  end

  test "missing owner callbacks and owner failures remain unavailable, not empty", c do
    Agent.update(
      c.state,
      &%{
        &1
        | tasks: :unavailable,
          processes: {:error, :unavailable},
          todos: {:error, :unsupported_version}
      }
    )

    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())

    for domain <- ["children", "processes", "todos"] do
      assert result["snapshot"][domain] == %{"status" => "unavailable"}
    end

    Agent.update(c.state, &%{&1 | native_result: {:error, :unavailable}})
    assert {:error, {:unavailable, _, nil}} = SessionsSnapshot.handle(params(c), ctx())
    :ok = AgentRuntime.register(MissingRuntime)
    assert {:error, {:unavailable, _, nil}} = SessionsSnapshot.handle(params(c), ctx())
  end

  test "cancellation metadata and structured reasons retain authoritative terminal semantics",
       c do
    for {index, completed} <-
          Enum.with_index([
            %{ok: false, answer: "Interrupted", error: %{type: :cancelled}},
            %{ok: false, answer: "Interrupted", error: :worker_stopped, meta: %{cancelled: true}}
          ])
          |> Enum.map(fn {completed, index} -> {index, completed} end) do
      id = "#{c.id}-cancel-#{index}"
      RunStore.finalize(id, %{session_key: c.key, prompt: "Run tool", completed: completed})

      Agent.update(
        c.state,
        &Map.put(&1, :native_result, {:ok, %{c.native | run_id: id, streaming: false}})
      )

      assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())
      assert result["snapshot"]["phase"] == "cancelled"
      assert result["snapshot"]["terminal"]
      refute Enum.any?(result["snapshot"]["actions"], &(&1["phase"] == "started"))
      Store.delete(:runs, id)
    end
  end

  test "response has shared byte limits and redacts credentials without changing owners", c do
    secret = "sk-" <> String.duplicate("a", 48)
    huge = "api_key=#{secret} " <> String.duplicate("界", 100_000)

    entries =
      for index <- 1..120 do
        %{
          type: :message,
          id: "message-#{index}",
          message: %{role: :assistant, content: [%{type: :text, text: huge}]}
        }
      end

    plan = %{"mode" => "plan", "path" => "/PRIVATE/PLAN", "content" => huge}

    Agent.update(
      c.state,
      &%{
        &1
        | native_result: {:ok, %{c.native | entries: entries, plan: plan}},
          todos: {:ok, [%{id: "todo", content: huge, api_key: secret}], {2, "todo-entry"}}
      }
    )

    assert {:ok, result} = SessionsSnapshot.handle(Map.put(params(c), "limit", 100), ctx())
    encoded = Jason.encode!(result)
    assert byte_size(encoded) <= 131_072
    refute encoded =~ secret
    refute encoded =~ "/PRIVATE/PLAN"
    assert result["snapshot"]["messagesTruncated"]
    assert result["snapshot"]["plan"]["value"]["truncated"]
    assert Agent.get(c.state, fn state -> elem(state.native_result, 1).entries end) == entries
  end

  test "selected branch revision replaces todo and plan state and rejects stale identities", c do
    assert {:ok, old} = SessionsSnapshot.handle(params(c), ctx())

    branch = %{
      c.native
      | branch_id: "rewound-leaf",
        revision: "rewound-revision",
        plan: %{"mode" => "plan", "path" => nil, "content" => nil}
    }

    Agent.update(
      c.state,
      &%{
        &1
        | native_result: {:ok, branch},
          todos:
            {:ok,
             [
               %{
                 "id" => "current",
                 "content" => "Current branch",
                 "status" => "pending",
                 "priority" => "high",
                 "metadata" => %{"private" => "ABANDONED"}
               }
             ], {3, "rewound-todo"}}
      }
    )

    assert {:ok, %{"status" => "retry", "reason" => "identity_changed"}} =
             SessionsSnapshot.handle(
               Map.put(params(c), "expectedIdentity", old["identity"]),
               ctx()
             )

    assert {:ok, recovered} = SessionsSnapshot.handle(params(c), ctx())
    assert recovered["identity"]["branchId"] == "rewound-leaf"
    assert recovered["identity"]["revision"] != old["identity"]["revision"]
    assert recovered["snapshot"]["plan"]["value"]["mode"] == "plan"
    assert [%{"id" => "current"} = todo] = recovered["snapshot"]["todos"]["items"]
    refute Map.has_key?(todo, "metadata")
    refute Jason.encode!(recovered) =~ "ABANDONED"
  end

  test "a new active user turn has no answer-so-far from an earlier assistant turn", c do
    entries = [
      %{type: :message, id: "previous-user", message: %{role: :user, content: "Previous prompt"}},
      %{
        type: :message,
        id: "previous-answer",
        message: %{role: :assistant, content: "PREVIOUS ANSWER"}
      },
      hd(c.native.entries)
    ]

    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, %{c.native | entries: entries}}))
    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())
    assert result["snapshot"]["phase"] == "running"

    assert result["snapshot"]["answer"] == %{
             "text" => "",
             "canonical" => false,
             "truncated" => false
           }

    assert Enum.any?(result["snapshot"]["messages"], &(&1["content"] == "PREVIOUS ANSWER"))
  end

  test "an idle live owner's stale invocation ID cannot restore an abandoned branch answer", c do
    finalize(c, %{ok: true, answer: "ABANDONED ANSWER"})

    selected = %{
      c.native
      | streaming: false,
        branch_id: "rewound",
        revision: "rewound",
        entries: [
          %{
            type: :message,
            id: "selected-user",
            message: %{
              role: :user,
              content: "Different selected prompt",
              timestamp: 1_800_000_000_000
            }
          }
        ]
    }

    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, selected}))
    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())
    assert result["identity"]["runId"] == nil
    assert result["snapshot"]["phase"] == "unknown"
    refute result["snapshot"]["terminal"]
    refute Jason.encode!(result) =~ "ABANDONED ANSWER"
  end

  test "a new active attempt cannot revive an unfinished action from a previous turn", c do
    previous = [
      %{type: :message, id: "old-user", message: %{role: :user, content: "Previous turn"}},
      %{
        type: :message,
        id: "old-call",
        message: %{
          role: :assistant,
          content: [%{type: :tool_call, id: "obsolete-call", name: "bash", arguments: %{}}]
        }
      }
    ]

    Agent.update(
      c.state,
      &Map.put(&1, :native_result, {:ok, %{c.native | entries: previous ++ c.native.entries}})
    )

    assert {:ok, result} = SessionsSnapshot.handle(params(c), ctx())
    actions = Map.new(result["snapshot"]["actions"], &{&1["toolCallId"], &1})
    assert actions["call"]["phase"] == "started"
    assert actions["call"]["runId"] == c.id
    assert actions["obsolete-call"]["phase"] == "unknown"
    refute actions["obsolete-call"]["runId"] == c.id
  end

  test "same-run replaced native attempt invalidates the previous snapshot", c do
    first_native = Map.put(c.native, :attempt, "execution-instance-one")
    Agent.update(c.state, &Map.put(&1, :native_result, {:ok, first_native}))
    assert {:ok, first} = SessionsSnapshot.handle(params(c), ctx())

    Agent.update(
      c.state,
      &Map.put(
        &1,
        :native_result,
        {:ok, Map.put(first_native, :attempt, "execution-instance-two")}
      )
    )

    assert {:ok, %{"status" => "retry", "identity" => identity, "reason" => "identity_changed"}} =
             SessionsSnapshot.handle(
               Map.put(params(c), "expectedIdentity", first["identity"]),
               ctx()
             )

    assert identity["runId"] == first["identity"]["runId"]
    assert identity["attempt"] != first["identity"]["attempt"]
  end

  @tag :tmp_dir
  test "owner-written user bindings recover repeated prompts across rewind despite late start receipts",
       %{tmp_dir: cwd} = c do
    alias CodingAgent.Session.Persistence
    alias CodingAgent.SessionManager
    second_id = "run_#{System.unique_integer([:positive])}"
    invalid_id = "run_#{System.unique_integer([:positive])}"
    manager = SessionManager.new(cwd)
    state = %{session_manager: manager, run_id: c.id, session_key: c.key}

    first =
      Persistence.persist_message(state, %LemonAi.Types.UserMessage{
        role: :user,
        content: "Run tool",
        timestamp: 1_700_000_000_000
      })

    first =
      SessionManager.append_message(first.session_manager, %{
        role: :assistant,
        content: [%{type: :text, text: "FIRST OWNED ANSWER"}]
      })

    first_leaf = first.leaf_id
    finalize(c, %{ok: true, answer: "FIRST OWNED ANSWER"})

    second =
      Persistence.persist_message(
        %{state | session_manager: first, run_id: second_id},
        %LemonAi.Types.UserMessage{role: :user, content: "Run tool", timestamp: 1_700_000_000_100}
      )

    second =
      SessionManager.append_message(second.session_manager, %{
        role: :assistant,
        content: [%{type: :text, text: "SECOND OWNED ANSWER"}]
      })

    :ok =
      RunStore.finalize(second_id, %{
        session_key: c.key,
        prompt: "Run tool",
        completed: %{ok: true, answer: "SECOND OWNED ANSWER"}
      })

    path = SessionManager.session_file_path(cwd, manager.header.id)
    :ok = SessionManager.save_to_file(path, second)

    :ok =
      LemonCore.ChatStateStore.put(c.key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: manager.header.id
      })

    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(c.key)
      Store.delete(:runs, second_id)
      Store.delete(:runs, invalid_id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    target = Map.put(params(c), "cwd", cwd)
    assert {:ok, latest} = SessionsSnapshot.handle(target, ctx())
    assert latest["identity"]["runId"] == second_id
    assert latest["snapshot"]["phase"] == "completed"
    assert latest["snapshot"]["answer"]["text"] == "SECOND OWNED ANSWER"
    rewound = SessionManager.set_leaf_id(%{second | file_path: path}, first_leaf)
    assert {:ok, selected} = SessionsSnapshot.handle(target, ctx())
    assert selected["identity"]["runId"] == c.id
    assert selected["snapshot"]["answer"]["text"] == "FIRST OWNED ANSWER"
    # A declared malformed binding cannot fall back to old timing/prompt matches.
    :ok =
      RunStore.finalize(invalid_id, %{
        session_key: c.key,
        prompt: "Legacy match",
        completed: %{ok: true, answer: "MUST NOT RECYCLE"}
      })

    {:ok, invalid_run} = RunStore.fetch(invalid_id)

    malformed =
      SessionManager.append_message(rewound, %{
        "role" => "user",
        "content" => "Legacy match",
        "timestamp" => invalid_run.started_at,
        "lemonRun" => nil
      })

    :ok = SessionManager.save_to_file(path, malformed)
    assert {:ok, unknown} = SessionsSnapshot.handle(target, ctx())
    assert unknown["identity"]["runId"] == nil
    assert unknown["snapshot"]["phase"] == "unknown"
    refute unknown["snapshot"]["answer"]["canonical"]
  end

  @tag :tmp_dir
  test "offline journal rewind is the authority, and a foreign native header is denied",
       %{tmp_dir: cwd} = c do
    alias CodingAgent.SessionManager
    alias CodingAgent.SessionManager.SessionEntry

    session =
      SessionManager.new(cwd)
      |> SessionManager.append_message(%{role: :user, content: "Selected branch"})
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.plan", %{"mode" => "plan", "path" => nil})
      )
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.todo", %{
          "version" => 1,
          "todos" => [
            %{
              "id" => "selected",
              "content" => "Selected todo",
              "status" => "pending",
              "priority" => "medium"
            }
          ]
        })
      )

    selected = session.leaf_id

    abandoned =
      session
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.plan", %{"mode" => "code", "path" => nil})
      )
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.todo", %{
          "version" => 1,
          "todos" => [
            %{
              "id" => "abandoned",
              "content" => "ABANDONED TODO",
              "status" => "completed",
              "priority" => "low"
            }
          ]
        })
      )
      |> SessionManager.append_message(%{
        role: :assistant,
        content: [%{type: :text, text: "ABANDONED ANSWER"}]
      })

    path = SessionManager.session_file_path(cwd, session.header.id)
    :ok = SessionManager.save_to_file(path, abandoned)

    :ok =
      LemonCore.ChatStateStore.put(c.key, %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: session.header.id
      })

    :ok = AgentRuntime.register(CodingAgent.ControlPlaneProvider)
    target = Map.put(params(c), "cwd", cwd)

    on_exit(fn ->
      LemonCore.ChatStateStore.delete(c.key)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    assert {:ok, old} = SessionsSnapshot.handle(target, ctx())
    assert old["snapshot"]["plan"]["value"]["mode"] == "code"
    # Persistence writes the selected leaf checkpoint. No live Session process
    # or client-local branch store exists to mask an offline rewind.
    rewound = SessionManager.set_leaf_id(%{abandoned | file_path: path}, selected)
    assert rewound.leaf_id == selected

    assert {:ok, %{"status" => "retry", "reason" => "identity_changed"}} =
             SessionsSnapshot.handle(Map.put(target, "expectedIdentity", old["identity"]), ctx())

    assert {:ok, current} = SessionsSnapshot.handle(target, ctx())
    # Before #102's optional owner callback is centrally integrated, report the
    # missing projection truthfully. Once installed, this same real journal
    # asserts selected-branch materialization rather than an ETS fallback.
    case current["snapshot"]["todos"] do
      %{"status" => "ok", "items" => [%{"id" => "selected"}]} ->
        :ok

      %{"status" => "unavailable"} ->
        refute function_exported?(CodingAgent.ControlPlaneProvider, :session_todos, 2)
    end

    assert current["identity"]["branchId"] == selected
    assert current["snapshot"]["plan"]["value"]["mode"] == "plan"
    refute Jason.encode!(current) =~ "ABANDONED ANSWER"

    foreign =
      SessionManager.new(cwd, id: "foreign-native")
      |> SessionManager.append_message(%{role: :user, content: "FOREIGN TRANSCRIPT"})

    :ok = SessionManager.save_to_file(path, foreign)
    assert {:error, {:unavailable, _, nil}} = SessionsSnapshot.handle(target, ctx())
  end

  defp native(id) do
    %{
      session_id: "native-owner",
      branch_id: "branch-leaf",
      revision: "native-revision",
      run_id: id,
      cwd: "/workspace",
      streaming: true,
      live: true,
      failed: false,
      partial: nil,
      pending: ["call"],
      plan: %{"mode" => "code", "path" => nil, "content" => nil},
      entries: [
        %{
          type: :message,
          id: "user",
          message: %{role: :user, content: "Run tool", timestamp: 1_800_000_000_000}
        },
        %{
          type: :message,
          id: "assistant",
          message: %{
            role: :assistant,
            content: [%{type: :tool_call, id: "call", name: "bash", arguments: %{}}]
          }
        }
      ]
    }
  end

  defp params(c), do: %{"sessionKey" => c.key}
  defp ctx(scopes \\ [:read]), do: %{auth: %{role: :operator, scopes: scopes}}

  defp finalize(c, completed),
    do: RunStore.finalize(c.id, %{session_key: c.key, prompt: "Run tool", completed: completed})

  defp approval(c, id),
    do: %{
      id: id,
      run_id: c.id,
      session_id: "native-owner",
      session_key: c.key,
      agent_id: LemonCore.SessionKey.agent_id(c.key),
      tool: "bash",
      action: %{command_hash: "hash", cwd_hash: "hash"},
      requested_at_ms: 1,
      expires_at_ms: nil
    }
end
