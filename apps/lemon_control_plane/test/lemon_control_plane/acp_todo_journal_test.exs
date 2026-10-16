defmodule LemonControlPlane.ACP.TodoJournalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager}
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Tools.{TodoStore, TodoWrite}
  alias LemonControlPlane.ACP
  alias LemonCore.Store
  alias LemonAi.Types.{Model, ModelCost}

  @tag :tmp_dir
  test "load, resume and fork publish the selected journal plan, not replayed tool plans", %{
    tmp_dir: cwd
  } do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    :ok = LemonCore.AgentRuntime.register(ControlPlaneProvider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    assert {:ok, created} = ACP.new_session(%{"cwd" => cwd})
    id = created["sessionId"]
    session = Store.get(:acp_sessions, id)
    # ACP owns its session identity; create the native journal through the
    # supported /plan lifecycle rather than the canonical-key creation RPC.
    for _ <- 1..2 do
      assert {:ok, %{"stopReason" => "end_turn"}} =
               ACP.prompt(%{
                 "sessionId" => id,
                 "prompt" => [%{"type" => "text", "text" => "/plan"}]
               })
    end

    native_id = LemonCore.ChatStateStore.get(session.session_key).last_resume_token
    path = SessionManager.session_file_path(cwd, native_id)
    assert {:ok, manager} = SessionManager.load_from_file(path)
    manager = SessionManager.append_message(manager, %{"role" => "user", "content" => "Start"})
    :ok = SessionManager.save_to_file(path, manager)
    target = manager.leaf_id

    on_exit(fn ->
      Store.delete(:acp_sessions, id)
      LemonCore.ChatStateStore.delete(session.session_key)
      LemonCore.RunStore.delete_session(session.session_key)
      TodoStore.delete(native_id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    pid =
      start_supervised!(
        {Session,
         cwd: cwd,
         workspace_dir: Path.join(cwd, "workspace"),
         session_file: path,
         session_key: session.session_key,
         model: fixture_model(),
         tools: []}
      )

    Session.subscribe(pid)
    refute_receive {:session_event, _, {:todos_changed, []}}

    first = write(pid, "Selected")
    assert_receive {:session_event, _, {:todos_changed, selected_todos}}

    {updates, projection} =
      LemonControlPlane.ACP.SessionUpdates.map_event(
        LemonControlPlane.ACP.SessionUpdates.new(id),
        {:todos_changed, selected_todos}
      )

    assert plans(updates) == [entries(first)]
    first_leaf = Session.get_state(pid).session_manager.leaf_id
    abandoned = write(pid, "Abandoned")
    assert_receive {:session_event, _, {:todos_changed, abandoned_todos}}

    {_updates, projection} =
      LemonControlPlane.ACP.SessionUpdates.map_event(
        projection,
        {:todos_changed, abandoned_todos}
      )

    assert :ok = Session.navigate_tree(pid, first_leaf, summarize_abandoned: false)
    assert_receive {:session_event, _, {:todos_changed, ^selected_todos}}

    {updates, projection} =
      LemonControlPlane.ACP.SessionUpdates.map_event(projection, {:todos_changed, selected_todos})

    assert plans(updates) == [entries(first)]

    {late_updates, _projection} =
      LemonControlPlane.ACP.SessionUpdates.map_event(
        projection,
        {:tool_execution_end, "late", "todo", abandoned, false}
      )

    assert plans(late_updates) == []
    manager = Session.get_state(pid).session_manager
    stop_supervised!(Session)

    # A historical read receipt can carry stale branch-global cache data. It is
    # still a transcript receipt, but must never govern the client plan.
    manager =
      SessionManager.append_message(manager, %{
        "role" => "tool_result",
        "tool_call_id" => "stale_read",
        "tool_name" => "todoread",
        "content" => [],
        "details" => abandoned.details,
        "is_error" => false
      })

    :ok = SessionManager.save_to_file(path, manager)
    TodoStore.delete(native_id)

    for method <- ["session/load", "session/resume"] do
      updates = invoke(method, %{"sessionId" => id, "cwd" => cwd})
      assert plans(updates) == [entries(first)]
    end

    fork_updates = invoke("session/fork", %{"sessionId" => id, "cwd" => cwd})
    {:ok, %{"sessions" => sessions}} = ACP.list_sessions(%{"cwd" => cwd})
    assert plans(fork_updates) == [entries(first)]
    child = Enum.find(sessions, &(&1["sessionId"] != id))
    child_id = child["sessionId"]
    child_session = Store.get(:acp_sessions, child_id)

    on_exit(fn ->
      Store.delete(:acp_sessions, child_id)
      LemonCore.ChatStateStore.delete(child_session.session_key)
      LemonCore.RunStore.delete_session(child_session.session_key)
    end)

    assert {:ok, preview} =
             ControlPlaneProvider.session_rewind(session.session_key, cwd, target, [])

    assert {:ok, _} =
             ControlPlaneProvider.session_rewind(session.session_key, cwd, target,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert plans(invoke("session/load", %{"sessionId" => id, "cwd" => cwd})) == [[]]

    assert plans(invoke("session/load", %{"sessionId" => child_id, "cwd" => cwd})) == [
             entries(first)
           ]

    assert {:ok, manager} = SessionManager.load_from_file(path)

    manager =
      SessionManager.append_entry(
        manager,
        SessionEntry.custom("lemon.todo", %{
          "version" => 999,
          "todos" => []
        })
      )

    :ok = SessionManager.save_to_file(path, manager)
    updates = invoke("session/load", %{"sessionId" => id, "cwd" => cwd})
    assert plans(updates) == []
    assert_unavailable(updates)
  end

  @tag :tmp_dir
  test "pristine subscriptions and unchanged writes are silent but real clears remain visible",
       %{tmp_dir: cwd} do
    alias CodingAgent.Executor.SessionRunner.Emitter
    alias CodingAgent.Session.RunTranslator
    alias LemonControlPlane.ACP.SessionUpdates

    pid =
      start_supervised!(
        {Session,
         cwd: cwd, workspace_dir: Path.join(cwd, "workspace"), model: fixture_model(), tools: []}
      )

    id = Session.get_state(pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    Session.subscribe(pid)
    refute_receive {:session_event, ^id, _}
    assert {:ok, stream} = Session.subscribe(pid, mode: :stream)
    assert LemonAgent.EventStream.stats(stream).queue_size == 0
    LemonAgent.EventStream.cancel(stream, :test_complete)

    assert {:ok, [], revision} = Session.todos(pid)
    assert {:ok, [], _} = Session.write_todos(pid, [], revision)
    refute_receive {:session_event, ^id, {:todos_changed, _}}

    # An explicitly journaled empty plan still initializes a new projection.
    Session.subscribe(pid)
    assert_receive {:session_event, ^id, {:todos_changed, []} = initial}
    {updates, _} = SessionUpdates.map_event(SessionUpdates.new(id), initial)
    assert plans(updates) == [[]]

    run_ref = make_ref()

    translator =
      RunTranslator.new(
        emitter: Emitter,
        emitter_state: %Emitter{sink_pid: self(), run_ref: run_ref, session: pid},
        engine: "lemon",
        label: "Todo projection",
        session_id: id,
        cwd: cwd
      )
      |> RunTranslator.handle_event(initial)

    refute_receive {:engine_event, ^run_ref, _}

    write(pid, "Plan before start")
    assert_receive {:session_event, ^id, {:todos_changed, todos} = changed}
    translator = RunTranslator.handle_event(translator, changed)
    assert_receive {:engine_event, ^run_ref, %{action: %{detail: %{todos: ^todos}}}}

    assert {:ok, ^todos, revision} = Session.todos(pid)
    assert {:ok, ^todos, _} = Session.write_todos(pid, todos, revision)
    same_plan_leaf = Session.get_state(pid).session_manager.leaf_id
    assert :ok = Session.navigate_tree(pid, same_plan_leaf, summarize_abandoned: false)
    refute_receive {:session_event, ^id, {:todos_changed, _}}

    # A real pre-start clear is visible, unlike the initial snapshot.
    assert {:ok, ^todos, revision} = Session.todos(pid)
    assert {:ok, [], _} = Session.write_todos(pid, [], revision)
    assert_receive {:session_event, ^id, {:todos_changed, []} = cleared}
    translator = RunTranslator.handle_event(translator, cleared)
    assert_receive {:engine_event, ^run_ref, %{action: %{detail: %{todos: []}}, ok: true}}

    translator = RunTranslator.handle_event(translator, {:agent_start})
    assert_receive {:engine_event, ^run_ref, %{__event__: :started}}
    write(pid, "Plan after start")
    assert_receive {:session_event, ^id, {:todos_changed, _} = changed}
    translator = RunTranslator.handle_event(translator, changed)
    assert_receive {:engine_event, ^run_ref, %{action: %{detail: %{type: :todos_changed}}}}
    assert {:ok, [_todo], revision} = Session.todos(pid)
    assert {:ok, [], _} = Session.write_todos(pid, [], revision)
    assert_receive {:session_event, ^id, {:todos_changed, []} = cleared}
    RunTranslator.handle_event(translator, cleared)
    assert_receive {:engine_event, ^run_ref, %{action: %{detail: %{todos: []}}, ok: true}}

    assert {:ok, [], revision} = Session.todos(pid)
    assert {:ok, [], _} = Session.write_todos(pid, [], revision)
    refute_receive {:session_event, ^id, {:todos_changed, _}}
  end

  @tag :tmp_dir
  test "unreadable live branches warn without clearing the last journal plan through native and bus consumers",
       %{tmp_dir: cwd} do
    alias CodingAgent.Executor.SessionRunner.Emitter
    alias CodingAgent.Session.RunTranslator
    alias CodingAgent.SessionManager.SessionEntry
    alias LemonControlPlane.ACP.SessionUpdates

    known = [
      %{"id" => "known", "content" => "Known", "status" => "pending", "priority" => "high"}
    ]

    for {name, bad_data} <- [
          {"future", %{"version" => 999, "todos" => []}},
          {"unreadable", %{"version" => 1, "todos" => ["invalid"]}}
        ] do
      manager =
        SessionManager.new(cwd)
        |> SessionManager.append_entry(
          SessionEntry.custom("lemon.todo", %{"version" => 1, "todos" => known})
        )

      good_leaf = manager.leaf_id
      manager = SessionManager.append_entry(manager, SessionEntry.custom("lemon.todo", bad_data))
      bad_leaf = manager.leaf_id
      path = Path.join(cwd, name <> ".jsonl")
      :ok = SessionManager.save_to_file(path, manager)

      pid =
        start_supervised!(
          {Session,
           cwd: cwd,
           workspace_dir: Path.join(cwd, "workspace"),
           session_file: path,
           model: fixture_model(),
           tools: []}
        )

      on_exit(fn -> TodoStore.delete(manager.header.id) end)
      Session.subscribe(pid)
      assert_receive {:session_event, _, {:todos_unavailable, :unsupported_todo_entry} = initial}
      {updates, projection} = SessionUpdates.map_event(SessionUpdates.new(name), initial)
      assert plans(updates) == []
      assert_unavailable(updates)

      assert :ok = Session.navigate_tree(pid, good_leaf, summarize_abandoned: false)
      assert_receive {:session_event, _, {:todos_changed, ^known} = known_event}
      {known_updates, projection} = SessionUpdates.map_event(projection, known_event)
      assert [known_plan] = plans(known_updates)

      assert :ok = Session.navigate_tree(pid, bad_leaf, summarize_abandoned: false)
      assert_receive {:session_event, _, {:todos_unavailable, :unsupported_todo_entry} = event}
      refute_receive {:session_event, _, {:todos_changed, []}}
      assert {:error, {:unsupported_todo_entry, _}, _} = Session.todos(pid)

      {updates, projection} = SessionUpdates.map_event(projection, event)
      assert plans(updates) == []
      assert_unavailable(updates)

      # Exercise the real translator/emitter before JSON encoding bus payloads.
      run_ref = make_ref()

      translator =
        RunTranslator.new(
          emitter: Emitter,
          emitter_state: %Emitter{
            sink_pid: self(),
            run_ref: run_ref,
            session: pid
          },
          engine: "lemon",
          label: "Todo projection",
          cwd: cwd
        )

      RunTranslator.handle_event(translator, event)
      assert_receive {:engine_event, ^run_ref, %{ok: false} = payload}
      wire_event = Jason.decode!(Jason.encode!(%{type: :engine_action, payload: payload}))
      {updates, projection} = SessionUpdates.map_event(projection, wire_event)
      assert plans(updates) == []
      assert_unavailable(updates)

      # Receipts and non-journal hints cannot fabricate an available plan.
      for stale <- [
            {:tool_execution_end, "late", "todo", %{details: %{todos: [], plan: %{entries: []}}},
             false},
            {:todo_reminder, []},
            {:todo_auto_clear},
            %{"type" => "todo_reminder", "todos" => []},
            %{"type" => "todo_auto_clear"}
          ] do
        {updates, _} = SessionUpdates.map_event(projection, stale)
        assert plans(updates) == []
      end

      assert :ok = Session.navigate_tree(pid, good_leaf, summarize_abandoned: false)
      assert_receive {:session_event, _, {:todos_changed, ^known} = restored}
      {updates, projection} = SessionUpdates.map_event(projection, restored)
      assert plans(updates) == [known_plan]

      assert {:ok, ^known, revision} = Session.todos(pid)
      assert {:ok, [], _} = Session.write_todos(pid, [], revision)
      assert_receive {:session_event, _, {:todos_changed, []} = cleared}
      {updates, _} = SessionUpdates.map_event(projection, cleared)
      assert plans(updates) == [[]]
      stop_supervised!(Session)
    end
  end

  defp assert_unavailable(updates) do
    assert Enum.any?(updates, fn
             %{
               "params" => %{
                 "update" => %{
                   "sessionUpdate" => "notice",
                   "severity" => "warning",
                   "title" => "The session todo plan is unavailable."
                 }
               }
             } ->
               true

             _ ->
               false
           end)
  end

  @tag :tmp_dir
  test "new direct and stream subscriptions receive only their own journal snapshot", %{
    tmp_dir: cwd
  } do
    pid =
      start_supervised!(
        {Session,
         cwd: cwd, workspace_dir: Path.join(cwd, "workspace"), model: fixture_model(), tools: []}
      )

    id = Session.get_state(pid).session_manager.header.id

    on_exit(fn ->
      TodoStore.delete(id)
      File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
    end)

    Session.subscribe(pid)
    refute_receive {:session_event, ^id, {:todos_changed, []}}
    write(pid, "Selected")
    assert_receive {:session_event, ^id, {:todos_changed, todos}}
    owner = self()

    subscriber =
      spawn_link(fn ->
        unsubscribe = Session.subscribe(pid)

        receive do
          event -> send(owner, {:initial_direct, event})
        end

        receive do
          :stop -> unsubscribe.()
        end
      end)

    assert_receive {:initial_direct, {:session_event, ^id, {:todos_changed, ^todos}}}
    refute_receive {:session_event, ^id, {:todos_changed, _}}
    send(subscriber, :stop)

    assert {:ok, stream} = Session.subscribe(pid, mode: :stream)

    assert Enum.take(LemonAgent.EventStream.events(stream), 1) == [
             {:session_event, id, {:todos_changed, todos}}
           ]

    refute_receive {:session_event, ^id, {:todos_changed, _}}
    LemonAgent.EventStream.cancel(stream, :test_complete)
  end

  defp fixture_model do
    %Model{
      id: "todo-journal-projection",
      name: "Todo journal projection",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4_096
    }
  end

  defp write(pid, content) do
    assert %LemonAgent.Types.AgentToolResult{} =
             result =
             TodoWrite.execute("write", %{"todos" => [%{"content" => content}]}, nil, nil, pid)

    result
  end

  defp entries(result) do
    Enum.map(result.details.plan.entries, fn entry ->
      Map.new(entry, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp plans(updates) do
    for %{"params" => %{"update" => %{"sessionUpdate" => "plan", "entries" => entries}}} <-
          updates,
        do: entries
  end

  defp invoke(method, params) do
    ref = make_ref()
    owner = self()

    assert {:ok, %{"result" => _}} =
             ACP.handle_jsonrpc(
               %{"jsonrpc" => "2.0", "id" => "todo", "method" => method, "params" => params},
               session_update_callback: &send(owner, {ref, &1})
             )

    collect(ref, [])
  end

  defp collect(ref, updates) do
    receive do
      {^ref, update} -> collect(ref, [update | updates])
    after
      0 -> Enum.reverse(updates)
    end
  end
end
