defmodule CodingAgent.ToolRegistryRestrictedProfilesTest do
  # Mutates the global satellite registration table.
  use ExUnit.Case, async: false

  alias CodingAgent.{ToolPolicy, ToolRegistry}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  @moduletag :tmp_dir

  # Stand-ins registered under the names the real satellites use, plus one
  # contributed tool the platform has never heard of.
  @satellites [
    {:omp, __MODULE__.Omp},
    {:cua_js, __MODULE__.CuaJs},
    {:cua_js_reset, __MODULE__.CuaJsReset},
    {:honcho_search, __MODULE__.HonchoSearch},
    {:honcho_conclude, __MODULE__.HonchoConclude},
    {:contributed_satellite_tool, __MODULE__.Contributed}
  ]

  @sms_tool {:sms_list_messages, __MODULE__.SmsListMessages}

  for {name, module} <- [@sms_tool | @satellites] do
    defmodule module do
      @moduledoc false
      def tool(_cwd, _opts) do
        %LemonAgent.Types.AgentTool{
          name: unquote(Atom.to_string(name)),
          description: "fixture",
          parameters: %{"type" => "object", "properties" => %{}},
          execute: fn _id, _params, _signal, _update ->
            %LemonAgent.Types.AgentToolResult{content: []}
          end
        }
      end
    end
  end

  @satellite_names Enum.map(@satellites, fn {name, _} -> Atom.to_string(name) end)
  @restricted [:safe_mode, :subagent_restricted, :leaf_worker, :no_external]

  setup do
    key = {LemonAgent.ToolRegistry, :registered}
    original = :persistent_term.get(key, [])
    :persistent_term.put(key, [])

    Enum.each(@satellites, fn {name, module} ->
      LemonAgent.ToolRegistry.register(name, module, native_process_ownership: :managed)
    end)

    on_exit(fn -> :persistent_term.put(key, original) end)
    :ok
  end

  test "every platform tool the registry builds is classified", %{tmp_dir: cwd} do
    built = names(cwd, ToolPolicy.from_profile(:full_access), mcp_tools: [])

    for name <- built -- @satellite_names do
      assert {:ok, _} = LemonCore.ToolCatalog.fetch(name), "#{name} has no catalogue entry"
    end
  end

  test "a satellite cannot register a tool reserved for platform builders" do
    for name <- [:read, :discord_send_file, :submit_result, :tool_invoke] do
      assert_raise ArgumentError, fn ->
        LemonAgent.ToolRegistry.register(name, __MODULE__.Contributed)
      end
    end
  end

  defp names(cwd, policy, opts) do
    cwd
    |> ToolRegistry.get_tools([tool_policy: policy, include_extensions: false] ++ opts)
    |> Enum.map(& &1.name)
  end

  defp mcp_tool(name) do
    %AgentTool{
      name: name,
      description: "mcp fixture",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _params, _signal, _update -> %AgentToolResult{content: []} end
    }
  end

  test "registered satellites reach full-access sessions", %{tmp_dir: cwd} do
    available = names(cwd, ToolPolicy.from_profile(:full_access), mcp_tools: [])
    for name <- @satellite_names, do: assert(name in available)
  end

  test "the SMS ingress satellite can register its classified tool", %{tmp_dir: cwd} do
    {name, module} = @sms_tool

    assert :ok =
             LemonAgent.ToolRegistry.register(name, module, native_process_ownership: :managed)

    assert {:ok, %{classes: [:external]}} = LemonCore.ToolCatalog.fetch("sms_list_messages")
    assert "sms_list_messages" in names(cwd, ToolPolicy.from_profile(:full_access), mcp_tools: [])

    refute "sms_list_messages" in names(cwd, ToolPolicy.from_profile(:no_external), mcp_tools: [])
  end

  test "restricted profiles build no unclassified satellite or peer tool, but keep agent_message",
       %{tmp_dir: cwd} do
    for profile <- @restricted do
      available = names(cwd, ToolPolicy.from_profile(profile), mcp_tools: [])

      for name <- @satellite_names ++ ["peer"] do
        refute name in available, "#{profile} built #{name}"
      end

      assert "agent_message" in available
      assert "read" in available
    end
  end

  test "a family-only agent_message refuses every named operation", %{tmp_dir: cwd} do
    for policy <- [
          ToolPolicy.from_profile(:leaf_worker),
          CodingAgent.Subagents.tool_policy(%{name: "scout", tools: nil}, nil)
        ] do
      {:ok, tool} =
        ToolRegistry.get_tool(cwd, "agent_message",
          tool_policy: policy,
          include_extensions: false,
          include_mcp: false,
          tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(cwd)
        )

      for params <- [
            %{"action" => "send", "to" => "@bob", "message" => "hi"},
            %{"to" => "session://agent:x:main", "message" => "hi"},
            %{"action" => "send", "to" => "bot://inst/1", "message" => "hi"},
            %{"action" => "list", "scope" => "named"},
            %{"action" => "rename", "name" => "evil"},
            %{"action" => "status", "message_id" => "m1"}
          ] do
        result = tool.execute.("call-1", params, nil, nil)
        text = family_text(result)
        assert text =~ "own task family", "#{inspect(params)}: #{text}"
      end
    end
  end

  defp family_text({:error, reason}), do: to_string(reason)

  defp family_text(%AgentToolResult{content: content}),
    do: Enum.map_join(content, "", &Map.get(&1, :text, ""))

  test "an MCP tool cannot borrow a platform tool's classification", %{tmp_dir: cwd} do
    mcp = [mcp_tool("sms_list_messages"), mcp_tool("contributed_mcp_tool")]

    full = names(cwd, ToolPolicy.from_profile(:full_access), mcp_tools: mcp)
    assert "contributed_mcp_tool" in full

    for profile <- @restricted do
      available = names(cwd, ToolPolicy.from_profile(profile), mcp_tools: mcp)
      refute "sms_list_messages" in available, "#{profile} admitted a spoofed MCP tool"
      refute "contributed_mcp_tool" in available, "#{profile} admitted an unclassified MCP tool"
    end
  end
end
