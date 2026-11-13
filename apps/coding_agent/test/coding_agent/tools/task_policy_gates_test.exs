defmodule CodingAgent.Tools.TaskPolicyGatesTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager, ToolPolicy}
  alias CodingAgent.Session.Planning
  alias CodingAgent.Tools.Agent, as: DelegateTool
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.Params
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @plan_child_tools ~w(read grep find ls websearch webfetch ask_parent)

  describe "plan mode" do
    @tag :tmp_dir
    test "launches a scout with read-only tools and no delegation", %{tmp_dir: cwd} do
      owner = self()
      response = Mocks.mock_stream_fn_single(Mocks.assistant_message("Found it."))

      opts =
        plan_opts(
          model: "openai-codex:gpt-6.1-sol",
          stream_fn: fn model, context, options ->
            send(owner, {:child_context, context})
            response.(model, context, options)
          end
        )

      result =
        execute(cwd, opts, %{
          "prompt" => "Map the auth module.",
          "agent" => "scout",
          "tool_policy" => %{"allow" => "all"},
          "async" => false,
          "auto_followup" => false
        })

      assert result.details.status == "completed"
      assert_receive {:child_context, context}, 2_000
      names = Enum.map(context.tools, & &1.name)
      assert "read" in names
      assert Enum.all?(names, &(&1 in @plan_child_tools))
      assert context.system_prompt =~ "Plan mode is active in the parent session"

      # Reading owned children stays available in plan mode.
      fetched = execute(cwd, opts, %{"action" => "get", "task_id" => result.details.task_id})
      assert fetched.details.status == "completed"
    end

    @tag :tmp_dir
    test "coerces a default child to the read-only allowlist and strips spawns", %{tmp_dir: cwd} do
      opts = plan_opts(settings_manager: %SettingsManager{})

      assert {:ok, validated} =
               Params.validate_run_params(
                 %{
                   "prompt" => "Explore",
                   "tool_policy" => %{"allow" => ["bash", "read", "task"]}
                 },
                 cwd,
                 Params.launch_opts(cwd, opts)
               )

      assert validated.plan_mode
      assert validated.task_allowed_agents == []
      assert ToolPolicy.allowed?(validated.tool_policy, "read")

      for tool <- ~w(bash write edit task agent agent_message) do
        refute ToolPolicy.allowed?(validated.tool_policy, tool)
      end

      # Outside plan mode the same request keeps its requested tools.
      assert {:ok, normal} =
               Params.validate_run_params(
                 %{"prompt" => "Explore", "tool_policy" => %{"allow" => ["bash", "read"]}},
                 cwd,
                 settings_manager: %SettingsManager{}
               )

      assert ToolPolicy.allowed?(normal.tool_policy, "bash")
    end

    @tag :tmp_dir
    test "refuses worktrees, merge-back, write personas and messaging", %{tmp_dir: cwd} do
      opts = plan_opts(settings_manager: %SettingsManager{})

      assert {:error, message} =
               execute(cwd, opts, %{"prompt" => "Explore", "agent" => "scout", "worktree" => true})

      assert message =~ "Plan mode is active: task worktree and merge are unavailable"

      assert {:error, message} =
               execute(cwd, opts, %{"prompt" => "Implement", "agent" => "task-executor"})

      assert message =~ "subagent 'task-executor' can change files"

      assert {:error, message} =
               execute(cwd, opts, %{
                 "tasks" => [
                   %{"prompt" => "Look", "agent" => "scout"},
                   %{"prompt" => "Change", "agent" => "task-executor"}
                 ]
               })

      assert message =~ "task-executor"

      assert {:error, message} =
               execute(cwd, opts, %{
                 "action" => "swarm",
                 "tasks" => [%{"name" => "fix", "prompt" => "Change", "agent" => "sonic"}]
               })

      assert message =~ "subagent 'sonic' can change files"

      for action <- ["message", "steer"] do
        assert {:error, message} =
                 execute(cwd, opts, %{"action" => action, "to" => "agent://x", "message" => "go"})

        assert message =~ "Plan mode is active: task #{action} is blocked"
      end
    end

    test "the plan guard lets the self-gated task tool through and still blocks bash" do
      root = Path.join(System.tmp_dir!(), "plan-gate-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      manager = SessionManager.new(root)
      {:ok, _, manager} = Planning.transition(manager, :enter, [])
      parent = self()

      tools =
        for name <- ["task", "bash", "tool_invoke", "wait"] do
          %AgentTool{
            name: name,
            parameters: %{},
            execute: fn _id, params, _, _ ->
              send(parent, {:executed, name, params})
              %AgentToolResult{content: [%TextContent{text: "ok"}]}
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
      assert Planning.active?(context.gate)

      assert %AgentToolResult{is_error: false} = guarded["task"].execute.("t", %{}, nil, nil)
      assert_receive {:executed, "task", _}
      assert %AgentToolResult{is_error: false} = guarded["wait"].execute.("w", %{}, nil, nil)
      assert_receive {:executed, "wait", _}

      bridged = %{"name" => "task", "args" => %{"prompt" => "Look"}}

      assert %AgentToolResult{is_error: false} =
               guarded["tool_invoke"].execute.("b", bridged, nil, nil)

      assert_receive {:executed, "tool_invoke", ^bridged}

      assert %AgentToolResult{is_error: true} = guarded["bash"].execute.("x", %{}, nil, nil)
      refute_received {:executed, "bash", _}
    end

    @tag :tmp_dir
    test "a live session shares its plan gate with tool options", %{tmp_dir: cwd} do
      session =
        start_supervised!(
          {Session,
           cwd: cwd,
           workspace_dir: Path.join(cwd, "workspace"),
           session_mode: :chat,
           tools: [],
           extension_inventory: {[], []},
           mcp_tools: [],
           model: Mocks.mock_model(),
           stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))}
        )

      state = Session.get_state(session)
      assert state.tool_opts[:plan_gate] == state.plan_gate
      refute Params.plan_mode?(state.tool_opts)

      assert {:ok, %{"mode" => "plan"}} = Session.plan(session, :enter)
      assert Params.plan_mode?(Session.get_state(session).tool_opts)
      assert {:ok, %{"mode" => "code"}} = Session.plan(session, :exit)
      refute Params.plan_mode?(Session.get_state(session).tool_opts)
    end
  end

  describe "per-call model gate" do
    @tag :tmp_dir
    test "refuses model and thinking_level by default before any child starts", %{tmp_dir: cwd} do
      opts = [
        parent_session: unique_id(),
        settings_manager: %SettingsManager{},
        run_override: &ok/2
      ]

      assert {:error, message} =
               execute(cwd, opts, %{"prompt" => "x", "model" => "openai:gpt-4o"})

      assert message =~ "[runtime.task].per_call_model = \"off\""

      assert {:error, message} =
               execute(cwd, opts, %{
                 "tasks" => [%{"prompt" => "a"}, %{"prompt" => "b", "thinking_level" => "high"}]
               })

      assert message =~ "Per-call thinking_level is disabled"

      assert {:error, _} =
               execute(cwd, opts, %{
                 "action" => "swarm",
                 "model" => "@smol",
                 "tasks" => [%{"name" => "a", "prompt" => "a"}]
               })

      # An empty selector counts as omitted.
      assert %AgentToolResult{} =
               execute(cwd, opts, %{"prompt" => "x", "model" => " ", "auto_followup" => false})

      tool = TaskTool.tool(cwd, opts)
      assert tool.parameters["properties"]["model"]["description"] =~ "Disabled by operator"
    end

    @tag :tmp_dir
    test "allows only allowlisted models when enabled", %{tmp_dir: cwd} do
      settings = gate_settings("on", ["openai/gpt-4o", "@smol"])
      opts = [parent_session: unique_id(), settings_manager: settings, run_override: &ok/2]

      for model <- ["openai/gpt-4o", "openai:gpt-4o", "@smol"] do
        assert %AgentToolResult{} =
                 execute(cwd, opts, %{"prompt" => "x", "model" => model, "auto_followup" => false})
      end

      assert {:error, message} =
               execute(cwd, opts, %{
                 "tasks" => [
                   %{"prompt" => "a", "model" => "@smol"},
                   %{"prompt" => "b", "model" => "@slow"}
                 ]
               })

      assert message =~ ~s(Model "@slow" is not in [runtime.task].per_call_model_allow)
      assert message =~ "openai/gpt-4o, @smol"

      assert %AgentToolResult{} =
               execute(cwd, opts, %{
                 "prompt" => "x",
                 "thinking_level" => "high",
                 "auto_followup" => false
               })

      description = TaskTool.tool(cwd, opts).parameters["properties"]["model"]["description"]
      assert description =~ "One of openai/gpt-4o, @smol"

      unrestricted = [
        parent_session: unique_id(),
        settings_manager: gate_settings("on", nil),
        run_override: &ok/2
      ]

      assert %AgentToolResult{} =
               execute(cwd, unrestricted, %{
                 "prompt" => "x",
                 "model" => "@slow",
                 "auto_followup" => false
               })
    end

    @tag :tmp_dir
    test "persona and agent_models defaults are not per-call selections", %{tmp_dir: cwd} do
      settings = %SettingsManager{
        task: %{%SettingsManager{}.task | agent_models: %{"scout" => "@slow"}}
      }

      assert :ok =
               Params.check_per_call_model(%{"prompt" => "x", "agent" => "scout"}, cwd,
                 settings_manager: settings
               )

      assert {:ok, %{model: "@slow", model_explicit: false}} =
               Params.validate_run_params(%{"prompt" => "x", "agent" => "scout"}, cwd,
                 settings_manager: settings
               )
    end

    @tag :tmp_dir
    test "a project config cannot widen the operator's gate", %{tmp_dir: cwd} do
      global = Path.join(System.get_env("HOME"), ".lemon/config.toml")
      File.mkdir_p!(Path.dirname(global))
      previous = if File.exists?(global), do: File.read!(global)

      on_exit(fn ->
        if previous, do: File.write!(global, previous), else: File.rm(global)
        LemonCore.Config.reload(cwd)
      end)

      File.write!(
        global,
        "[runtime.task]\nper_call_model = \"on\"\nper_call_model_allow = [\"openai/gpt-4o\"]\n"
      )

      File.mkdir_p!(Path.join(cwd, ".lemon"))

      File.write!(
        Path.join(cwd, ".lemon/config.toml"),
        "[runtime.task]\nper_call_model = \"on\"\nper_call_model_allow = [\"openai/gpt-4o\", \"anthropic/claude-opus-4\"]\n"
      )

      LemonCore.Config.reload(cwd)
      opts = [settings_manager: SettingsManager.load(cwd)]

      assert :ok = Params.check_per_call_model(%{"model" => "openai/gpt-4o"}, cwd, opts)

      assert {:error, message} =
               Params.check_per_call_model(%{"model" => "anthropic/claude-opus-4"}, cwd, opts)

      assert message =~ "not in [runtime.task].per_call_model_allow (openai/gpt-4o)"

      File.write!(global, "[runtime.task]\nper_call_model = \"off\"\n")
      LemonCore.Config.reload(cwd)

      assert {:error, message} =
               Params.check_per_call_model(%{"model" => "openai/gpt-4o"}, cwd,
                 settings_manager: SettingsManager.load(cwd)
               )

      assert message =~ "per_call_model = \"off\""
    end

    @tag :tmp_dir
    test "the agent tool applies the same gate to its model", %{tmp_dir: cwd} do
      opts = [settings_manager: %SettingsManager{}]

      assert {:error, message} =
               DelegateTool.execute(
                 "id",
                 %{"agent_id" => "default", "prompt" => "x", "model" => "openai:gpt-4o"},
                 nil,
                 nil,
                 cwd,
                 opts
               )

      assert message =~ "per_call_model = \"off\""

      assert DelegateTool.tool(cwd, opts).parameters["properties"]["model"]["description"] =~
               "Disabled by operator"
    end
  end

  defp plan_opts(extra) do
    gate = Planning.new_gate()
    :atomics.put(gate, 1, 1)
    Keyword.merge([parent_session: unique_id(), plan_gate: gate], extra)
  end

  defp gate_settings(mode, allow) do
    %SettingsManager{
      task: %{%SettingsManager{}.task | per_call_model: mode, per_call_model_allow: allow}
    }
  end

  defp ok(_, _), do: %AgentToolResult{content: [%TextContent{text: "done"}], details: %{}}
  defp execute(cwd, opts, params), do: TaskTool.execute(unique_id(), params, nil, nil, cwd, opts)
  defp unique_id, do: "policy-#{System.unique_integer([:positive, :monotonic])}"
end
