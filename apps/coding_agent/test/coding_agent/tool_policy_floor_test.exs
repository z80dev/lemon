defmodule CodingAgent.ToolPolicyFloorTest do
  # Starts real sessions and compiles an extension into the shared cache.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias CodingAgent.{ExtensionLifecycle, Session, ToolPolicy, ToolRegistry}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @moduletag :tmp_dir

  @channel_names ~w(send_file)
  @extension_tool "floor_extension_tool"
  @mcp_tool "floor_mcp_tool"

  setup %{tmp_dir: tmp} do
    ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()

    name = "FloorExtension#{System.unique_integer([:positive])}"
    ext_dir = Path.join(tmp, "extensions")
    File.mkdir_p!(ext_dir)

    File.write!(Path.join(ext_dir, "#{String.downcase(name)}.ex"), """
    defmodule #{name} do
      @behaviour CodingAgent.Extensions.Extension
      def name, do: "floor"
      def version, do: "1.0.0"
      def hooks, do: []

      def tools(_cwd) do
        [
          %LemonAgent.Types.AgentTool{
            name: "#{@extension_tool}",
            description: "extension fixture",
            parameters: %{},
            label: "fixture",
            execute: fn _, _, _, _ -> %LemonAgent.Types.AgentToolResult{content: []} end
          }
        ]
      end
    end
    """)

    on_exit(fn ->
      module = Module.concat([name])
      :code.purge(module)
      :code.delete(module)
      ToolRegistry.invalidate_extension_cache()
    end)

    workspace = Path.join(tmp, "workspace")
    File.mkdir_p!(workspace)
    {:ok, ext_dir: ext_dir, workspace: workspace}
  end

  # Built exactly as `CodingAgent.Executor.SessionRunner` builds a channel run's extras.
  defp executor_extras(cwd) do
    key = "agent:floor:telegram:dm:1"

    [
      CodingAgent.Tools.SendFile.tool(cwd, session_key: key, workspace_dir: cwd)
    ]
  end

  defp model do
    %LemonAi.Types.Model{
      id: "floor-test",
      name: "Floor test",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }
  end

  defp settings(cwd, ext_dir) do
    %{
      CodingAgent.SettingsManager.load(cwd)
      | extension_paths: [ext_dir],
        extension_auto_load_default_paths: false
    }
  end

  defp session_tools(ctx, opts) do
    session =
      start_supervised!(
        {Session,
         [
           cwd: ctx.tmp_dir,
           model: model(),
           settings_manager: settings(ctx.tmp_dir, ctx.ext_dir),
           workspace_dir: ctx.workspace
         ] ++ opts},
        id: make_ref()
      )

    {session, Enum.map(Session.get_state(session).tools, & &1.name)}
  end

  defp fixture_tool(name) do
    %AgentTool{
      name: name,
      description: "fixture",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
    }
  end

  test "a read-only executor session receives no channel or extension tool", ctx do
    for policy <- [ToolPolicy.from_profile(:read_only), ToolPolicy.custom(allow: [])] do
      {_session, names} =
        session_tools(ctx, tool_policy: policy, extra_tools: executor_extras(ctx.tmp_dir))

      for name <- [@extension_tool | @channel_names] do
        refute name in names, "#{inspect(policy.allow)} exposed #{name}"
      end

      assert Enum.all?(names, &ToolPolicy.allowed?(policy, &1)), inspect(names)
    end
  end

  test "a full-access executor session keeps its channel tools", ctx do
    {_session, names} =
      session_tools(ctx,
        tool_policy: ToolPolicy.from_profile(:full_access),
        extra_tools: executor_extras(ctx.tmp_dir)
      )

    for name <- @channel_names, do: assert(name in names)
  end

  test "a side query session with no tools gets no extension tool", ctx do
    {_session, names} = session_tools(ctx, tools: [])
    assert names == []
  end

  test "a hand-assembled toolset stays closed across reload", ctx do
    custom = [fixture_tool("hand_picked")]

    {session, names} =
      session_tools(ctx, tools: custom, tool_policy: ToolPolicy.from_profile(:full_access))

    assert names == ["hand_picked"]
    assert {:ok, _report} = Session.reload_extensions(session)
    assert Enum.map(Session.get_state(session).tools, & &1.name) == ["hand_picked"]
  end

  test "child tasks inherit only the extras their parent's policy admits", ctx do
    {session, _names} =
      session_tools(ctx,
        tool_policy: ToolPolicy.custom(deny: @channel_names),
        extra_tools: executor_extras(ctx.tmp_dir)
      )

    inherited = Keyword.get(Session.get_state(session).tool_opts, :extra_tools, [])
    assert Enum.map(inherited, & &1.name) -- @channel_names == Enum.map(inherited, & &1.name)
  end

  defp policy_gen do
    names =
      Enum.uniq(
        ~w(read ls grep write bash webfetch task tool_search tool_invoke) ++
          @channel_names ++ [@extension_tool, @mcp_tool, "hand_picked"]
      )

    profiles =
      member_of([
        :full_access,
        :read_only,
        :safe_mode,
        :leaf_worker,
        :no_external,
        :minimal_core,
        :subagent_restricted
      ])

    one_of([
      map(profiles, &ToolPolicy.from_profile/1),
      map(list_of(member_of(names), max_length: 6), &ToolPolicy.custom(allow: &1)),
      map(list_of(member_of(names), max_length: 6), &ToolPolicy.custom(deny: &1)),
      constant(ToolPolicy.custom(allow: []))
    ])
  end

  property "every finalized tool is allowed by the session's policy", ctx do
    check all(policy <- policy_gen(), custom? <- boolean(), max_runs: 20) do
      result =
        ExtensionLifecycle.initialize(
          cwd: ctx.tmp_dir,
          settings_manager: settings(ctx.tmp_dir, ctx.ext_dir),
          custom_tools: if(custom?, do: [fixture_tool("hand_picked")]),
          extra_tools: executor_extras(ctx.tmp_dir),
          tool_policy: policy,
          tool_opts: [
            mcp_tools: [fixture_tool(@mcp_tool)],
            tool_policy: policy,
            tool_disclosure: [budget_tokens: 1]
          ]
        )

      names = Enum.map(result.tools, & &1.name)

      for name <- names do
        assert ToolPolicy.allowed?(policy, name), "#{name} escaped #{inspect(policy)}"
      end
    end
  end

  defp initialize(ctx, policy, extra_tool_opts \\ []) do
    ExtensionLifecycle.initialize(
      cwd: ctx.tmp_dir,
      settings_manager: settings(ctx.tmp_dir, ctx.ext_dir),
      tool_policy: policy,
      tool_opts:
        [
          mcp_tools: [fixture_tool(@mcp_tool)],
          tool_policy: policy,
          tool_disclosure: [budget_tokens: 1]
        ] ++ extra_tool_opts
    )
  end

  test "disclosure bridges are dropped with discovery intact when the policy denies them",
       ctx do
    full = initialize(ctx, ToolPolicy.from_profile(:full_access))
    full_names = Enum.map(full.tools, & &1.name)
    assert "tool_search" in full_names and "tool_invoke" in full_names
    refute @mcp_tool in full_names

    for denied <- ["tool_search", "tool_invoke"] do
      result = initialize(ctx, ToolPolicy.custom(deny: [denied]))
      names = Enum.map(result.tools, & &1.name)
      refute "tool_search" in names
      refute "tool_invoke" in names
      # The long tail stays reachable, disclosed directly.
      assert @mcp_tool in names
      assert result.tool_disclosure.reason == :bridges_denied
    end
  end

  test "disclosure bridges pass the session approval gate", ctx do
    parent = self()

    approval = fn request ->
      send(parent, {:approval, request.tool})
      {:ok, :denied}
    end

    for bridge <- ["tool_search", "tool_invoke"] do
      policy = ToolPolicy.custom(approvals: %{bridge => :always})

      result =
        initialize(ctx, policy, approval_context: %{approval_request_fun: approval})

      tool = Enum.find(result.tools, &(&1.name == bridge))
      assert tool, "#{bridge} missing"

      params =
        if bridge == "tool_search",
          do: %{"query" => "floor"},
          else: %{"name" => @mcp_tool, "args" => %{}}

      outcome = tool.execute.("call", params, nil, nil)
      assert match?(%AgentToolResult{is_error: true}, outcome) or match?({:error, _}, outcome)
      assert_received {:approval, ^bridge}
    end
  end
end
