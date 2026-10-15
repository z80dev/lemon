defmodule CodingAgent.Session.PlanningTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Security.SecretObfuscator
  alias CodingAgent.Session
  alias CodingAgent.Session.Planning
  alias CodingAgent.Session.WasmBridge
  alias CodingAgent.SessionManager
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.SettingsManager
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall}

  setup do
    fixture = Path.join(System.tmp_dir!(), "lemon-plan-#{System.unique_integer([:positive])}")
    root = Path.join(fixture, "project")

    saved_env =
      Map.new(~w(HOME LEMON_AGENT_DIR LEMON_DEFAULT_MODEL LEMON_DEFAULT_PROVIDER), fn key ->
        {key, System.get_env(key)}
      end)

    saved_paths = Application.get_env(:lemon_core, :paths)
    home = Path.join(fixture, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", Path.join(home, ".lemon/agent"))
    System.delete_env("LEMON_DEFAULT_MODEL")
    System.delete_env("LEMON_DEFAULT_PROVIDER")
    Application.put_env(:lemon_core, :paths, home_dir: home)
    File.mkdir_p!(Path.join(root, ".lemon"))
    File.write!(Path.join(root, ".lemon/config.toml"), "[features]\nsession_search = \"off\"\n")
    previous_feature = System.get_env("LEMON_FEATURE_SESSION_SEARCH")
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "off")
    previous_req_options = Req.default_options()
    {:ok, http_requests} = Agent.start(fn -> [] end)
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(http_requests, &[{conn.host, conn.request_path} | &1])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error":{"message":"unexpected fixture HTTP request"}}))
    end)

    on_exit(fn ->
      Req.default_options(previous_req_options)
      Req.Test.set_req_test_to_private(%{})

      if previous_feature,
        do: System.put_env("LEMON_FEATURE_SESSION_SEARCH", previous_feature),
        else: System.delete_env("LEMON_FEATURE_SESSION_SEARCH")

      File.rm_rf!(fixture)
      File.rm_rf!(SessionManager.get_session_dir(root))

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      try do
        assert Agent.get(http_requests, & &1) == [],
               "scripted planning must not call HTTP providers"
      after
        Agent.stop(http_requests)
      end
    end)

    %{root: root}
  end

  test "plan mode blocks mutation, drafts a plan file and executes in the same run once approved",
       %{root: root} do
    parent = self()
    target = Path.join(root, "result.txt")
    plan_text = "# Result plan\n1. Write result.txt with EXECUTED.\n2. Verify the bytes."

    stream =
      scripted_stream(parent, fn call, context ->
        plan_file = Path.join(plan_dir(context.system_prompt), "result-plan.md")

        case call do
          1 -> tool_use("write-tree", "write", %{"path" => target, "content" => "EARLY"})
          2 -> tool_use("bash", "bash", %{"command" => "touch nope"})
          3 -> tool_use("write-plan", "write", %{"path" => plan_file, "content" => plan_text})
          4 -> tool_use("propose", "propose_plan", %{"path" => plan_file, "title" => "Result"})
          5 -> tool_use("write-tree-2", "write", %{"path" => target, "content" => "EXECUTED"})
          _ -> stop("Executed and verified")
        end
      end)

    approvals = fn request ->
      send(parent, {:approval_request, request})
      {:ok, :approved, :once}
    end

    opts =
      session_opts(root, stream, approvals, [reader(), writer(), bash()])
      |> Keyword.put(:agent_id, "planner")
      |> Keyword.put(:invocation_context_key, "planning-client")

    session = start_supervised!({Session, opts})
    Session.subscribe(session)

    assert {:ok, %{"mode" => "plan", "path" => nil}} = Session.plan(session, :enter)
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Plan, then write the result.")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    assert_receive {:provider_context, 1, planning}
    assert planning.system_prompt =~ "Plan mode is active"
    assert ~w(read write bash propose_plan) -- Enum.map(planning.tools, & &1.name) == []

    errors = tool_errors(Session.get_messages(session))
    assert errors["write-tree"] =~ "Plan mode is active"
    assert errors["bash"] =~ "Plan mode is active"
    refute Map.has_key?(errors, "write-plan")

    assert_receive {:approval_request, request}
    assert request.tool == "propose_plan"
    assert request.tool_call_id == "propose"
    assert request.agent_id == "planner"
    assert request.invocation_context_key == "planning-client"
    assert request.action["title"] == "Result"
    assert request.action["plan"] == plan_text
    plan_file = request.action["path"]
    refute String.starts_with?(plan_file, root <> "/")

    assert_receive {:provider_context, 5, executing}
    refute executing.system_prompt =~ "Plan mode is active"
    assert executing.system_prompt =~ "## Approved plan"
    assert executing.system_prompt =~ plan_text
    assert File.read!(target) == "EXECUTED"

    assert {:ok, %{"mode" => "code", "path" => ^plan_file, "content" => ^plan_text}} =
             Session.plan(session)

    path = Session.get_state(session).session_file
    stop_supervised!(Session)
    resumed = start_supervised!({Session, Keyword.put(opts, :session_file, path)})
    assert {:ok, %{"mode" => "code", "path" => ^plan_file}} = Session.plan(resumed)
    assert Session.get_state(resumed).system_prompt =~ plan_text
    refute "propose_plan" in Enum.map(Session.get_state(resumed).tools, & &1.name)

    assert {:ok, %{"mode" => "plan", "path" => ^plan_file}} = Session.plan(resumed, :enter)
    assert Session.get_state(resumed).system_prompt =~ "Existing plan: `#{plan_file}`"
    assert {:ok, %{"mode" => "code"}} = Session.plan(resumed, :exit)
    assert {:ok, %{"mode" => "code"}} = Session.plan(resumed, :exit)
  end

  test "a direct key without policy or approval context still scopes plan approval", %{root: root} do
    parent = self()
    :ok = LemonCore.Bus.subscribe("exec_approvals")

    stream =
      scripted_stream(parent, fn call, context ->
        plan_file = Path.join(plan_dir(context.system_prompt), "key-only-plan.md")

        case call do
          1 -> tool_use("write-plan", "write", %{"path" => plan_file, "content" => "# Key only"})
          2 -> tool_use("propose", "propose_plan", %{"path" => plan_file, "title" => "Key only"})
          _ -> stop("Not approved")
        end
      end)

    opts =
      session_opts(root, stream, nil, [reader(), writer()])
      |> Keyword.delete(:approval_context)
      |> Keyword.put(:agent_id, "key-only-planner")
      |> Keyword.put(:invocation_context_key, "key-only-planning-client")

    session = start_supervised!({Session, opts})
    Session.subscribe(session)
    assert {:ok, _} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Propose a plan.")

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{pending: %{id: approval_id}}
                   },
                   5_000

    pending = LemonCore.ExecApprovalStore.get_pending(approval_id)
    assert pending.invocation_context_key == "key-only-planning-client"
    assert pending.agent_id == "key-only-planner"
    LemonCore.ExecApprovals.resolve(approval_id, :deny)
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session)
  end

  test "active plan reload immediately applies new mutation and proposal blockers", %{root: root} do
    ext_dir = Path.join(root, ".lemon/extensions")
    File.mkdir_p!(ext_dir)

    names =
      for label <- ["Allow", "Block"],
          do: "ReloadPlan#{label}#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for name <- names do
        module = Module.concat([name])
        :code.purge(module)
        :code.delete(module)
      end
    end)

    install = fn name, action ->
      path = Path.join(ext_dir, name <> ".ex")

      File.write!(path, """
      defmodule #{name} do
        @behaviour CodingAgent.Extensions.Extension
        def name, do: "#{name}"
        def version, do: "1.0.0"
        def hooks do
          [on_tool_call: fn %{tool_name: name} when name in ["write", "edit", "propose_plan"] ->
            #{action}
          _ -> :ok end]
        end
      end
      """)

      path
    end

    [allow, block] = names
    old_path = install.(allow, ":ok")
    parent = self()

    session =
      start_supervised!(
        {Session,
         [
           cwd: root,
           register: false,
           model: model(),
           mcp_tools: [],
           settings_manager: %{
             settings(root)
             | extension_paths: [ext_dir],
               extension_auto_load_default_paths: false
           },
           approval_context: %{
             approval_request_fun: fn request ->
               send(parent, {:unexpected_plan_approval, request})
               {:ok, :approved, :once}
             end
           }
         ]}
      )

    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    state = Session.get_state(session)
    path = Path.join(Planning.plan_dir(state.session_manager), "reload-plan.md")
    write = Enum.find(state.tools, &(&1.name == "write"))
    refute run(write, path, "allowed").is_error
    assert File.read!(path) == "allowed"

    File.rm!(old_path)
    install.(block, "{:block, \"reloaded extension blocks plan mutation\"}")
    assert {:ok, _} = Session.reload_extensions(session)
    tools = Map.new(Session.get_state(session).tools, &{&1.name, &1})

    for {name, args} <- [
          {"write", %{"path" => path, "content" => "forbidden"}},
          {"edit", %{"path" => path, "old_text" => "allowed", "new_text" => "forbidden"}},
          {"propose_plan", %{"path" => path}}
        ] do
      result = tools[name].execute.("reload-#{name}", args, nil, nil)
      assert result.is_error
      assert File.read!(path) == "allowed"
    end

    assert {:ok, %{"mode" => "plan"}} = Session.plan(session)
    refute_received {:unexpected_plan_approval, _}
  end

  test "repeated refresh and reload restore private host and native bridge writes", %{root: root} do
    secret = "fixture-native-plan-secret"
    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(agent_dir)
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    File.mkdir_p!(Path.join(root, ".lemon"))
    File.write!(Path.join(root, ".lemon/secrets.yml"), "- type: plain\n  content: #{secret}\n")
    ext_dir = Path.join(root, ".lemon/extensions")
    File.mkdir_p!(ext_dir)
    module_name = "NativePlanRefresh#{System.unique_integer([:positive])}"
    module = Module.concat([module_name])
    parent = inspect(:erlang.pid_to_list(self()))

    File.write!(Path.join(ext_dir, "hooks.ex"), """
    defmodule #{module_name} do
      @behaviour CodingAgent.Extensions.Extension
      @impl true
      def name, do: "native-plan-refresh"
      @impl true
      def version, do: "1.0.0"
      @impl true
      def hooks do
        [on_tool_call: fn
          %{tool_name: "write", args: args} ->
            send(:erlang.list_to_pid(#{parent}), {:native_plan_hook, args["content"]})
            :ok
          _ -> :ok
        end]
      end
    end
    """)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")
    end)

    calls = :counters.new(1, [:atomics])

    stream = fn _, context, _ ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)

      message =
        if rem(call, 2) == 1 do
          content = context.messages |> List.last() |> Map.fetch!(:content)

          placeholder =
            case content do
              text when is_binary(text) -> text
              blocks when is_list(blocks) -> Enum.map_join(blocks, "", &Map.fetch!(&1, :text))
            end

          tool_use("bounded-#{call}", "tool_invoke", %{
            "name" => "write",
            "args" => %{
              "path" => Path.join(plan_dir(context.system_prompt), "bounded-plan.md"),
              "content" => placeholder <> "/bridge-#{div(call + 1, 2)}"
            }
          })
        else
          stop("Draft saved")
        end

      {:ok, events(message)}
    end

    settings = %{
      settings(root)
      | secret_obfuscation_enabled: true,
        extension_paths: [ext_dir],
        extension_auto_load_default_paths: false
    }

    session =
      start_supervised!(
        {Session,
         [
           cwd: root,
           workspace_dir: Path.join(root, "workspace"),
           model: model(),
           stream_fn: stream,
           settings_manager: settings,
           mcp_tools: [],
           tool_policy:
             CodingAgent.ToolPolicy.custom(allow: ["read", "write", "edit", "browser_tabs"]),
           tool_disclosure: [profile: :coding],
           system_prompt: "Update the private plan draft."
         ]}
      )

    Session.subscribe(session)
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    state = Session.get_state(session)

    placeholder =
      SecretObfuscator.obfuscate(state.secret_obfuscator, secret)

    refute placeholder == secret
    plan_file = Path.join(Planning.plan_dir(state.session_manager), "bounded-plan.md")
    native_id = state.session_manager.header.id

    for revision <- 1..6 do
      if revision > 1 do
        assert {:ok, _} = Session.reload_extensions(session)
      end

      host_content = secret <> "/host-#{revision}"

      assert {:ok, _} =
               WasmBridge.invoke_host_tool(
                 session,
                 "write",
                 Jason.encode!(%{
                   "path" => plan_file,
                   "content" => placeholder <> "/host-#{revision}"
                 }),
                 5_000
               )

      assert_receive {:native_plan_hook, ^host_content}
      refute_received {:native_plan_hook, _}
      assert File.read!(plan_file) == host_content

      assert :ok = Session.prompt(session, placeholder)
      assert_receive {:session_event, ^native_id, {:agent_end, _}}, 5_000
      bridge_content = secret <> "/bridge-#{revision}"
      assert_receive {:native_plan_hook, ^bridge_content}
      refute_received {:native_plan_hook, _}
      assert File.read!(plan_file) == bridge_content
      call_id = "bounded-#{revision * 2 - 1}"

      assert %{is_error: false} =
               Enum.find(Session.get_messages(session), fn
                 %{role: :tool_result, tool_call_id: ^call_id} -> true
                 _ -> false
               end)

      assert {:ok, %{"mode" => "plan"}} = Session.plan(session)
    end
  end

  test "refinement keeps plan mode and remembers the proposed plan file", %{root: root} do
    parent = self()

    stream =
      scripted_stream(parent, fn call, context ->
        plan_file = Path.join(plan_dir(context.system_prompt), "refine-plan.md")

        case call do
          1 -> tool_use("write-plan", "write", %{"path" => plan_file, "content" => "# Draft"})
          2 -> tool_use("propose", "propose_plan", %{"path" => plan_file, "title" => "Draft"})
          _ -> stop("Waiting for feedback")
        end
      end)

    approvals = fn request ->
      send(parent, {:refinement_approval, request})
      {:ok, :denied}
    end

    opts =
      session_opts(root, stream, approvals, [reader(), writer()])
      |> Keyword.put(:agent_id, "refiner")
      |> Keyword.put(:invocation_context_key, "refinement-client")

    session = start_supervised!({Session, opts})

    Session.subscribe(session)
    assert {:ok, _} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Plan it.")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert_receive {:refinement_approval, request}
    assert request.agent_id == "refiner"
    assert request.invocation_context_key == "refinement-client"

    assert {:ok, %{"mode" => "plan", "path" => plan_file, "content" => "# Draft"}} =
             Session.plan(session)

    assert Path.basename(plan_file) == "refine-plan.md"
    assert Session.get_state(session).system_prompt =~ "Existing plan: `#{plan_file}`"

    result =
      Session.get_messages(session)
      |> Enum.find(&(Map.get(&1, :tool_call_id) == "propose"))

    assert text(result) =~ "wants it refined"
  end

  test "toggling is refused while a turn runs", %{root: root} do
    parent = self()

    stream = fn _model, _context, _opts ->
      send(parent, {:streaming, self()})

      receive do
        :release -> {:ok, events(stop("done"))}
      end
    end

    session =
      start_supervised!({Session, session_opts(root, stream, fn _ -> {:ok, :denied} end, [])})

    Session.subscribe(session)
    assert :ok = Session.prompt(session, "Work.")
    assert_receive {:streaming, pid}, 5_000
    assert {:error, :busy} = Session.plan(session, :enter)
    assert {:ok, %{"mode" => "code"}} = Session.plan(session, :status)
    send(pid, :release)
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
  end

  test "plan mode permits direct and bridged todo reads but blocks mutations", %{root: root} do
    manager = SessionManager.new(root)
    {:ok, _, manager} = Planning.transition(manager, :enter, [])
    parent = self()

    tools =
      for name <- ["todo", "todoread", "tool_invoke"] do
        %{
          writer()
          | name: name,
            execute: fn id, params, _, _ ->
              send(parent, {:todo_execution, name, id, params})
              %AgentToolResult{content: [%TextContent{text: "read result"}], is_error: false}
            end
        }
      end

    context = %{
      gate: Planning.new_gate(),
      cwd: root,
      session_pid: self(),
      session_id: manager.header.id,
      run_id: "run",
      session_key: "key",
      agent_id: "default",
      approval_request_fun: nil
    }

    guarded = Map.new(Planning.tools(tools, manager, context), &{&1.name, &1})

    reads =
      [{"todoread", %{}}] ++
        Enum.map(["read", "progress", "actionable"], &{"todo", %{"action" => &1}})

    for {target, args} <- reads do
      assert %AgentToolResult{is_error: false} =
               guarded[target].execute.("direct", args, nil, nil)

      assert_receive {:todo_execution, ^target, "direct", ^args}
      params = %{"name" => target, "args" => args}

      assert %AgentToolResult{is_error: false} =
               guarded["tool_invoke"].execute.("bridge", params, nil, nil)

      assert_receive {:todo_execution, "tool_invoke", "bridge", ^params}
    end

    for args <- [%{"action" => "add"}, %{"action" => "update"}, %{"action" => "clear"}, %{}] do
      assert %AgentToolResult{is_error: true} =
               guarded["todo"].execute.("blocked", args, nil, nil)

      assert %AgentToolResult{is_error: true} =
               guarded["tool_invoke"].execute.(
                 "blocked",
                 %{"name" => "todo", "args" => args},
                 nil,
                 nil
               )

      refute_received {:todo_execution, _, _, _}
    end
  end

  test "plan-only file tools stay inside the plan directory", %{root: root} do
    manager = SessionManager.new(root)
    {:ok, _, manager} = Planning.transition(manager, :enter, [])
    gate = Planning.new_gate()
    plan_dir = Planning.plan_dir(manager)

    context = %{
      gate: gate,
      cwd: root,
      session_pid: self(),
      session_id: manager.header.id,
      run_id: "run",
      session_key: "key",
      agent_id: "default",
      approval_request_fun: nil
    }

    tools = Map.new(Planning.tools([reader()], manager, context), &{&1.name, &1})
    assert Map.keys(tools) |> Enum.sort() == ~w(edit propose_plan read write)
    assert :atomics.get(gate, 1) == 1

    plan_file = Path.join(plan_dir, "x-plan.md")
    assert %AgentToolResult{is_error: false} = run(tools["write"], plan_file, "# Plan")
    assert File.read!(plan_file) == "# Plan"
    assert %AgentToolResult{is_error: true} = run(tools["write"], Path.join(root, "a.md"), "x")

    assert %AgentToolResult{is_error: true} =
             run(tools["write"], Path.join(plan_dir, "x.txt"), "x")

    database = Path.join(plan_dir, "app.db")
    {:ok, conn} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(conn, "CREATE TABLE \"plan.md\" (name TEXT)")
    :ok = Exqlite.Sqlite3.close(conn)

    assert %AgentToolResult{is_error: true} =
             run(tools["write"], database <> ":plan.md", ~s({"name":"blocked"}))

    refute File.exists?(Path.join(root, "a.md"))

    File.write!(plan_file, " ")
    propose = %{"path" => plan_file, "title" => "T"}

    assert {:error, "The plan file is empty" <> _} =
             tools["propose_plan"].execute.("p", propose, nil, nil)

    assert {:error, "The plan file must be a Markdown file" <> _} =
             tools["propose_plan"].execute.("p", %{propose | "path" => "a.md"}, nil, nil)

    {:ok, _, manager} = Planning.transition(manager, :exit, [])
    assert Planning.tools([reader()], manager, context) |> Enum.map(& &1.name) == ["read"]
    assert :atomics.get(gate, 1) == 0

    assert {:error, "Plan mode is not active" <> _} =
             tools["propose_plan"].execute.("p", propose, nil, nil)
  end

  test "private plan tools restore secrets and enforce hooks before restricted writes", %{
    root: root
  } do
    manager = SessionManager.new(root)
    {:ok, _, manager} = Planning.transition(manager, :enter, [])
    secret = "private-plan-secret"

    obfuscator =
      SecretObfuscator.build(
        cwd: root,
        agent_dir: root,
        env: %{"API_KEY" => secret}
      )

    placeholder = SecretObfuscator.obfuscate(obfuscator, secret)
    parent = self()
    outside = Path.join(root, "outside.md")

    hooks = [
      on_tool_call: [
        fn event ->
          send(parent, {:plan_tool_call, event.tool_name, event.args})

          cond do
            event.tool_name == "propose_plan" ->
              {:block, "not ready"}

            event.args["content"] == "redirect" ->
              {:replace_args, Map.put(event.args, "path", outside)}

            true ->
              :ok
          end
        end
      ]
    ]

    context = %{
      gate: Planning.new_gate(),
      cwd: root,
      session_pid: self(),
      session_id: manager.header.id,
      run_id: "run",
      session_key: "key",
      agent_id: "default",
      approval_request_fun: fn _ -> flunk("blocked proposal reached approval") end,
      hooks: hooks,
      secret_obfuscator: obfuscator
    }

    plan_file = Path.join(Planning.plan_dir(manager), "hook-plan.md")

    bridge = %{
      writer()
      | name: "tool_invoke",
        execute: fn _, _, _, _ -> flunk("private plan write escaped through the bridge") end
    }

    for base <- [[reader()], [reader(), writer()]] do
      tools = Map.new(Planning.tools([bridge | base], manager, context), &{&1.name, &1})
      assert %AgentToolResult{is_error: false} = run(tools["write"], plan_file, placeholder)
      assert_receive {:plan_tool_call, "write", %{"content" => ^secret}}
      assert File.read!(plan_file) == secret

      assert %AgentToolResult{is_error: true} = run(tools["write"], plan_file, "redirect")
      assert_receive {:plan_tool_call, "write", %{"content" => "redirect"}}
      refute File.exists?(outside)
      assert File.read!(plan_file) == secret

      state =
        Map.merge(context, %{
          plan_gate: context.gate,
          session_manager: manager,
          tools: Map.values(tools),
          approval_context: %{}
        })

      host =
        Planning.host_tool(writer(), manager, Planning.runtime_context(state, self()))

      bridged_write = fn content ->
        tools["tool_invoke"].execute.(
          "bridge-plan",
          %{"name" => "write", "args" => %{"path" => plan_file, "content" => content}},
          nil,
          nil
        )
      end

      for execute <- [&run(host, plan_file, &1), bridged_write] do
        assert %AgentToolResult{is_error: false} = execute.(placeholder)
        assert_receive {:plan_tool_call, "write", %{"content" => ^secret}}
        refute_received {:plan_tool_call, "write", _}
        assert File.read!(plan_file) == secret

        assert %AgentToolResult{is_error: true} = execute.("redirect")
        assert_receive {:plan_tool_call, "write", %{"content" => "redirect"}}
        refute_received {:plan_tool_call, "write", _}
        refute File.exists?(outside)
        assert File.read!(plan_file) == secret
      end

      assert %AgentToolResult{is_error: true} =
               tools["propose_plan"].execute.(
                 "p",
                 %{"path" => plan_file, "title" => "Plan"},
                 nil,
                 nil
               )

      assert_receive {:plan_tool_call, "propose_plan", _}
    end
  end

  test "legacy reviewed-artifact entries load as plan mode and approved context", %{root: root} do
    artifact = Path.join(root, "legacy.md")
    File.write!(artifact, "# Legacy pending")
    file = Path.join(root, "legacy.jsonl")

    root
    |> SessionManager.new()
    |> SessionManager.append_entry(
      SessionEntry.custom("lemon.plan", %{
        "mode" => "plan",
        "status" => "pending",
        "revision" => String.duplicate("a", 64),
        "path" => artifact,
        "content" => "# Legacy pending"
      })
    )
    |> SessionManager.persist(file)

    assert {:ok, pending} = SessionManager.load_from_file(file)

    assert Planning.status(pending) == %{
             "mode" => "plan",
             "path" => artifact,
             "content" => "# Legacy pending"
           }

    assert Planning.system_prompt("base", pending) =~ "Existing plan: `#{artifact}`"

    approved =
      pending
      |> SessionManager.append_entry(
        SessionEntry.custom("lemon.plan", %{
          "mode" => "code",
          "status" => "approved",
          "revision" => String.duplicate("a", 64),
          "path" => artifact,
          "content" => "# Legacy approved"
        })
      )

    assert %{"mode" => "code", "path" => ^artifact} = Planning.status(approved)
    assert Planning.system_prompt("base", approved) =~ "## Approved plan"
    assert Planning.system_prompt("base", approved) =~ "# Legacy approved"
    assert {:ok, %{"mode" => "plan"}, _} = Planning.transition(approved, :enter, [])
  end

  test "configured plan role restores the execution model after durable resume", %{root: root} do
    settings = role_settings()
    stream = fn model, _context, _opts -> {:ok, events(%{stop("done") | model: model.id})} end

    opts =
      session_opts(root, stream, fn _ -> {:ok, :denied} end, [])
      |> Keyword.put(:model, "openai:gpt-4")
      |> Keyword.put(:settings_manager, settings)
      |> Keyword.put(:workspace_dir, Path.join(root, "workspace"))

    session = start_supervised!({Session, opts})
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    assert Session.get_state(session).model.id == "gpt-4o-mini"
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    assert :ok = Session.save(session)
    path = Session.get_state(session).session_file
    stop_supervised!(Session)

    resumed =
      start_supervised!(
        {Session, opts |> Keyword.delete(:model) |> Keyword.put(:session_file, path)}
      )

    assert Session.get_state(resumed).model.id == "gpt-4o-mini"
    assert {:ok, %{"mode" => "code"}} = Session.plan(resumed, :exit)
    assert Session.get_state(resumed).model.id == "gpt-4"
    assert LemonAgent.Agent.get_state(Session.get_state(resumed).agent).model.id == "gpt-4"
    assert :ok = Session.save(resumed)
    assert {:ok, manager} = SessionManager.load_from_file(path)

    assert SessionManager.build_session_context(manager).model == %{
             provider: "openai",
             model_id: "gpt-4"
           }
  end

  test "approval restores the execution model before the next response in the same run", %{
    root: root
  } do
    parent = self()
    calls = :counters.new(1, [:atomics])

    stream = fn model, context, _opts ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:planning_model, call, model.id})
      path = Path.join(plan_dir(context.system_prompt), "role-plan.md")

      response =
        case call do
          1 -> tool_use("write-plan", "write", %{"path" => path, "content" => "# Role plan"})
          2 -> tool_use("propose", "propose_plan", %{"path" => path, "title" => "Role"})
          _ -> stop("Executing with the original model")
        end

      {:ok, events(%{response | model: model.id, provider: model.provider, api: model.api})}
    end

    opts =
      session_opts(root, stream, fn _ -> {:ok, :approved, :once} end, [reader(), writer()])
      |> Keyword.put(:model, "openai:gpt-4")
      |> Keyword.put(:settings_manager, role_settings())
      |> Keyword.put(:workspace_dir, Path.join(root, "workspace"))

    session = start_supervised!({Session, opts})
    Session.subscribe(session)
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Plan and execute.")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000
    assert_receive {:planning_model, 1, "gpt-4o-mini"}
    assert_receive {:planning_model, 2, "gpt-4o-mini"}
    assert_receive {:planning_model, 3, "gpt-4"}
    assert Session.get_state(session).model.id == "gpt-4"
  end

  test "invalid configured plan model leaves mode and execution model unchanged", %{root: root} do
    settings = %{role_settings() | model_roles: %{"plan" => "unknown-provider:not-a-model"}}

    opts =
      session_opts(
        root,
        fn _, _, _ -> {:ok, events(stop("done"))} end,
        fn _ ->
          {:ok, :denied}
        end,
        []
      )
      |> Keyword.put(:model, "openai:gpt-4")
      |> Keyword.put(:settings_manager, settings)
      |> Keyword.put(:workspace_dir, Path.join(root, "workspace"))

    session = start_supervised!({Session, opts})
    assert {:error, :invalid_plan_model} = Session.plan(session, :enter)
    assert {:ok, %{"mode" => "code"}} = Session.plan(session)
    assert Session.get_state(session).model.id == "gpt-4"
  end

  test "stopped entry journals the project role and resumes without a model override", %{
    root: root
  } do
    write_role_config(root)
    key = planning_key()
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)
    assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_create(key, root)
    before = stopped_manager(root, key)

    assert {:ok, %{"mode" => "plan"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])

    planned = stopped_manager(root, key)
    assert planned.leaf_id != before.leaf_id

    assert execution_descriptor(planned) == %{
             "provider" => "plan-fixture",
             "model" => "execution"
           }

    assert model_changes(planned) == [{"plan-fixture", "planning"}]
    bytes = File.read!(planned.file_path)

    assert {:ok, %{"mode" => "plan"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])

    assert File.read!(planned.file_path) == bytes
    assert LemonCore.SessionLifecycle.get(key).run_count == 0

    # Profile workspace files are bootstrap inputs, not project model-role config.
    workspace = Path.join(root, "profile-workspace")
    File.mkdir_p!(Path.join(workspace, ".lemon"))

    File.write!(
      Path.join(workspace, ".lemon/config.toml"),
      "[model_roles]\nplan = \"openai:gpt-4o\"\n"
    )

    resumed =
      start_supervised!({Session, offline_resume_opts(root, key, planned.file_path, workspace)})

    state = Session.get_state(resumed)
    assert state.model.id == "planning"
    assert state.model.base_url == "http://127.0.0.1:1/v1"
    assert LemonAgent.Agent.get_state(state.agent).model.id == "planning"
    assert execution_descriptor(state.session_manager) == execution_descriptor(planned)
    assert {:ok, %{"mode" => "code"}} = Session.plan(resumed, :exit)
    assert Session.get_state(resumed).model.id == "execution"
    assert :ok = Session.save(resumed)
    assert List.last(model_changes(stopped_manager(root, key))) == {"plan-fixture", "execution"}
  end

  test "stopped entry preserves the active branch model rather than the configured default", %{
    root: root
  } do
    write_role_config(root)
    key = planning_key()
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)
    assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_create(key, root)

    active =
      stopped_manager(root, key)
      |> SessionManager.append_entry(SessionEntry.model_change("openai", "gpt-4"))

    sibling =
      active
      |> SessionManager.append_entry(SessionEntry.model_change("openai", "gpt-4o"))
      |> SessionManager.set_leaf_id(active.leaf_id)

    assert {:ok, %{"mode" => "plan"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])

    planned = stopped_manager(root, key)
    assert execution_descriptor(planned) == %{"provider" => "openai", "model" => "gpt-4"}
    assert model_changes(planned) == [{"openai", "gpt-4"}, {"plan-fixture", "planning"}]
    assert length(SessionManager.entries(planned)) == length(SessionManager.entries(sibling)) + 2

    assert {:ok, %{"mode" => "code"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :exit, [])

    assert List.last(model_changes(stopped_manager(root, key))) == {"openai", "gpt-4"}
  end

  test "live entry then stopped exit restores the journaled execution model on restart", %{
    root: root
  } do
    write_role_config(root)
    key = planning_key()
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)
    assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_create(key, root)
    manager = stopped_manager(root, key)
    opts = offline_resume_opts(root, key, manager.file_path, Path.join(root, "workspace"))
    session = start_supervised!({Session, Keyword.put(opts, :model, "openai:gpt-4")})
    assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
    assert Session.get_state(session).model.id == "planning"
    assert :ok = Session.save(session)
    stop_supervised!(Session)

    assert {:ok, %{"mode" => "code"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :exit, [])

    exited = stopped_manager(root, key)
    assert List.last(model_changes(exited)) == {"openai", "gpt-4"}
    bytes = File.read!(exited.file_path)

    assert {:ok, %{"mode" => "code"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :exit, [])

    assert File.read!(exited.file_path) == bytes
    resumed = start_supervised!({Session, opts})
    assert Session.get_state(resumed).model.id == "gpt-4"
    assert LemonAgent.Agent.get_state(Session.get_state(resumed).agent).model.id == "gpt-4"
  end

  test "first stopped entry can be approved after restart without a provider request", %{
    root: root
  } do
    write_role_config(root)
    key = planning_key()
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    assert {:ok, %{"mode" => "plan"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])

    manager = stopped_manager(root, key)

    assert execution_descriptor(manager) == %{
             "provider" => "plan-fixture",
             "model" => "execution"
           }

    session =
      start_supervised!(
        {Session, offline_resume_opts(root, key, manager.file_path, Path.join(root, "workspace"))}
      )

    assert Session.get_state(session).model.id == "planning"

    proposal = %{
      "path" => Path.join(Planning.plan_dir(manager), "approved.md"),
      "content" => "# Approved"
    }

    assert :ok = GenServer.call(session, {:resolve_plan_proposal, :approve, proposal})
    assert {:ok, %{"mode" => "code"}} = Session.plan(session)
    assert Session.get_state(session).model.id == "execution"
    assert LemonAgent.Agent.get_state(Session.get_state(session).agent).model.id == "execution"
    assert :ok = Session.save(session)
    assert List.last(model_changes(stopped_manager(root, key))) == {"plan-fixture", "execution"}
    stop_supervised!(Session)

    resumed =
      start_supervised!(
        {Session, offline_resume_opts(root, key, manager.file_path, Path.join(root, "workspace"))}
      )

    assert Session.get_state(resumed).model.id == "execution"
    assert Session.get_state(resumed).system_prompt =~ "# Approved"
  end

  test "invalid stopped planning roles leave the file branch and creation binding untouched", %{
    root: root
  } do
    write_role_config(root, "unknown-provider:missing")
    key = planning_key()
    fresh = planning_key()
    on_exit(fn -> Enum.each([key, fresh], &LemonCore.SessionLifecycle.delete/1) end)
    assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_create(key, root)
    manager = stopped_manager(root, key)
    bytes = File.read!(manager.file_path)

    assert {:error, :invalid_plan_model} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])

    unchanged = stopped_manager(root, key)
    assert unchanged.leaf_id == manager.leaf_id
    assert SessionManager.entries(unchanged) == SessionManager.entries(manager)
    assert File.read!(manager.file_path) == bytes
    files = Path.wildcard(Path.join(SessionManager.get_session_dir(root), "*.jsonl"))

    assert {:error, :invalid_plan_model} =
             CodingAgent.ControlPlaneProvider.session_plan(fresh, root, :enter, [])

    assert LemonCore.ChatStateStore.get(fresh) == nil
    assert LemonCore.SessionLifecycle.get(fresh) == nil
    assert Path.wildcard(Path.join(SessionManager.get_session_dir(root), "*.jsonl")) == files
  end

  test "same-model stopped planning toggles append no model change entries", %{root: root} do
    write_role_config(root, "plan-fixture:execution")
    key = planning_key()
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)
    assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_create(key, root)

    for action <- [:enter, :exit, :enter, :exit] do
      assert {:ok, _} = CodingAgent.ControlPlaneProvider.session_plan(key, root, action, [])
    end

    manager = stopped_manager(root, key)
    assert model_changes(manager) == []
    assert length(SessionManager.entries(manager)) == 4
  end

  defp planning_key, do: "agent:stopped-plan-#{System.unique_integer([:positive])}:main"

  defp stopped_manager(root, key) do
    id = LemonCore.ChatStateStore.get(key).last_resume_token
    path = SessionManager.session_file_path(root, id)
    {:ok, manager} = SessionManager.load_from_file(path)
    %{manager | file_path: path}
  end

  defp execution_descriptor(manager),
    do: SessionManager.latest_custom_entry(manager, "lemon.plan").data["execution_model"]

  defp model_changes(manager) do
    manager
    |> SessionManager.get_branch()
    |> Enum.filter(&(&1.type == :model_change))
    |> Enum.map(&{to_string(&1.provider), &1.model_id})
  end

  defp offline_resume_opts(root, key, path, workspace) do
    [
      cwd: root,
      session_file: path,
      session_key: key,
      workspace_dir: workspace,
      system_prompt: "Offline plan-role regression.",
      tools: [],
      stream_fn: fn _, _, _ -> flunk("plan transitions must not request a model response") end
    ]
  end

  defp write_role_config(root, plan_selector \\ "@project-planner") do
    global = Path.join(System.get_env("HOME"), ".lemon/config.toml")
    File.mkdir_p!(Path.dirname(global))
    File.write!(global, "[model_roles]\nplan = \"openai:gpt-4o\"\n")

    File.write!(Path.join(root, ".lemon/config.toml"), """
    [defaults]
    model = "plan-fixture:execution"
    [model_roles]
    plan = "#{plan_selector}"
    project-planner = "plan-fixture:planning"
    [providers.plan-fixture]
    api = "openai_completions"
    base_url = "http://127.0.0.1:1/v1"
    auth = "none"
    [[providers.plan-fixture.models]]
    id = "execution"
    [[providers.plan-fixture.models]]
    id = "planning"
    [features]
    session_search = "off"
    [memory]
    auto_recall = false
    [runtime.compaction]
    enabled = false
    [runtime.retry]
    enabled = false
    [runtime.provider_routing]
    enabled = false
    """)

    LemonCore.Config.reload(root)
  end

  defp role_settings do
    %SettingsManager{
      default_model: %{provider: :openai, model_id: "gpt-4", base_url: nil},
      model_roles: %{"plan" => "openai:gpt-4o-mini"},
      providers: %{"openai" => %{api_key: "fixture-only"}},
      provider_routing: %{enabled: false},
      compaction_enabled: false,
      retry_enabled: false
    }
  end

  test "entering before the first run creates one durable native planning session", %{root: root} do
    key = "agent:plan-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    assert {:ok, %{"mode" => "code", "path" => nil, "content" => nil}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :status, [])

    assert {:ok, %{"mode" => "code"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :exit, [])

    assert {:ok, entered} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])
    assert entered["mode"] == "plan"
    first = LemonCore.ChatStateStore.get(key).last_resume_token
    assert {:ok, ^entered} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :enter, [])
    assert LemonCore.ChatStateStore.get(key).last_resume_token == first
    assert {:ok, ^entered} = CodingAgent.ControlPlaneProvider.session_plan(key, root, :status, [])

    assert {:ok, %{"mode" => "code"}} =
             CodingAgent.ControlPlaneProvider.session_plan(key, root, :exit, [])

    assert LemonCore.SessionLifecycle.get(key).run_count == 0
  end

  test "explicit creation is idempotent, nameable and contains no fabricated plan or messages", %{
    root: root
  } do
    key = "agent:create-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    assert {:error, :not_found} =
             LemonCore.SessionLifecycle.patch(key, %{title: "Before first turn"})

    results =
      1..4
      |> Task.async_stream(fn _ -> CodingAgent.ControlPlaneProvider.session_create(key, root) end)
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert Enum.count(results, & &1["created"]) == 1
    assert [id] = results |> Enum.map(& &1["sessionId"]) |> Enum.uniq()
    assert LemonCore.ChatStateStore.get(key).last_resume_token == id

    assert {:ok, native} =
             SessionManager.load_from_file(SessionManager.session_file_path(root, id))

    assert SessionManager.entries(native) == []
    assert Planning.status(native)["mode"] == "code"
    assert {:ok, named} = LemonCore.SessionLifecycle.patch(key, %{title: "Before first turn"})
    assert named.title == "Before first turn"
    assert named.run_count == 0

    assert {:ok, %{"created" => false, "sessionId" => ^id}} =
             CodingAgent.ControlPlaneProvider.session_create(key, root)

    assert LemonCore.SessionLifecycle.get(key).title == "Before first turn"
    assert {:error, _} = CodingAgent.ControlPlaneProvider.session_create(key, root <> "-wrong")
    assert LemonCore.ChatStateStore.get(key).last_resume_token == id
  end

  test "explicit creation refuses legacy identities and existing non-native indexes", %{
    root: root
  } do
    assert {:error, :invalid_session_key} =
             CodingAgent.ControlPlaneProvider.session_create("unknown-legacy", root)

    key = "agent:existing-test-#{System.unique_integer([:positive])}:main"
    on_exit(fn -> LemonCore.SessionLifecycle.delete(key) end)

    :ok =
      LemonCore.RunStore.create_session_index(
        key,
        LemonCore.SessionKey.agent_id(key),
        :control_plane
      )

    assert {:error, :unsupported_session} =
             CodingAgent.ControlPlaneProvider.session_create(key, root)

    assert LemonCore.ChatStateStore.get(key) == nil
  end

  defp session_opts(root, stream, approvals, tools) do
    [
      cwd: root,
      model: model(),
      stream_fn: stream,
      tools: tools,
      system_prompt: "Follow the user's request.",
      settings_manager: settings(root),
      approval_context: %{approval_request_fun: approvals}
    ]
  end

  defp scripted_stream(parent, script) do
    calls = :counters.new(1, [:atomics])

    fn _model, context, _opts ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:provider_context, call, context})
      {:ok, events(script.(call, context))}
    end
  end

  # Plan-mode prompts name the plan directory; later (code-mode) calls do not.
  defp plan_dir(system_prompt) do
    case Regex.run(~r/The plan directory `([^`]+)`/, system_prompt) do
      [_, dir] -> dir
      nil -> ""
    end
  end

  defp tool_errors(messages) do
    for %{role: :tool_result, is_error: true} = message <- messages, into: %{} do
      {message.tool_call_id, text(message)}
    end
  end

  defp text(%{content: content}),
    do: Enum.map_join(content, &Map.get(&1, :text, ""))

  defp run(tool, path, content) do
    tool.execute.("call", %{"path" => path, "content" => content}, nil, nil)
  end

  defp reader do
    %AgentTool{
      name: "read",
      label: "Read",
      description: "Read",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> %AgentToolResult{content: [%TextContent{text: "read"}]} end
    }
  end

  defp writer do
    %AgentTool{
      name: "write",
      label: "Write",
      description: "Write a file",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, %{"path" => path, "content" => content}, _, _ ->
        File.write!(path, content)
        %AgentToolResult{content: [%TextContent{text: "written"}]}
      end
    }
  end

  defp bash do
    %AgentTool{
      name: "bash",
      label: "Bash",
      description: "Run a command",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> raise "bash must not run in plan mode" end
    }
  end

  defp settings(root), do: %{SettingsManager.load(root) | compaction_enabled: false}

  defp model,
    do: %Model{
      id: "plan-test",
      name: "Plan Test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

  defp tool_use(id, name, arguments),
    do: response([%ToolCall{id: id, name: name, arguments: arguments}], :tool_use)

  defp stop(text), do: response([%TextContent{text: text}], :stop)

  defp response(content, reason),
    do: %AssistantMessage{
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "plan-test",
      stop_reason: reason,
      timestamp: System.system_time(:millisecond)
    }

  defp events(message) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end
end
