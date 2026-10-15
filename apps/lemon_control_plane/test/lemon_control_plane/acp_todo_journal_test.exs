defmodule LemonControlPlane.ACP.TodoJournalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager}
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
