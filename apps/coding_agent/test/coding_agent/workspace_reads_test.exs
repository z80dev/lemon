defmodule CodingAgent.WorkspaceReadsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Task.Params
  alias CodingAgent.{Session, SessionManager, SettingsManager, ToolExecutor, WorkspaceReads}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.{ProfileStore, ToolPolicy}

  @moduletag :tmp_dir

  defmodule FenceSession do
    @moduledoc false
    use GenServer

    def start(session_id, reply) do
      GenServer.start(__MODULE__, {session_id, reply})
    end

    @impl true
    def init({session_id, reply}) do
      {:ok, _} = Registry.register(CodingAgent.SessionRegistry, session_id, %{})
      # Mirrors what `Session.Lifecycle` records at initialization.
      :ok = WorkspaceReads.register_session(session_id, false)
      {:ok, %{session_id: session_id, reply: reply}}
    end

    @impl true
    def handle_call(:record_workspace_read_fence, _from, state) do
      if state.reply == :ok, do: WorkspaceReads.set_fenced(state.session_id)
      {:reply, state.reply, state}
    end
  end

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: Path.join(tmp, ".lemon"))

    if :ets.whereis(:coding_agent_workspace_read_fence) == :undefined do
      start_supervised!(WorkspaceReads)
    end

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    profile_id = "test-bot"
    {:ok, paths} = ProfileStore.paths(profile_id)
    files_root = paths["files"]
    File.mkdir_p!(files_root)

    ctx = %{
      bot_folder_root: files_root,
      workspace_scope_root: files_root,
      native_source_profile_id: profile_id,
      cwd: files_root,
      session_id: "session-#{System.unique_integer([:positive])}"
    }

    %{files_root: files_root, profile_id: profile_id, policy: exempt_policy(), ctx: ctx, tmp: tmp}
  end

  defp exempt_policy(value \\ true) do
    opts = [require_approval: ["read", "ls", "grep"]]
    opts = if is_nil(value), do: opts, else: Keyword.put(opts, :workspace_read_exempt, value)
    ToolPolicy.custom(opts)
  end

  defp text_result(text), do: %AgentToolResult{content: [%TextContent{text: text}]}

  defp fence_session(session_id, reply \\ :ok) do
    {:ok, pid} = FenceSession.start(session_id, reply)
    ExUnit.Callbacks.on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  defp real_session(root, opts \\ []) do
    settings = SettingsManager.load(root)
    settings = %{settings | tools: Map.put(settings.tools, :wasm, %{enabled: false})}

    defaults = [
      cwd: root,
      workspace_dir: Path.join(root, "workspace"),
      model: LemonAgent.Test.Mocks.mock_model(),
      settings_manager: settings,
      system_prompt: "Test.",
      tools: [],
      register: true
    ]

    start_supervised!(
      Supervisor.child_spec({Session, Keyword.merge(defaults, opts)},
        id: make_ref(),
        restart: :temporary
      )
    )
  end

  describe "exempt?/4" do
    test "exempts read, ls and grep inside the folder", %{
      files_root: root,
      policy: policy,
      ctx: ctx
    } do
      file = Path.join(root, "safe.txt")
      File.write!(file, "hello safe file")

      assert WorkspaceReads.exempt?(policy, "read", %{"path" => "safe.txt"}, ctx)
      assert WorkspaceReads.exempt?(policy, "read", %{"path" => file}, ctx)
      assert WorkspaceReads.exempt?(policy, "read", %{"path" => "safe.txt:1-5"}, ctx)
      assert WorkspaceReads.exempt?(policy, "read", %{"path" => "safe.txt:raw"}, ctx)

      assert WorkspaceReads.exempt?(policy, "ls", %{"path" => "."}, ctx)
      assert WorkspaceReads.exempt?(policy, "ls", %{"path" => root}, ctx)

      if CodingAgent.Tools.Grep.ripgrep_available?() do
        assert WorkspaceReads.exempt?(
                 policy,
                 "grep",
                 %{"pattern" => "x", "path" => "safe.txt"},
                 ctx
               )

        refute WorkspaceReads.exempt?(policy, "grep", %{"pattern" => "x", "path" => "."}, ctx)
      end
    end

    test "refuses targets outside the folder", %{policy: policy, ctx: ctx, tmp: tmp} do
      outside = Path.join(tmp, "outside.txt")
      File.write!(outside, "secret outside")

      refute WorkspaceReads.exempt?(policy, "read", %{"path" => outside}, ctx)
      refute WorkspaceReads.exempt?(policy, "read", %{"path" => "../config.toml"}, ctx)
      refute WorkspaceReads.exempt?(policy, "ls", %{"path" => tmp}, ctx)
    end

    test "refuses symlinks leaving the folder", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      outside = Path.join(tmp, "secret.txt")
      File.write!(outside, "outside secret")
      File.ln_s!(outside, Path.join(root, "link_out.txt"))

      refute WorkspaceReads.exempt?(policy, "read", %{"path" => "link_out.txt"}, ctx)
    end

    test "accepts symlinks that stay inside the folder", %{
      files_root: root,
      policy: policy,
      ctx: ctx
    } do
      real = Path.join(root, "real.txt")
      File.write!(real, "inside content")
      File.ln_s!(real, Path.join(root, "link_in.txt"))

      assert WorkspaceReads.exempt?(policy, "read", %{"path" => "link_in.txt"}, ctx)
    end

    test "refuses hard-linked regular files", %{files_root: root, policy: policy, ctx: ctx} do
      original = Path.join(root, "original.txt")
      File.write!(original, "content")
      File.ln!(original, Path.join(root, "hardlink.txt"))

      assert File.stat!(original).links >= 2
      refute WorkspaceReads.exempt?(policy, "read", %{"path" => "original.txt"}, ctx)
      refute WorkspaceReads.exempt?(policy, "read", %{"path" => "hardlink.txt"}, ctx)
    end

    test "grep refuses hard links and all directory discovery scopes", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      outside = Path.join(tmp, "private.txt")
      File.write!(outside, "private bytes")
      File.mkdir_p!(Path.join(root, "nested/deep"))
      File.ln!(outside, Path.join(root, "nested/deep/linked.txt"))
      File.write!(Path.join(root, "safe.txt"), "safe")

      for path <- ["nested/deep/linked.txt", "nested/deep", "nested", ".", "safe.txt;nested"] do
        refute WorkspaceReads.exempt?(
                 policy,
                 "grep",
                 %{"pattern" => "private", "path" => path},
                 ctx
               )
      end
    end

    test "memory aliases check the execution workspace, not same-named folder files", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      workspace = Path.join(tmp, "workspace")
      ctx = Map.put(ctx, :workspace_dir, workspace)

      for base <- [root, workspace] do
        File.mkdir_p!(Path.join(base, "memory"))

        for path <- ["MEMORY.md", "USER.md", "memory/note.md"] do
          File.write!(Path.join(base, path), base)
        end
      end

      for path <- ["MEMORY.md", "USER.md", "memory/note.md"] do
        refute WorkspaceReads.exempt?(policy, "read", %{"path" => path}, ctx)
        refute WorkspaceReads.exempt?(policy, "read", %{"path" => path <> ":1:raw"}, ctx)
        refute WorkspaceReads.exempt?(policy, "grep", %{"path" => path}, ctx)
        assert WorkspaceReads.exempt?(policy, "read", %{"path" => "./" <> path}, ctx)
      end

      refute WorkspaceReads.exempt?(policy, "grep", %{"path" => "memory"}, ctx)
      # Literal colon-bearing names still take precedence over selectors.
      File.write!(Path.join(root, "MEMORY.md:raw"), "literal")
      assert WorkspaceReads.exempt?(policy, "read", %{"path" => "MEMORY.md:raw"}, ctx)
    end

    test "canonicalization errors and exhausted link chains deny every exemption", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "private")

      for n <- 0..32 do
        target = if n == 32, do: outside, else: Path.join(root, "hop-#{n + 1}")
        File.ln_s!(target, Path.join(root, "hop-#{n}"))
      end

      File.ln_s!("cycle", Path.join(root, "cycle"))
      File.ln_s!("missing", Path.join(root, "dangling"))

      assert {:error, :eloop} = WorkspaceReads.realpath(Path.join(root, "hop-0"))
      assert {:error, :eloop} = WorkspaceReads.realpath(Path.join(root, "cycle"))
      assert {:error, :enoent} = WorkspaceReads.realpath(Path.join(root, "dangling"))

      for path <- ["hop-0/secret.txt", "cycle", "dangling", "missing"],
          tool <- ["read", "ls", "grep"] do
        refute WorkspaceReads.exempt?(policy, tool, %{"path" => path}, ctx)
      end

      refute WorkspaceReads.exempt?(policy, "ls", %{"path" => "."}, %{
               ctx
               | bot_folder_root: Path.join(root, "cycle")
             })
    end

    test "refuses internal URLs", %{policy: policy, ctx: ctx} do
      for url <- [
            "issue://123",
            "pr://456",
            "history://task-789",
            "proc://bash-1",
            "agent://worker-1",
            "skill://weather",
            "local://temp.md"
          ] do
        refute WorkspaceReads.exempt?(policy, "read", %{"path" => url}, ctx)
        refute WorkspaceReads.exempt?(policy, "ls", %{"path" => url}, ctx)
        refute WorkspaceReads.exempt?(policy, "grep", %{"pattern" => "x", "path" => url}, ctx)
      end
    end

    test "find never qualifies", %{files_root: root, policy: policy, ctx: ctx} do
      File.write!(Path.join(root, "safe.txt"), "content")

      refute WorkspaceReads.exempt?(policy, "find", %{"path" => "."}, ctx)
      refute WorkspaceReads.exempt?(policy, "find", %{"path" => "safe.txt"}, ctx)
    end

    test "requires a trusted worker-derived root equal to the profile files root", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      file = Path.join(root, "safe.txt")
      File.write!(file, "content")

      refute WorkspaceReads.exempt?(policy, "read", %{"path" => file}, %{
               ctx
               | bot_folder_root: tmp
             })

      refute WorkspaceReads.exempt?(
               policy,
               "read",
               %{"path" => file},
               Map.delete(ctx, :bot_folder_root)
             )

      refute WorkspaceReads.exempt?(
               policy,
               "read",
               %{"path" => file},
               %{ctx | native_source_profile_id: "../escape"}
             )

      refute WorkspaceReads.exempt?(
               policy,
               "read",
               %{"path" => file},
               Map.delete(ctx, :native_source_profile_id)
             )
    end

    test "requires the bound execution-context workspace scope", %{
      files_root: root,
      policy: policy,
      ctx: ctx,
      tmp: tmp
    } do
      file = Path.join(root, "safe.txt")
      File.write!(file, "content")

      refute WorkspaceReads.exempt?(
               policy,
               "read",
               %{"path" => file},
               Map.delete(ctx, :workspace_scope_root)
             )

      refute WorkspaceReads.exempt?(policy, "read", %{"path" => file}, %{
               ctx
               | workspace_scope_root: tmp
             })

      execution_ctx =
        ctx
        |> Map.delete(:workspace_scope_root)
        |> Map.put(:execution_context, %{workspace_scope: %{root: root}})

      assert WorkspaceReads.exempt?(policy, "read", %{"path" => file}, execution_ctx)
    end

    test "requires the policy key to be true", %{files_root: root, ctx: ctx} do
      file = Path.join(root, "safe.txt")
      File.write!(file, "content")

      refute WorkspaceReads.exempt?(exempt_policy(false), "read", %{"path" => file}, ctx)
      refute WorkspaceReads.exempt?(exempt_policy(nil), "read", %{"path" => file}, ctx)
    end
  end

  describe "fence!/1 and fenced?/1" do
    test "fails closed without a reachable session" do
      session_id = "orphan-#{System.unique_integer([:positive])}"

      assert WorkspaceReads.fence!(session_id) == {:error, :session_unavailable}
      assert WorkspaceReads.fence!(%{session_id: session_id}) == {:error, :session_unavailable}
      assert WorkspaceReads.fence!(%{}) == {:error, :session_unavailable}
      refute WorkspaceReads.fenced?(session_id)
    end

    test "fails closed when the journal write fails" do
      session_id = "unwritable-#{System.unique_integer([:positive])}"
      fence_session(session_id, {:error, :journal_write_failed})

      assert WorkspaceReads.fence!(session_id) == {:error, :journal_write_failed}
      refute WorkspaceReads.fenced?(session_id)
    end

    test "mirrors a durable fence in ETS for lock-free checks" do
      session_id = "fence-#{System.unique_integer([:positive])}"
      fence_session(session_id)

      assert WorkspaceReads.fence!(session_id) == :ok
      assert WorkspaceReads.fenced?(session_id)
      assert WorkspaceReads.fenced?(%{session_id: session_id})
    end

    test "a live session whose mirror was lost reads as fenced" do
      session_id = "mirror-loss-#{System.unique_integer([:positive])}"
      fence_session(session_id)
      refute WorkspaceReads.fenced?(session_id)

      # The ETS owner restarted: every row recorded at session initialization
      # is gone, so the state of this still-live session is unknown.
      :ets.delete_all_objects(:coding_agent_workspace_read_fence)

      assert WorkspaceReads.fenced?(session_id)
      assert WorkspaceReads.fenced?(%{session_id: session_id})
    end

    test "an unknown dead session id stays unfenced" do
      session_id = "dead-#{System.unique_integer([:positive])}"
      pid = fence_session(session_id)
      :ok = GenServer.stop(pid)
      :ets.delete_all_objects(:coding_agent_workspace_read_fence)

      refute WorkspaceReads.fenced?(session_id)
    end

    test "restores from the persisted journal entry", %{files_root: root, tmp: tmp} do
      session_id = "restore-#{System.unique_integer([:positive])}"
      session_file = Path.join(tmp, "#{session_id}.jsonl")

      SessionManager.new(root, id: session_id)
      |> SessionManager.append_entry(
        SessionManager.SessionEntry.custom(WorkspaceReads.fence_entry_type(), %{
          "fenced" => true,
          "timestamp" => System.system_time(:millisecond)
        })
      )
      |> SessionManager.persist(session_file)

      :ets.delete(:coding_agent_workspace_read_fence, session_id)
      refute WorkspaceReads.fenced?(session_id)

      assert {:ok, restored} = SessionManager.load_from_file(session_file)
      assert SessionManager.latest_custom_entry(restored, WorkspaceReads.fence_entry_type())

      assert WorkspaceReads.set_fenced(restored.header.id) == :ok
      assert WorkspaceReads.fenced?(session_id)
    end

    test "task children inherit the parent fence", %{files_root: root, policy: policy} do
      parent_id = "parent-#{System.unique_integer([:positive])}"
      fence_session(parent_id)
      assert WorkspaceReads.fence!(parent_id) == :ok

      child_opts =
        Params.build_session_opts(
          root,
          [parent_session: parent_id, cwd: root, tool_policy: policy],
          %{tool_policy: policy}
        )

      assert Keyword.get(child_opts, :workspace_read_fenced) == true
    end

    test "unfenced parents do not fence children", %{files_root: root, policy: policy} do
      parent_id = "clean-parent-#{System.unique_integer([:positive])}"
      refute WorkspaceReads.fenced?(parent_id)

      child_opts =
        Params.build_session_opts(
          root,
          [parent_session: parent_id, cwd: root, tool_policy: policy],
          %{tool_policy: policy}
        )

      refute Keyword.has_key?(child_opts, :workspace_read_fenced)
    end

    test "child reads durably fence ancestors before sync or async output is exposed", %{
      files_root: root,
      policy: policy,
      ctx: ctx
    } do
      File.write!(Path.join(root, "data.txt"), "private child content")
      grandparent = real_session(root)
      grandparent_state = Session.get_state(grandparent)
      parent = real_session(root, parent_session: grandparent_state.session_manager.header.id)
      parent_state = Session.get_state(parent)
      parent_id = parent_state.session_manager.header.id
      sibling = real_session(root, parent_session: parent_id)
      child = real_session(root, parent_session: parent_id)
      child_id = Session.get_state(child).session_manager.header.id
      observer = self()

      web_policy = exempt_policy(nil)

      web_tools =
        for session <- [grandparent, parent, sibling],
            name <- ["webfetch", "websearch"] do
          id = Session.get_state(session).session_manager.header.id

          context = %{
            session_id: id,
            approval_request_fun: fn _ ->
              send(observer, {:web_approval, id, name})
              {:ok, :denied}
            end
          }

          tool = %AgentTool{
            name: name,
            description: "Web",
            parameters: %{},
            execute: fn _, _, _, _ -> flunk("unreviewed web egress") end
          }

          {id, name, ToolExecutor.wrap_with_approval(tool, web_policy, context)}
        end

      context =
        ctx
        |> Map.put(:session_id, child_id)
        |> Map.put(:approval_request_fun, fn _ -> flunk("safe child read asked") end)

      tool = CodingAgent.Tools.Read.tool(root)
      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

      for mode <- [:sync, :async] do
        result =
          if mode == :sync do
            wrapped.execute.("read-sync", %{"path" => "data.txt"}, nil, nil)
          else
            Task.async(fn ->
              wrapped.execute.("read-async", %{"path" => "data.txt"}, nil, nil)
            end)
            |> Task.await()
          end

        assert Enum.any?(result.content, &String.contains?(&1.text, "private child content"))

        for state <- [grandparent_state, parent_state] do
          assert {:ok, journal} = SessionManager.load_from_file(state.session_file)
          assert SessionManager.latest_custom_entry(journal, WorkspaceReads.fence_entry_type())
        end

        for {id, name, web} <- web_tools do
          web.execute.("web", %{}, nil, nil)
          assert_received {:web_approval, ^id, ^name}
        end
      end

      GenServer.stop(parent)
      :ets.delete(:coding_agent_workspace_read_fence, parent_id)
      restored = real_session(root, session_file: parent_state.session_file)
      assert WorkspaceReads.fenced?(restored)
    end

    test "unreachable or unwritable ancestors refuse the child's exemption", %{
      files_root: root
    } do
      for reply <- [:missing, {:error, :journal_write_failed}] do
        parent_id = "unavailable-parent-#{System.unique_integer([:positive])}"
        if reply != :missing, do: fence_session(parent_id, reply)
        child = real_session(root, parent_session: parent_id)

        assert {:error, reason} = WorkspaceReads.fence!(child)
        assert reason in [:session_unavailable, :journal_write_failed]
        manager = Session.get_state(child).session_manager
        refute SessionManager.latest_custom_entry(manager, WorkspaceReads.fence_entry_type())
      end
    end

    test "registration cannot clear a fence or detach an existing descendant" do
      parent = "monotonic-parent-#{System.unique_integer([:positive])}"
      child = "monotonic-child-#{System.unique_integer([:positive])}"
      :ok = WorkspaceReads.register_session(parent, true)
      :ok = WorkspaceReads.register_session(child, false, parent)
      :ok = WorkspaceReads.register_session(child, false)
      :ok = WorkspaceReads.register_session(parent, false)
      assert WorkspaceReads.fenced?(parent)
      assert WorkspaceReads.fenced?(child)
    end
  end

  test "approval and execution bind the redirected memory target in both wrappers", %{
    files_root: root,
    policy: policy,
    ctx: ctx,
    tmp: tmp
  } do
    workspace = Path.join(tmp, "private-workspace")
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.mkdir_p!(Path.join(root, "memory"))
    observer = self()

    for path <- ["MEMORY.md", "USER.md", "memory/note.md"] do
      File.write!(Path.join(root, path), "decoy")
      File.write!(Path.join(workspace, path), "actual workspace bytes")
    end

    File.write!(Path.join(workspace, "SOUL.md"), "bootstrap fallback bytes")

    context =
      ctx
      |> Map.put(:workspace_dir, workspace)
      |> Map.put(:approval_request_fun, fn request ->
        send(observer, {:approval_target, request.action["path"]})
        {:ok, :approved, :once}
      end)

    fence_session(ctx.session_id)

    direct =
      CodingAgent.Tools.Read.tool(root, workspace_dir: workspace)
      |> ToolExecutor.wrap_with_approval(policy, context)

    [registry] =
      CodingAgent.ToolRegistry.get_tools(root,
        enabled_only: [:read],
        include_extensions: false,
        include_mcp: false,
        tool_policy: policy,
        workspace_dir: workspace,
        approval_context: Map.put(context, :workspace_dir, root)
      )

    for tool <- [direct, registry],
        path <- ["MEMORY.md", "USER.md", "memory/note.md"],
        selector <- ["", ":1:raw"] do
      expected = Path.join(workspace, path) <> selector
      result = tool.execute.("memory-read", %{"path" => path <> selector}, nil, nil)
      assert_received {:approval_target, ^expected}
      assert Enum.any?(result.content, &String.contains?(&1.text, "actual workspace bytes"))
      refute WorkspaceReads.fenced?(ctx.session_id)
    end

    for tool <- [direct, registry] do
      expected = Path.join(workspace, "SOUL.md")
      result = tool.execute.("bootstrap-read", %{"path" => "SOUL.md"}, nil, nil)
      assert_received {:approval_target, ^expected}
      assert Enum.any?(result.content, &String.contains?(&1.text, "bootstrap fallback bytes"))
      refute WorkspaceReads.fenced?(ctx.session_id)
    end
  end

  describe "ToolExecutor integration" do
    setup %{ctx: ctx} do
      parent = self()

      context =
        Map.put(ctx, :approval_request_fun, fn _request ->
          send(parent, :approval_requested)
          {:ok, :approved, :once}
        end)

      read_tool = %AgentTool{
        name: "read",
        description: "Read a file",
        parameters: %{"type" => "object"},
        execute: fn _id, _params, _signal, _update ->
          send(parent, :tool_executed)
          text_result("hello")
        end
      }

      %{context: context, read_tool: read_tool}
    end

    test "an exempt read skips approval once the fence is durable", %{
      files_root: root,
      policy: policy,
      context: context,
      read_tool: tool
    } do
      File.write!(Path.join(root, "file.txt"), "hello")
      fence_session(context.session_id)

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)
      wrapped.execute.("call-1", %{"path" => "file.txt"}, nil, nil)

      assert_received :tool_executed
      refute_received :approval_requested
      assert WorkspaceReads.fenced?(context.session_id)
    end

    test "an exempt read still asks when the fence cannot be persisted", %{
      files_root: root,
      policy: policy,
      context: context,
      read_tool: tool
    } do
      File.write!(Path.join(root, "file.txt"), "hello")
      fence_session(context.session_id, {:error, :journal_write_failed})

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)
      wrapped.execute.("call-2", %{"path" => "file.txt"}, nil, nil)

      assert_received :approval_requested
      assert_received :tool_executed
      refute WorkspaceReads.fenced?(context.session_id)
    end

    test "an exempt read still asks when no session can record the fence", %{
      files_root: root,
      policy: policy,
      context: context,
      read_tool: tool
    } do
      File.write!(Path.join(root, "file.txt"), "hello")

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)
      wrapped.execute.("call-3", %{"path" => "file.txt"}, nil, nil)

      assert_received :approval_requested
      refute WorkspaceReads.fenced?(context.session_id)
    end

    test "a non-exempt read still requests approval", %{
      policy: policy,
      context: context,
      read_tool: tool,
      tmp: tmp
    } do
      outside = Path.join(tmp, "outside.txt")
      File.write!(outside, "outside")
      fence_session(context.session_id)

      wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)
      wrapped.execute.("call-4", %{"path" => outside}, nil, nil)

      assert_received :approval_requested
      assert_received :tool_executed
      refute WorkspaceReads.fenced?(context.session_id)
    end

    test "webfetch and websearch require approval only after the fence", %{
      policy: policy,
      ctx: ctx
    } do
      parent = self()

      for name <- ["webfetch", "websearch"] do
        session_id = "#{ctx.session_id}-#{name}"
        fence_session(session_id)

        context =
          ctx
          |> Map.put(:session_id, session_id)
          |> Map.put(:approval_request_fun, fn _request ->
            send(parent, {:approval_requested, name})
            {:ok, :approved, :once}
          end)

        tool = %AgentTool{
          name: name,
          description: "External access",
          parameters: %{"type" => "object"},
          execute: fn _id, _params, _signal, _update ->
            send(parent, {:executed, name})
            text_result("page")
          end
        }

        wrapped = ToolExecutor.wrap_with_approval(tool, policy, context)

        refute WorkspaceReads.fenced?(session_id)
        wrapped.execute.("call-web-1", %{"url" => "https://example.com"}, nil, nil)
        assert_received {:executed, ^name}
        refute_received {:approval_requested, ^name}

        assert WorkspaceReads.fence!(session_id) == :ok

        wrapped.execute.("call-web-2", %{"url" => "https://example.com"}, nil, nil)
        assert_received {:approval_requested, ^name}
        assert_received {:executed, ^name}
      end
    end

    test "a fenced session keeps the web gate under a narrowed policy", %{ctx: ctx} do
      parent = self()
      session_id = "narrowed-#{System.unique_integer([:positive])}"
      fence_session(session_id)
      assert WorkspaceReads.fence!(session_id) == :ok

      context =
        ctx
        |> Map.put(:session_id, session_id)
        |> Map.put(:approval_request_fun, fn _request ->
          send(parent, :approval_requested)
          {:ok, :approved, :once}
        end)

      tool = %AgentTool{
        name: "webfetch",
        description: "External access",
        parameters: %{"type" => "object"},
        execute: fn _id, _params, _signal, _update ->
          send(parent, :tool_executed)
          text_result("page")
        end
      }

      # The child/reloaded policy no longer carries the exemption, but the
      # fence the session already earned must still gate web egress.
      wrapped = ToolExecutor.wrap_with_approval(tool, exempt_policy(nil), context)
      wrapped.execute.("call-web", %{"url" => "https://example.com"}, nil, nil)

      assert_received :approval_requested
      assert_received :tool_executed
    end
  end
end
