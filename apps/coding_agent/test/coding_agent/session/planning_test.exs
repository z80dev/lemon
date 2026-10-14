defmodule CodingAgent.Session.PlanningTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Session.Planning
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{AssistantMessage, Model, ModelCost, TextContent, ToolCall}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(SessionManager.get_session_dir(root))
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

    opts = session_opts(root, stream, approvals, [reader(), writer(), bash()])
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
      CodingAgent.Security.SecretObfuscator.obfuscate(state.secret_obfuscator, secret)

    refute placeholder == secret
    plan_file = Path.join(Planning.plan_dir(state.session_manager), "bounded-plan.md")
    native_id = state.session_manager.header.id

    for revision <- 1..6 do
      if revision > 1 do
        assert {:ok, _} = Session.reload_extensions(session)
      end

      # The same request the WASM sidecar's host-invoke callback sends.
      host_content = secret <> "/host-#{revision}"
      params = %{"path" => plan_file, "content" => placeholder <> "/host-#{revision}"}

      assert {:ok, _} =
               GenServer.call(
                 session,
                 {:wasm_host_tool_invoke, "write", Jason.encode!(params)},
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

    session =
      start_supervised!(
        {Session, session_opts(root, stream, fn _ -> {:ok, :denied} end, [reader(), writer()])}
      )

    Session.subscribe(session)
    assert {:ok, _} = Session.plan(session, :enter)
    assert :ok = Session.prompt(session, "Plan it.")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

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
      CodingAgent.Security.SecretObfuscator.build(
        cwd: root,
        agent_dir: root,
        env: %{"API_KEY" => secret}
      )

    placeholder = CodingAgent.Security.SecretObfuscator.obfuscate(obfuscator, secret)
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

    for base <- [[reader()], [reader(), writer()]] do
      tools = Map.new(Planning.tools(base, manager, context), &{&1.name, &1})
      assert %AgentToolResult{is_error: false} = run(tools["write"], plan_file, placeholder)
      assert_receive {:plan_tool_call, "write", %{"content" => ^secret}}
      assert File.read!(plan_file) == secret

      assert %AgentToolResult{is_error: true} = run(tools["write"], plan_file, "redirect")
      assert_receive {:plan_tool_call, "write", %{"content" => "redirect"}}
      refute File.exists?(outside)
      assert File.read!(plan_file) == secret

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
