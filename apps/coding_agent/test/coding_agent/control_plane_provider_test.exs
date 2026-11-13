defmodule CodingAgent.ControlPlaneProviderTest do
  @moduledoc """
  Checks the coding provider against the shared core runtime contract and
  verifies boot registration and adapter return shapes.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.ControlPlaneProvider
  alias CodingAgent.Session.BudgetLedger
  alias CodingAgent.Session.MessageSerialization
  alias CodingAgent.Session.Presentation
  alias CodingAgent.SessionManager.SessionEntry
  alias CodingAgent.Tools.TodoStore
  alias CodingAgent.Tools.TodoWrite
  alias LemonAgent.Test.Mocks

  defmodule DirectCompactSession do
    use GenServer

    def start_link({observer, key}) do
      GenServer.start_link(__MODULE__, {observer, key})
    end

    @impl true
    def init({observer, key}) do
      {:ok, _} = Registry.register(CodingAgent.SessionRegistry, key, :test)
      {:ok, observer}
    end

    @impl true
    def handle_call({:compact, opts}, _from, observer) do
      send(observer, {:direct_compact, opts})
      {:reply, :ok, observer}
    end
  end

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, :sqlite_busy}
    def put_new(_, _, _, _), do: {:error, :sqlite_busy}
    def get(_, _, _), do: {:error, :sqlite_busy}
    def delete(_, _, _), do: {:error, :sqlite_busy}
    def list(_, _), do: {:error, :sqlite_busy}
  end

  test "offline todos distinguish unavailable workspace history from a missing session" do
    key = "agent:introspection-failure-#{System.unique_integer([:positive])}:main"
    original = :sys.get_state(LemonCore.Store)
    :sys.replace_state(LemonCore.Store, &%{&1 | backend: BusyBackend, backend_state: %{}})

    try do
      assert ControlPlaneProvider.session_todos(key, nil) ==
               {:error, :introspection_unavailable}
    after
      :sys.replace_state(LemonCore.Store, fn _ -> original end)
    end

    assert ControlPlaneProvider.session_todos(key, nil) == {:error, :session_not_found}
  end

  test "the running application has registered this provider" do
    assert LemonCore.AgentRuntime.provider() == ControlPlaneProvider
    assert LemonCore.AgentRuntime.available?()
  end

  describe "adapters return the shapes the control plane expects" do
    @tag :tmp_dir
    test "resolves reviewer instructions with enforced read-only policy", %{tmp_dir: cwd} do
      agents = Path.join(cwd, ".lemon/agents")
      File.mkdir_p!(agents)

      File.write!(Path.join(agents, "reviewer.md"), """
      ---
      description: Local review policy
      model: openai-codex:gpt-6.1-sol
      read_only: false
      tools: [read, write, bash]
      ---
      Check the exact proposed changes before approval.
      """)

      assert {:ok, persona} = ControlPlaneProvider.resolve_subagent(cwd, "reviewer")
      assert persona.prompt =~ "Check the exact proposed changes"
      assert persona.model == "openai-codex:gpt-6.1-sol"
      assert persona.tool_policy.allow == ["read"]
      refute Map.has_key?(persona, :source)

      assert {:error, :persona_unavailable} =
               ControlPlaneProvider.resolve_subagent(cwd, "../reviewer")
    end

    test "compact_session reports a missing session rather than raising" do
      assert ControlPlaneProvider.compact_session(
               "no-such-session-#{System.unique_integer()}",
               []
             ) ==
               {:error, :session_not_found}
    end

    test "compact_session accepts a direct registration without the native state protocol" do
      key = "direct-compact-#{LemonCore.Id.uuid()}"
      start_supervised!({DirectCompactSession, {self(), key}})
      opts = [force: true, summary: "Preserve the decision"]

      assert :ok = ControlPlaneProvider.compact_session(key, opts)
      assert_received {:direct_compact, ^opts}

      assert {:error, :session_not_found} =
               ControlPlaneProvider.session_recovery_snapshot(key, nil)
    end

    test "todo_progress reports unavailable for an unknown session" do
      assert ControlPlaneProvider.todo_progress("no-such-session-#{System.unique_integer()}") ==
               nil
    end

    test "extension_dirs returns global then project" do
      assert ControlPlaneProvider.extension_dirs("/tmp/some-project") == [
               CodingAgent.Config.extensions_dir(),
               CodingAgent.Config.project_extensions_dir("/tmp/some-project")
             ]
    end
  end

  describe "trusted addressing context" do
    @describetag :tmp_dir

    setup %{tmp_dir: root} do
      original_agent_dir = System.get_env("LEMON_AGENT_DIR")
      System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
      cwd = Path.join(root, "original")
      File.mkdir_p!(cwd)
      key = "agent:context-#{System.unique_integer([:positive])}:main"
      session = CodingAgent.SessionManager.new(cwd)
      path = CodingAgent.SessionManager.session_file_path(cwd, session.header.id)
      :ok = CodingAgent.SessionManager.save_to_file(path, session)

      :ok =
        LemonCore.ChatStateStore.put(key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: session.header.id
        })

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(key)
        LemonCore.RunStore.delete_session_index(key)

        if original_agent_dir,
          do: System.put_env("LEMON_AGENT_DIR", original_agent_dir),
          else: System.delete_env("LEMON_AGENT_DIR")
      end)

      %{cwd: cwd, key: key, session: session, path: path}
    end

    test "live ordinary, profile and fork roots retain actual authority", context do
      policy = CodingAgent.ToolPolicy.from_profile(:read_only)
      servers = [%{"type" => "http", "url" => "https://ordinary.example/mcp"}]

      for kind <- [:ordinary, :profile, :fork] do
        key = if(kind == :fork, do: context.key <> ":sub:user-fork", else: context.key)

        session =
          CodingAgent.SessionManager.new(context.cwd,
            parent_session: if(kind == :fork, do: "user-fork-parent")
          )

        path = CodingAgent.SessionManager.session_file_path(context.cwd, session.header.id)
        :ok = CodingAgent.SessionManager.save_to_file(path, session)

        opts = [
          cwd: context.cwd,
          workspace_dir: Path.join(context.cwd, "workspace"),
          session_file: path,
          session_key: key,
          register: true,
          model: Mocks.mock_model(),
          tools: [],
          tool_policy: policy,
          task_child: false,
          native_source_profile_id: if(kind == :profile, do: "research"),
          invocation_mcp_servers: servers
        ]

        pid = start_supervised!(Supervisor.child_spec({CodingAgent.Session, opts}, id: kind))

        assert {:ok, recovered} = ControlPlaneProvider.session_addressing_context(key)
        assert recovered.cwd == context.cwd
        assert recovered.task_child == false
        assert recovered.resume == LemonCore.ResumeToken.new("lemon", session.header.id)
        assert recovered.tool_policy == CodingAgent.Session.get_state(pid).tool_policy
        assert recovered.meta == %{mcp_servers: servers}
        assert recovered[:profile_id] == if(kind == :profile, do: "research")
        refute Map.has_key?(recovered, :approval_context)

        if kind == :fork do
          assert CodingAgent.Session.get_state(pid).session_scope == :subagent
        end

        stop_supervised!(kind)
      end
    end

    test "cold legacy journal and newly created empty session recover without introspection",
         context do
      assert {:ok, recovered} = ControlPlaneProvider.session_addressing_context(context.key)
      assert recovered.cwd == context.cwd
      assert recovered.resume.value == context.session.header.id
      assert recovered.task_child == false

      fresh_key = "agent:new-context-#{System.unique_integer([:positive])}:main"

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(fresh_key)
        LemonCore.RunStore.delete_session_index(fresh_key)
      end)

      assert {:ok, %{"created" => true, "sessionId" => id}} =
               ControlPlaneProvider.session_create(fresh_key, context.cwd)

      assert {:ok, %{cwd: cwd, resume: %{value: ^id}, task_child: false}} =
               ControlPlaneProvider.session_addressing_context(fresh_key)

      assert cwd == context.cwd
    end

    test "cold user fork preserves parentage without becoming a task child", context do
      fork_key = context.key <> ":sub:user-fork"

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(fork_key)
        LemonCore.RunStore.delete_session_index(fork_key)
      end)

      assert :ok = ControlPlaneProvider.session_fork(context.key, context.cwd, fork_key)
      assert {:ok, recovered} = ControlPlaneProvider.session_addressing_context(fork_key)
      assert recovered.cwd == context.cwd
      assert recovered.task_child == false
      refute recovered.resume.value == context.session.header.id
    end

    test "cold recovery rejects spoofed headers, ambiguous journals and corrupt headers",
         context do
      spoof = %{context.session | header: %{context.session.header | id: "another-native-id"}}
      :ok = CodingAgent.SessionManager.save_to_file(context.path, spoof)

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      :ok = CodingAgent.SessionManager.save_to_file(context.path, context.session)
      other_cwd = Path.join(context.cwd, "other")
      File.mkdir_p!(other_cwd)
      duplicate = %{context.session | header: %{context.session.header | cwd: other_cwd}}
      other_path = CodingAgent.SessionManager.session_file_path(other_cwd, duplicate.header.id)
      :ok = CodingAgent.SessionManager.save_to_file(other_path, duplicate)

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      File.rm!(other_path)
      File.write!(context.path, "{broken\n")

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)
    end

    test "cold recovery does not traverse journal or bucket symlinks", context do
      outside = Path.join(context.cwd, "outside.jsonl")
      File.rename!(context.path, outside)
      File.ln_s!(outside, context.path)

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      File.rm!(context.path)
      bucket = Path.dirname(context.path)
      moved_bucket = bucket <> "-outside"
      File.rename!(bucket, moved_bucket)
      File.rename!(outside, Path.join(moved_bucket, Path.basename(context.path)))
      File.ln_s!(moved_bucket, bucket)

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)
    end

    test "missing original cwd, non-native mapping and caller paths never select a workspace",
         context do
      File.rmdir!(context.cwd)

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      refute File.exists?(context.cwd)

      File.mkdir_p!(context.cwd)

      :ok =
        LemonCore.ChatStateStore.put(context.key, %LemonCore.ChatState{
          last_engine: "other",
          last_resume_token: context.session.header.id
        })

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      assert {:error, :forbidden} = ControlPlaneProvider.session_addressing_context(context.cwd)
    end

    test "ambiguous live roots, managed owners and actual children are refused", context do
      base = [
        cwd: context.cwd,
        workspace_dir: Path.join(context.cwd, "workspace"),
        session_key: context.key,
        register: true,
        model: Mocks.mock_model(),
        tools: []
      ]

      for id <- [:first, :second] do
        start_supervised!(Supervisor.child_spec({CodingAgent.Session, base}, id: id))
      end

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key)

      stop_supervised!(:first)
      stop_supervised!(:second)

      for {id, options} <- [
            managed: [native_managed_context: true],
            reserved_mcp: [
              native_managed_context: false,
              invocation_mcp_servers: [
                %{"url" => "https://bot.example/lemon_bot/invocations/run"}
              ]
            ],
            child: [session_scope: :subagent, task_child: true]
          ] do
        pid =
          start_supervised!(
            Supervisor.child_spec({CodingAgent.Session, Keyword.merge(base, options)}, id: id)
          )

        if id == :child do
          # A running worker sharing the key cannot shadow its stopped root.
          assert {:ok, %{resume: %{value: root_id}}} =
                   ControlPlaneProvider.session_addressing_context(context.key)

          assert root_id == context.session.header.id

          :ok =
            LemonCore.ChatStateStore.put(context.key, %LemonCore.ChatState{
              last_engine: "lemon",
              last_resume_token: CodingAgent.Session.get_state(pid).session_manager.header.id
            })
        end

        assert {:error, :forbidden} =
                 ControlPlaneProvider.session_addressing_context(context.key)

        stop_supervised!(id)
      end

      assert {:error, :forbidden} =
               ControlPlaneProvider.session_addressing_context(
                 "agent:default:lemon_bot:bot:dm:one"
               )

      assert {:error, :context_unavailable} =
               ControlPlaneProvider.session_addressing_context(context.key <> ":sub:missing")
    end

    test "cold managed run metadata refuses recovery instead of returning proof or MCP",
         context do
      run_id = "managed-context-#{LemonCore.Id.uuid()}"
      on_exit(fn -> LemonCore.RunStore.delete_session(context.key) end)

      {:ok, execution} =
        LemonCore.ExecutionContext.new(run_id: run_id, cwd: context.cwd, agent_id: "default")

      {:ok, session} =
        CodingAgent.SessionManager.append_execution_context(context.session, execution)

      :ok = CodingAgent.SessionManager.save_to_file(context.path, session)

      :ok =
        LemonCore.RunStore.finalize(run_id, %{
          session_key: context.key,
          meta: %{
            invocation_proof: "private-proof",
            invocation_context_key: "private-context",
            mcp_servers: [
              %{"url" => "https://bot.example/private", "headers" => %{"secret" => "x"}}
            ]
          }
        })

      assert {:error, :forbidden} =
               ControlPlaneProvider.session_addressing_context(context.key)
    end

    test "cold delegated execution authority is refused without projecting its context",
         context do
      {:ok, parent} =
        LemonCore.ExecutionContext.new(run_id: "parent", cwd: context.cwd, agent_id: "default")

      {:ok, child} = LemonCore.ExecutionContext.child(parent, run_id: "child")
      {:ok, session} = CodingAgent.SessionManager.append_execution_context(context.session, child)
      :ok = CodingAgent.SessionManager.save_to_file(context.path, session)

      assert {:error, :forbidden} =
               ControlPlaneProvider.session_addressing_context(context.key)
    end
  end

  describe "durable native session adapters" do
    setup do
      cwd = Path.join(System.tmp_dir!(), "provider-session-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      source_key = "source-#{LemonCore.Id.uuid()}"
      destination_key = "fork-#{LemonCore.Id.uuid()}"

      session =
        CodingAgent.SessionManager.new(cwd)
        |> CodingAgent.SessionManager.append_entry(
          SessionEntry.model_change("openai-codex", "gpt-6.1-sol")
        )
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "Decision: append-only JSONL"
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "Remembered"}]
        })
        |> CodingAgent.SessionManager.append_message(%{
          "role" => "user",
          "content" => "TODO: blue widgets"
        })

      path = Presentation.session_file_path(session.header.id, cwd)
      :ok = CodingAgent.SessionManager.save_to_file(path, session)

      :ok =
        LemonCore.ChatStateStore.put(source_key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: session.header.id
        })

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(source_key)
        LemonCore.ChatStateStore.delete(destination_key)
        File.rm_rf!(CodingAgent.Config.sessions_dir(cwd))
        File.rm_rf!(cwd)
      end)

      %{cwd: cwd, source: source_key, destination: destination_key, session: session, path: path}
    end

    test "a task child sharing the direct routing key cannot replace the durable root", context do
      alias CodingAgent.Tools.Task.Params

      opts =
        Params.build_session_opts(
          context.cwd,
          [session_key: context.source, child_run_id: "child-#{LemonCore.Id.uuid()}"],
          %{}
        )
        |> Keyword.put(:session_id, context.source)
        |> Keyword.put(:tools, [])

      child = start_supervised!({CodingAgent.Session, opts})
      child_owner = CodingAgent.Session.get_state(child).session_manager.header.id

      assert {:ok, snapshot} =
               ControlPlaneProvider.session_recovery_snapshot(context.source, context.cwd)

      assert snapshot.session_id == context.session.header.id
      refute snapshot.session_id == child_owner
    end

    for root_count <- [1, 2] do
      @tag timeout: 20_000
      test "recovery fails closed with an unresponsive owner among #{root_count} roots",
           context do
        roots =
          for index <- 1..unquote(root_count) do
            opts = [
              cwd: context.cwd,
              workspace_dir: Path.join(context.cwd, "workspace-#{index}"),
              session_key: context.source,
              register: true,
              model: Mocks.mock_model(),
              tools: []
            ]

            start_supervised!(Supervisor.child_spec({CodingAgent.Session, opts}, id: index))
          end

        blocked = hd(roots)
        :ok = :sys.suspend(blocked)

        try do
          assert {:error, :unavailable} =
                   ControlPlaneProvider.session_recovery_snapshot(context.source, context.cwd)
        after
          :ok = :sys.resume(blocked)
        end
      end
    end

    test "compaction rejects ambiguous roots instead of opening the durable owner", context do
      for index <- 1..2 do
        opts = [
          cwd: context.cwd,
          workspace_dir: Path.join(context.cwd, "workspace-#{index}"),
          session_key: context.source,
          register: true,
          model: Mocks.mock_model(),
          tools: []
        ]

        start_supervised!(Supervisor.child_spec({CodingAgent.Session, opts}, id: index))
      end

      assert {:error, :unavailable} =
               ControlPlaneProvider.compact_session(context.source, cwd: context.cwd)

      assert {:error, :unavailable} =
               ControlPlaneProvider.session_recovery_snapshot(context.source, context.cwd)
    end

    @tag timeout: 20_000
    test "compaction cannot bypass an unavailable native owner through a direct registration",
         context do
      start_supervised!({DirectCompactSession, {self(), context.source}})

      root =
        start_supervised!(
          {CodingAgent.Session,
           [
             cwd: context.cwd,
             workspace_dir: Path.join(context.cwd, "workspace"),
             session_key: context.source,
             register: true,
             model: Mocks.mock_model(),
             tools: []
           ]}
        )

      :ok = :sys.suspend(root)

      try do
        assert {:error, :unavailable} =
                 ControlPlaneProvider.compact_session(context.source, cwd: context.cwd)

        refute_received {:direct_compact, _}
      after
        :ok = :sys.resume(root)
      end
    end

    test "fork creates a distinct resume token and replays independent history", context do
      assert :ok =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)

      child = LemonCore.ChatStateStore.get(context.destination)
      assert child.last_engine == "lemon"
      refute child.last_resume_token == context.session.header.id

      assert {:ok, entries} =
               ControlPlaneProvider.session_history(context.destination, context.cwd)

      child_path =
        Presentation.session_file_path(child.last_resume_token, context.cwd)

      assert {:ok, child_session} = CodingAgent.SessionManager.load_from_file(child_path)
      assert entries == CodingAgent.SessionManager.get_branch(child_session)

      assert CodingAgent.SessionManager.build_session_context(child_session) ==
               CodingAgent.SessionManager.build_session_context(context.session)

      assert BudgetLedger.restore(child_session) ==
               BudgetLedger.restore(context.session)

      assert {:error, :destination_exists} =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)
    end

    test "todo projections follow live navigation, cache loss, durable resume and fork",
         context do
      opts = [
        cwd: context.cwd,
        workspace_dir: Path.join(context.cwd, "workspace"),
        session_file: context.path,
        session_key: context.source,
        model: Mocks.mock_model(),
        tools: []
      ]

      pid = start_supervised!({CodingAgent.Session, opts})
      empty_leaf = CodingAgent.Session.get_state(pid).session_manager.leaf_id

      first =
        TodoWrite.execute(
          "first",
          %{
            "todos" => [
              %{"id" => "done", "content" => "Done", "status" => "completed"},
              %{"id" => "next", "content" => "Next", "status" => "pending"}
            ]
          },
          nil,
          nil,
          pid
        )

      assert %LemonAgent.Types.AgentToolResult{} = first
      first_leaf = CodingAgent.Session.get_state(pid).session_manager.leaf_id
      native_id = context.session.header.id
      TodoStore.delete(native_id)
      TodoStore.put(context.source, [%{"status" => "completed"}])

      assert {:ok, first_todos, _} =
               ControlPlaneProvider.session_todos(context.source, context.cwd)

      assert first_todos == first.details.todos

      assert %{total: 2, completed: 1, actionable_count: 1} =
               ControlPlaneProvider.todo_progress(context.source)

      assert :ok =
               CodingAgent.Session.navigate_tree(pid, empty_leaf, summarize_abandoned: false)

      assert {:ok, [], _} = ControlPlaneProvider.session_todos(context.source, context.cwd)
      assert %{total: 0, actionable_count: 0} = ControlPlaneProvider.todo_progress(context.source)

      assert :ok =
               CodingAgent.Session.navigate_tree(pid, first_leaf, summarize_abandoned: false)

      stop_supervised!(CodingAgent.Session)
      TodoStore.delete(native_id)

      assert {:ok, ^first_todos, {0, ^first_leaf}} =
               ControlPlaneProvider.session_todos(context.source, context.cwd)

      assert %{total: 2, completed: 1, actionable_count: 1} =
               ControlPlaneProvider.todo_progress(context.source)

      assert :ok =
               ControlPlaneProvider.session_fork(context.source, context.cwd, context.destination)

      assert {:ok, ^first_todos, _} =
               ControlPlaneProvider.session_todos(context.destination, context.cwd)

      resumed = start_supervised!({CodingAgent.Session, opts})
      assert {:ok, ^first_todos, _} = CodingAgent.Session.todos(resumed)

      assert %LemonAgent.Types.AgentToolResult{} =
               TodoWrite.execute("clear", %{"todos" => []}, nil, nil, resumed)

      assert {:ok, [], _} = ControlPlaneProvider.session_todos(context.source, context.cwd)

      assert {:ok, ^first_todos, _} =
               ControlPlaneProvider.session_todos(context.destination, context.cwd)

      TodoStore.delete(context.source)
      TodoStore.delete(native_id)
    end

    test "manual compaction works after the native session process has stopped", context do
      assert :ok =
               ControlPlaneProvider.compact_session(context.source,
                 cwd: context.cwd,
                 summary: "Decision: append-only JSONL",
                 keep_recent_tokens: 5
               )

      assert {:ok, session} = CodingAgent.SessionManager.load_from_file(context.path)
      assert Enum.any?(CodingAgent.SessionManager.get_branch(session), &(&1.type == :compaction))
    end

    for history <- [:known, :missing_usage] do
      test "durable context usage preserves #{history} branch accounting", context do
        assistant = %LemonAi.Types.AssistantMessage{
          role: :assistant,
          content: [%LemonAi.Types.TextContent{text: "Counted."}],
          stop_reason: :stop,
          timestamp: 1,
          usage: %LemonAi.Types.Usage{
            input: 700,
            output: 80,
            cache_read: 300,
            cache_write: 20,
            total_tokens: 1_100,
            cost: %LemonAi.Types.Cost{total: 0.0375}
          }
        }

        session =
          if unquote(history) == :known do
            # Use the same durable identity with a complete history. Merely
            # switching branches would still include unknown cumulative spend.
            session = CodingAgent.SessionManager.new(context.cwd)

            %{session | header: context.session.header}
            |> CodingAgent.SessionManager.append_entry(
              SessionEntry.model_change("openai-codex", "gpt-6.1-sol")
            )
          else
            context.session
          end

        session =
          CodingAgent.SessionManager.append_message(
            session,
            MessageSerialization.serialize_message(assistant)
          )

        :ok = CodingAgent.SessionManager.save_to_file(context.path, session)

        assert {:ok, report} =
                 ControlPlaneProvider.session_context_usage(context.source, context.cwd)

        assert report.live == false

        if unquote(history) == :known do
          assert report.usage.input == 700
          assert report.usage.output == 80
          assert report.usage.cache_read == 300
          assert report.usage.cache_write == 20
          assert report.usage.assistant_messages == 1
          assert report.usage.tokens == 1_100
          assert report.usage.cost_usd == 0.0375
        else
          # Missing history is not a zero-cost, zero-token provider call.
          assert is_nil(report.usage.input)
          assert is_nil(report.usage.output)
          assert is_nil(report.usage.cache_read)
          assert is_nil(report.usage.cache_write)
          assert report.usage.assistant_messages == 2
          assert is_nil(report.usage.tokens)
          assert is_nil(report.usage.cost_usd)
        end
      end
    end
  end
end
