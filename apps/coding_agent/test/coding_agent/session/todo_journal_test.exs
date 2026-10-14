defmodule CodingAgent.Session.TodoJournalTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager, ToolPolicy}
  alias CodingAgent.Session.{BudgetLedger, Planning, Todos}
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Tools.{Todo, TodoStore, TodoStoreOwner}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, ToolCall, Usage}

  @moduletag :tmp_dir

  test "real loop writes survive rewind, both preserved branches, save and process restart", %{
    tmp_dir: root
  } do
    pending = pending()
    completed = Enum.map(pending, &Map.put(&1, "status", "completed"))
    external = Path.join(root, "external.txt")

    stream =
      scripted([
        response([call("a", "todo", %{"action" => "write", "todos" => pending})]),
        response("A"),
        response([
          call("b", "todo", %{"action" => "write", "todos" => completed}),
          call("effect", "write", %{"path" => external, "content" => "effect"})
        ]),
        response("B")
      ])

    session = start_session(root, stream_fn: stream)
    prompt(session, "A")
    a = leaf(session)
    original = view(session, "read").details.todos
    assert Enum.map(original, & &1["status"]) == ["pending", "pending"]
    prompt(session, "B")
    b = leaf(session)
    done = view(session, "read").details.todos
    assert Enum.map(done, & &1["id"]) == Enum.map(original, & &1["id"])
    assert Enum.map(done, & &1["status"]) == ["completed", "completed"]
    assert File.read!(external) == "effect"

    writes = Session.get_state(session).session_manager |> SessionManager.entries()
    assert Enum.count(writes, &(&1.custom_type == "lemon.todo")) == 2

    assert Enum.all?(
             Enum.filter(Session.get_messages(session), &(Map.get(&1, :role) == :tool_result)),
             &(not &1.is_error)
           )

    user_b =
      writes
      |> Enum.filter(&(&1.type == :message and &1.message["role"] == "user"))
      |> List.last()

    spent = Session.get_state(session).budget_usage
    assert spent.tokens > 0
    File.write!(external, "changed after the effect")

    rewind(session, user_b.id)
    assert leaf(session) == a
    assert view(session, "read").details.todos == original
    assert Session.get_state(session).budget_usage == spent
    assert File.read!(external) == "changed after the effect"

    alternate =
      write(session, Enum.map(original, &Map.put(&1, "status", "in_progress"))).details.todos

    c = leaf(session)

    for {branch, expected} <- [{b, done}, {c, alternate}, {a, original}] do
      navigate(session, branch)
      assert_views(session, expected)
      assert Session.get_state(session).budget_usage == spent
      assert File.read!(external) == "changed after the effect"
    end

    assert :ok = Session.save(session)
    path = Session.get_state(session).session_file
    assert {:ok, saved} = SessionManager.load_from_file(path)
    assert {{:ok, ^original}, _} = Todos.materialize(saved)
    assert SessionManager.get_entry(saved, b)
    assert SessionManager.get_entry(saved, c)
    GenServer.stop(session)
    TodoStore.clear()
    resumed = start_session(root, session_file: path)
    assert_views(resumed, original)
    assert Session.get_state(resumed).budget_usage == spent
    navigate(resumed, b)
    assert_views(resumed, done)
    navigate(resumed, c)
    assert_views(resumed, alternate)
    assert File.read!(external) == "changed after the effect"
  end

  test "selected-point fork inherits IDs and all spend but isolates child writes and subagents",
       %{
         tmp_dir: root
       } do
    parent = start_session(root, stream_fn: scripted([response("charged")]))
    original = write(parent, pending()).details.todos
    a = leaf(parent)
    prompt(parent, "charge the parent")
    done = write(parent, Enum.map(original, &Map.put(&1, "status", "completed"))).details.todos
    state = Session.get_state(parent)
    path = Path.join(root, "fork.jsonl")
    assert {:ok, fork} = SessionManager.fork_file(state.session_file, path, leaf_id: a)
    assert fork.header.parent_session == state.session_manager.header.id
    assert BudgetLedger.restore(fork) == state.budget_usage
    child = start_session(root, session_file: path)
    assert_views(child, original)
    assert Session.get_state(child).budget_usage == state.budget_usage
    changed = write(child, [%{hd(original) | "content" => "child only"}]).details.todos
    assert_views(parent, done)
    write(parent, [])
    assert_views(child, changed)

    subagent =
      start_session(root,
        parent_session: state.session_manager.header.id,
        session_scope: :subagent
      )

    assert_views(subagent, [])

    assert Session.get_state(subagent).session_manager.header.parent_session ==
             state.session_manager.header.id
  end

  test "clearing and restarting the ETS owner cannot resurrect an abandoned branch", %{
    tmp_dir: root
  } do
    session = start_session(root)
    original = write(session, pending()).details.todos
    a = leaf(session)
    done = write(session, Enum.map(original, &Map.put(&1, "status", "completed"))).details.todos
    b = leaf(session)
    navigate(session, a)
    id = Session.get_state(session).session_manager.header.id
    TodoStore.put(id, done)
    assert_views(session, original)
    TodoStore.clear()
    assert_views(session, original)

    assert :ok = Supervisor.terminate_child(CodingAgent.Supervisor, TodoStoreOwner)
    assert {:ok, _} = Supervisor.restart_child(CodingAgent.Supervisor, TodoStoreOwner)
    assert TodoStore.get(id) == []
    assert_views(session, original)
    assert TodoStore.get(id) == original
    navigate(session, b)
    assert_views(session, done)
  end

  test "planning mode, approved context and complete plan projections follow the same branch", %{
    tmp_dir: root
  } do
    session =
      start_session(root,
        approval_context: %{approval_request_fun: fn _ -> {:ok, :approved, :once} end}
      )

    original = write(session, pending()).details.todos
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    planning = leaf(session)

    assert %AgentToolResult{is_error: true} =
             tool(session, "todo").execute.(
               "blocked-write",
               %{"action" => "write", "todos" => []},
               nil,
               nil
             )

    assert {:ok, ^original, _} = Session.todos(session)
    prompt(session, "Review the plan")

    user =
      Session.get_state(session).session_manager
      |> SessionManager.entries()
      |> Enum.find(&(&1.type == :message and &1.message["role"] == "user"))

    path =
      Path.join(Planning.plan_dir(Session.get_state(session).session_manager), "todo-plan.md")

    assert %AgentToolResult{is_error: false} =
             tool(session, "write").execute.(
               "draft",
               %{"path" => path, "content" => "# Approved todo work"},
               nil,
               nil
             )

    assert %AgentToolResult{is_error: false} =
             tool(session, "propose_plan").execute.(
               "approve",
               %{"path" => path, "title" => "Todo work"},
               nil,
               nil
             )

    done = write(session, Enum.map(original, &Map.put(&1, "status", "completed"))).details.todos
    approved = leaf(session)
    rewind(session, user.id)
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session)
    refute Session.get_state(session).system_prompt =~ "## Approved plan"
    assert_views(session, original)

    for {branch, mode, expected} <- [{planning, "plan", original}, {approved, "code", done}] do
      navigate(session, branch)
      assert {:ok, %{"mode" => ^mode}} = Session.plan(session)
      state = Session.get_state(session)
      assert :atomics.get(state.plan_gate, 1) == if(mode == "plan", do: 1, else: 0)
      assert String.contains?(state.system_prompt, "## Approved plan") == (mode == "code")
      assert_views(session, expected)
    end

    path = Session.get_state(session).session_file
    fork_path = Path.join(root, "planning-fork.jsonl")
    assert {:ok, _} = SessionManager.fork_file(path, fork_path, leaf_id: planning)
    child = start_session(root, session_file: fork_path)
    assert {:ok, %{"mode" => "plan"}} = Session.plan(child)
    assert_views(child, original)
    refute Session.get_state(child).system_prompt =~ "## Approved plan"
    assert {:ok, %{"mode" => "code"}} = Session.plan(child, :exit)
    refute Session.get_state(child).system_prompt =~ "## Approved plan"
    assert_views(session, done)
    GenServer.stop(session)
    resumed = start_session(root, session_file: path)
    assert {:ok, %{"mode" => "code"}} = Session.plan(resumed)
    assert Session.get_state(resumed).system_prompt =~ "# Approved todo work"
    assert_views(resumed, done)
  end

  test "journal append failure reports failure and leaves both journal and cache unchanged", %{
    tmp_dir: root
  } do
    session = start_session(root)
    original = write(session, pending()).details.todos
    before = Session.get_state(session)
    blocked = Path.join(root, "not-a-file")
    File.mkdir_p!(blocked)

    :sys.replace_state(session, fn state ->
      %{state | session_manager: %{state.session_manager | file_path: blocked}}
    end)

    assert {:error, _} = execute(session, %{"action" => "write", "todos" => []})
    after_failure = Session.get_state(session)
    assert after_failure.session_manager.by_id == before.session_manager.by_id
    assert after_failure.session_manager.leaf_id == before.session_manager.leaf_id
    assert TodoStore.get(before.session_manager.header.id) == original
    assert_views(session, original)
    assert {:ok, saved} = SessionManager.load_from_file(before.session_file)
    assert {{:ok, ^original}, _} = Todos.materialize(saved)

    :sys.replace_state(session, fn state ->
      %{state | session_manager: %{state.session_manager | file_path: before.session_file}}
    end)
  end

  test "superseded lists and even switch-away-and-back invalidate prepared writes", %{
    tmp_dir: root
  } do
    session = start_session(root)
    Session.subscribe(session)
    original = write(session, pending()).details.todos
    assert_receive {:session_event, _, {:todos_changed, ^original}}
    a = leaf(session)
    assert {:ok, ^original, old} = Session.todos(session)
    done = write(session, Enum.map(original, &Map.put(&1, "status", "completed"))).details.todos
    assert_receive {:session_event, _, {:todos_changed, ^done}}
    assert {:error, :stale_revision} = Session.write_todos(session, original, old)
    assert_views(session, done)
    navigate(session, a)
    assert_receive {:session_event, _, {:todos_changed, ^original}}
    assert {:ok, ^original, prepared} = Session.todos(session)
    navigate(session, leaf_id_of_latest_todo(session))
    navigate(session, a)
    before = Session.get_state(session).session_manager
    assert {:error, :stale_revision} = Session.write_todos(session, done, prepared)
    assert Session.get_state(session).session_manager.by_id == before.by_id
    assert_views(session, original)
  end

  test "restoration reapplies current restricted policy instead of historical authority", %{
    tmp_dir: root
  } do
    session = start_session(root)
    original = write(session, pending()).details.todos
    a = leaf(session)
    write(session, [])
    path = Session.get_state(session).session_file
    GenServer.stop(session)
    policy = ToolPolicy.custom(allow: ["todo"])
    resumed = start_session(root, session_file: path, tool_policy: policy)
    navigate(resumed, a)
    assert_views(resumed, original)
    refute Enum.any?(Session.get_state(resumed).tools, &(&1.name == "write"))
    assert Session.get_state(resumed).tool_policy == policy
    prompt(resumed, "no authority restored")
    refute Enum.any?(Session.get_state(resumed).tools, &(&1.name == "write"))
  end

  test "legacy fallback uses only successful writes on the selected branch, never reads or cache",
       %{tmp_dir: root} do
    manager =
      SessionManager.new(root)
      |> SessionManager.append_entry(SessionEntry.custom("legacy-root", %{}))

    empty = manager.leaf_id

    legacy = [
      %{
        "id" => "legacy-id",
        "content" => "Legacy",
        "status" => "pending",
        "priority" => "high",
        "metadata" => %{"origin" => "old"}
      }
    ]

    manager = legacy_result(manager, "old-write", "todo", %{"action" => "write"}, legacy, false)
    a = manager.leaf_id
    leaked = Enum.map(legacy, &Map.put(&1, "status", "completed"))
    manager = legacy_result(manager, "read", "todo", %{"action" => "read"}, leaked, false)
    manager = legacy_result(manager, "progress", "todo", %{"action" => "progress"}, leaked, false)
    manager = legacy_result(manager, "failed", "todowrite", %{}, leaked, true)
    read_leaf = manager.leaf_id
    manager = legacy_result(manager, "new-write", "todowrite", %{}, leaked, false)
    b = manager.leaf_id
    path = Path.join(root, "legacy.jsonl")
    assert :ok = SessionManager.save_to_file(path, manager)
    bytes = File.read!(path)
    assert {:ok, loaded} = SessionManager.load_from_file(path)
    assert {{:ok, ^leaked}, nil} = Todos.materialize(loaded)
    assert File.read!(path) == bytes
    TodoStore.put(manager.header.id, leaked)
    session = start_session(root, session_file: path)

    for {branch, expected} <- [{empty, []}, {a, legacy}, {read_leaf, legacy}, {b, leaked}] do
      navigate(session, branch)
      assert_views(session, expected)
    end

    assert Enum.all?(manager.by_id, fn {id, entry} ->
             Session.get_state(session).session_manager.by_id[id] == entry
           end)
  end

  test "unknown and unreadable journal versions govern their branch without legacy fallback", %{
    tmp_dir: root
  } do
    legacy = [
      %{"id" => "legacy-id", "content" => "Legacy", "status" => "pending", "priority" => "medium"}
    ]

    entries = [
      {"future", %{"version" => 999, "todos" => legacy}},
      {"broken", %{"version" => 1, "todos" => ["not a todo"]}},
      {"missing-id", %{"version" => 1, "todos" => [%{"content" => "fabricated"}]}}
    ]

    for {name, data} <- entries do
      manager = legacy_result(SessionManager.new(root), "legacy", "todowrite", %{}, legacy, false)
      manager = SessionManager.append_entry(manager, SessionEntry.custom("lemon.todo", data))
      bad = manager.leaf_id
      path = Path.join(root, name <> ".jsonl")
      assert :ok = SessionManager.save_to_file(path, manager)
      session = start_session(root, session_file: path)
      assert {:error, {:unsupported_todo_entry, _}, revision} = Session.todos(session)
      assert elem(revision, 1) == bad

      for action <- ["read", "progress", "actionable"],
          do: assert({:error, _} = execute(session, %{"action" => action}))

      replacement = write(session, [%{"content" => "Replacement"}]).details.todos
      assert_views(session, replacement)
      navigate(session, bad)
      assert {:error, {:unsupported_todo_entry, _}, _} = Session.todos(session)
      assert Session.get_state(session).session_manager.by_id[bad].data == data
      GenServer.stop(session)
    end
  end

  defp start_session(root, opts \\ []) do
    settings = %{
      SettingsManager.load(root)
      | compaction_enabled: false,
        retry_enabled: false,
        provider_routing: %{enabled: false}
    }

    defaults = [
      cwd: root,
      workspace_dir: Path.join(root, "workspace"),
      model: model(),
      settings_manager: settings,
      system_prompt: "Follow the request.",
      tool_policy: ToolPolicy.custom(allow: ["todo", "write"]),
      stream_fn: scripted([response("done")])
    ]

    session =
      start_supervised!(
        Supervisor.child_spec({Session, Keyword.merge(defaults, opts)},
          id: make_ref(),
          restart: :temporary
        )
      )

    on_exit(fn -> File.rm_rf!(SessionManager.get_session_dir(root)) end)
    session
  end

  defp pending do
    [
      %{
        "id" => "primary",
        "content" => "Inspect",
        "priority" => "high",
        "metadata" => %{"owner" => "test"}
      },
      %{"content" => "Verify", "dependencies" => ["primary"], "estimated_effort" => "small"}
    ]
  end

  defp execute(session, params),
    do:
      Todo.tool(Session.get_state(session).cwd, session_pid: session).execute.(
        "todo-test",
        params,
        nil,
        nil
      )

  defp view(session, action) do
    assert %AgentToolResult{is_error: false} = result = execute(session, %{"action" => action})
    result
  end

  defp write(session, todos) do
    assert %AgentToolResult{is_error: false} =
             result = execute(session, %{"action" => "write", "todos" => todos})

    result
  end

  defp tool(session, name), do: Enum.find(Session.get_state(session).tools, &(&1.name == name))
  defp leaf(session), do: Session.get_state(session).session_manager.leaf_id

  defp leaf_id_of_latest_todo(session),
    do:
      Session.get_state(session).session_manager
      |> SessionManager.entries()
      |> Enum.filter(&(&1.custom_type == "lemon.todo"))
      |> List.last()
      |> Map.fetch!(:id)

  defp navigate(session, id),
    do: assert(:ok = Session.navigate_tree(session, id, summarize_abandoned: false))

  defp rewind(session, id) do
    assert {:ok, preview} = Session.rewind(session, id)

    assert {:ok, _} =
             Session.rewind(session, id,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )
  end

  defp assert_views(session, todos) do
    details = TodoStore.result_details(todos)

    for action <- ["read", "progress", "actionable"] do
      result = view(session, action)
      assert result.details.todos == details.todos
      assert result.details.plan == details.plan

      assert %AgentToolResult{is_error: false, details: live_details} =
               tool(session, "todo").execute.("view", %{"action" => action}, nil, nil)

      assert live_details.todos == details.todos
      assert live_details.plan == details.plan

      if action == "progress",
        do:
          assert(
            Map.take(result.details, Map.keys(TodoStore.progress(todos))) ==
              TodoStore.progress(todos)
          )

      if action == "actionable",
        do:
          assert(
            result.details.actionable ==
              TodoStore.result_details(TodoStore.actionable(todos)).todos
          )
    end
  end

  defp prompt(session, text) do
    assert {:ok, stream} = Session.subscribe(session, mode: :stream)
    assert :ok = Session.prompt(session, text)
    events = stream |> LemonAgent.EventStream.events() |> Enum.to_list()
    refute Enum.any?(events, &match?({:error, _, _}, &1))
    refute Session.get_state(session).is_streaming
  end

  defp legacy_result(manager, id, name, arguments, todos, error) do
    manager
    |> SessionManager.append_message(%{
      "role" => "assistant",
      "content" => [
        %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments}
      ]
    })
    |> SessionManager.append_message(%{
      "role" => "tool_result",
      "tool_call_id" => id,
      "tool_name" => name,
      "content" => [],
      "details" => %{"todos" => todos},
      "is_error" => error
    })
  end

  defp scripted(responses) do
    count = :counters.new(1, [:atomics])

    fn _model, _context, _opts ->
      :counters.add(count, 1, 1)
      message = Enum.fetch!(responses, :counters.get(count, 1) - 1)
      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
      {:ok, stream}
    end
  end

  defp call(id, name, arguments), do: %ToolCall{id: id, name: name, arguments: arguments}
  defp response(text) when is_binary(text), do: response([%TextContent{text: text}], :stop)
  defp response(content), do: response(content, :tool_use)

  defp response(content, reason),
    do: %AssistantMessage{
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "todo-journal-test",
      stop_reason: reason,
      timestamp: 1,
      usage: %Usage{input: 6, output: 4, total_tokens: 10, cost: %Cost{total: 0.25}}
    }

  defp model,
    do: %Model{
      id: "todo-journal-test",
      name: "Todo journal test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 1024
    }
end
