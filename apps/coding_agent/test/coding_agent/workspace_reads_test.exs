defmodule CodingAgent.WorkspaceReadsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Task.Params
  alias CodingAgent.{SessionManager, ToolExecutor, WorkspaceReads}
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

        assert WorkspaceReads.exempt?(policy, "grep", %{"pattern" => "x", "path" => "."}, ctx)
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
