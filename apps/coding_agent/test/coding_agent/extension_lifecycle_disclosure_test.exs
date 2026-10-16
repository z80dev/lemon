defmodule CodingAgent.ExtensionLifecycleDisclosureTest do
  @moduledoc """
  Integration coverage for progressive tool disclosure at the point every tool
  a session sees actually converges: `CodingAgent.ExtensionLifecycle`.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ExtensionLifecycle
  alias CodingAgent.Security.SecretObfuscator
  alias CodingAgent.ToolDisclosure
  alias CodingAgent.ToolPolicy
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.ExtensionsStatus
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  setup do
    CodingAgent.ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()
    :ok
  end

  defp settings, do: %{extension_paths: [], extension_auto_load_default_paths: true}

  defp mcp_tool(name, opts \\ []) do
    tool = %AgentTool{
      name: name,
      description: Keyword.get(opts, :description, "MCP #{name}"),
      parameters:
        Keyword.get(opts, :parameters, %{
          "type" => "object",
          "properties" => %{},
          "required" => []
        }),
      label: "MCP #{name}",
      execute:
        Keyword.get(opts, :execute, fn _, _, _, _ ->
          %AgentToolResult{content: [%TextContent{text: "ran #{name}"}]}
        end)
    }

    {name, tool, {:mcp, Keyword.get(opts, :server, :fixture)}}
  end

  defp names(tools), do: Enum.map(tools, & &1.name)

  # The prompt-visible projection of a tool: exactly the fields that reach the
  # provider's tool array.
  defp wire(tools) do
    Enum.map(tools, fn t ->
      %{name: t.name, description: t.description, parameters: t.parameters}
    end)
  end

  defp find(tools, name), do: Enum.find(tools, &(&1.name == name))

  defp all_text(%AgentToolResult{content: content}),
    do: Enum.map_join(content, &Map.get(&1, :text, ""))

  describe "initialize/1 with disclosure" do
    test "hides the MCP long tail and exposes working bridge tools", %{tmp_dir: tmp_dir} do
      parent = self()

      inventory = [
        mcp_tool("mcp_fixture_alpha", description: "Alpha tool"),
        mcp_tool("mcp_fixture_beta",
          description: "Beta tool",
          execute: fn id, params, _s, _u ->
            send(parent, {:beta_ran, id, params})
            %AgentToolResult{content: [%TextContent{text: "beta ok"}]}
          end
        )
      ]

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [mcp_tools: inventory, tool_disclosure: [budget_tokens: 1]]
        )

      tool_names = names(result.tools)

      refute "mcp_fixture_alpha" in tool_names
      refute "mcp_fixture_beta" in tool_names
      assert "read" in tool_names
      assert Enum.take(tool_names, -2) == ["tool_search", "tool_invoke"]

      assert result.tool_disclosure.active == true
      assert result.tool_disclosure.hidden_names == ["mcp_fixture_alpha", "mcp_fixture_beta"]

      attached = result.extension_status_report.tool_disclosure
      assert attached.hidden_count == result.tool_disclosure.hidden_count
      assert attached.disclosed_count == result.tool_disclosure.disclosed_count

      # Searchable...
      search = find(result.tools, "tool_search")
      search_result = search.execute.("id", %{"query" => "beta"}, nil, nil)
      assert "mcp_fixture_beta" in search_result.details.matched

      # ...and invokable through the bridge.
      invoke = find(result.tools, "tool_invoke")

      assert %AgentToolResult{} =
               invoke.execute.(
                 "call-9",
                 %{"name" => "mcp_fixture_beta", "args" => %{}},
                 nil,
                 nil
               )

      assert_received {:beta_ran, "call-9", %{}}
    end

    test "exposed and deferred catalog targets restore secrets before hooks across reload", %{
      tmp_dir: tmp_dir
    } do
      parent = self()
      test_pid = inspect(:erlang.pid_to_list(parent))

      module =
        create_extension_file(tmp_dir, "DisclosureSecretExt#{System.unique_integer([:positive])}",
          hooks: """
          [on_tool_call: fn
            %{tool_name: "mcp_secret_writer", args: args} ->
              send(:erlang.list_to_pid(#{test_pid}), {:target_hook, args["content"]})
              {:replace_args, Map.update!(args, "content", &(&1 <> " /hook"))}
            _ -> :ok
          end]
          """
        )

      on_exit(fn -> cleanup_module(module) end)
      secret = "fixture-disclosure-secret"

      obfuscator =
        SecretObfuscator.build(
          cwd: tmp_dir,
          agent_dir: tmp_dir,
          env: %{"API_KEY" => secret}
        )

      placeholder = SecretObfuscator.obfuscate(obfuscator, secret)
      path = Path.join(tmp_dir, "restored.txt")

      inventory = [
        mcp_tool("mcp_secret_writer",
          execute: fn _, args, _, _ ->
            File.write!(path, args["content"])
            %AgentToolResult{content: [%TextContent{text: "saved"}]}
          end
        )
      ]

      for disclosure <- [[enabled: false], [profile: :coding]] do
        opts = [
          cwd: tmp_dir,
          settings_manager: settings(),
          secret_obfuscator: obfuscator,
          tool_opts: [mcp_tools: inventory, tool_disclosure: disclosure]
        ]

        initial = ExtensionLifecycle.initialize(opts)

        reloaded =
          ExtensionLifecycle.reload(
            Keyword.put(opts, :previous_status_report, initial.extension_status_report)
          )

        for lifecycle <- [initial, reloaded] do
          args = %{"content" => placeholder}
          target = lifecycle.tool_catalog["mcp_secret_writer"].tool
          assert %AgentToolResult{is_error: false} = target.execute.("host", args, nil, nil)
          assert_receive {:target_hook, ^secret}
          refute_received {:target_hook, _}
          assert File.read!(path) == secret <> " /hook"

          if lifecycle.tool_disclosure.active do
            refute find(lifecycle.tools, "mcp_secret_writer")
            invoke = find(lifecycle.tools, "tool_invoke")

            assert %AgentToolResult{is_error: false} =
                     invoke.execute.(
                       "bridge",
                       %{"name" => "mcp_secret_writer", "args" => args},
                       nil,
                       nil
                     )
          else
            exposed = find(lifecycle.tools, "mcp_secret_writer")
            assert %AgentToolResult{is_error: false} = exposed.execute.("direct", args, nil, nil)
          end

          assert_receive {:target_hook, ^secret}
          refute_received {:target_hook, _}
          assert File.read!(path) == secret <> " /hook"
        end
      end
    end

    test "extension tools are hidden while builtins stay disclosed", %{tmp_dir: tmp_dir} do
      module =
        create_extension_file(tmp_dir, "DisclosureExt#{System.unique_integer([:positive])}",
          tools: extension_tools_code("disclosed_ext_tool")
        )

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [tool_disclosure: [budget_tokens: 1]]
        )

      tool_names = names(result.tools)

      refute "disclosed_ext_tool" in tool_names
      assert "read" in tool_names
      assert "bash" in tool_names
      assert "disclosed_ext_tool" in result.tool_disclosure.hidden_names

      cleanup_module(module)
    end

    test "the default configuration changes nothing", %{tmp_dir: tmp_dir} do
      tool_opts = []

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: tool_opts
        )

      golden =
        ToolRegistry.get_tools(
          tmp_dir,
          Keyword.merge(tool_opts, extension_paths: result.extension_paths)
        )

      assert names(result.tools) == names(golden)

      # Names alone would not catch a rewritten description or schema. The tool
      # array is part of the cached prompt prefix, so the under-budget path has
      # to be byte-identical, not merely same-shaped. Execute closures are
      # anonymous funs and never compare equal across two builds, so the
      # comparison is over exactly the fields that get serialized.
      assert wire(result.tools) == wire(golden)

      disabled =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: Keyword.put(tool_opts, :tool_disclosure, enabled: false)
        )

      assert wire(result.tools) == wire(disabled.tools)
      assert disabled.tool_disclosure.reason == :disabled

      # The kill switch also beats the opt-in profile: a disabled session is the
      # legacy inventory whatever profile is configured.
      disabled_coding =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: Keyword.put(tool_opts, :tool_disclosure, enabled: false, profile: :coding)
        )

      assert wire(disabled_coding.tools) == wire(golden)

      refute "tool_search" in names(result.tools)
      refute "tool_invoke" in names(result.tools)
      assert result.tool_disclosure.active == false
      assert result.tool_disclosure.reason == :under_budget
      assert result.tool_disclosure.profile == :legacy
    end

    test "the coding profile defers optional built-ins and keeps the coding core directly usable",
         %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "hello.txt"), "hello from the core")

      extra = %AgentTool{
        name: "caller_extra",
        description: "Caller-supplied tool",
        parameters: %{"type" => "object", "properties" => %{}},
        label: "caller_extra",
        execute: fn _, _, _, _ -> %AgentToolResult{content: [%TextContent{text: "extra"}]} end
      }

      build = fn disclosure ->
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          extra_tools: [extra],
          tool_opts: [mcp_tools: [mcp_tool("mcp_fixture_alpha")], tool_disclosure: disclosure]
        )
      end

      legacy = build.(nil)
      coding = build.(profile: :coding, pinned: ["browser_tabs"])

      # Non-vacuous: the registry resolved optional built-ins and the legacy
      # profile exposes them all.
      assert "browser_navigate" in names(legacy.tools)
      assert "media_status" in names(legacy.tools)
      refute legacy.tool_disclosure.active

      kept = MapSet.new(ToolDisclosure.coding_core() ++ ["browser_tabs", "caller_extra"])
      {exposed, deferred} = Enum.split_with(legacy.tools, &MapSet.member?(kept, &1.name))

      # The kept tools are exactly the legacy ones, same order, same schemas;
      # everything else the registry resolved is deferred, built-in or not.
      assert Enum.drop(wire(coding.tools), -2) == wire(exposed)
      assert Enum.take(names(coding.tools), -2) == ["tool_search", "tool_invoke"]
      assert coding.tool_disclosure.hidden_names == deferred |> names() |> Enum.sort()
      assert "browser_navigate" in coding.tool_disclosure.hidden_names
      assert "mcp_fixture_alpha" in coding.tool_disclosure.hidden_names
      assert "browser_tabs" in names(coding.tools)

      for core <- ~w(read write edit bash grep find ls todo task) do
        assert core in names(coding.tools), "#{core} must stay directly exposed"
      end

      assert coding.tool_disclosure.profile == :coding
      assert coding.tool_disclosure.disclosed_tokens < coding.tool_disclosure.estimated_tokens

      # A core tool runs directly, without a bridge round-trip.
      read = find(coding.tools, "read")

      assert all_text(read.execute.("id", %{"path" => Path.join(tmp_dir, "hello.txt")}, nil, nil)) =~
               "hello from the core"
    end

    test "a per-session override beats settings that would activate", %{tmp_dir: tmp_dir} do
      settings_manager =
        Map.put(settings(), :tools, %{disclosure: %{budget_tokens: 1}})

      # A deferrable tool has to exist for activation to mean anything: with an
      # all-builtin catalog there is nothing to hide and disclosure stays off
      # however small the budget is.
      inventory = [mcp_tool("mcp_fixture_alpha")]

      activating =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings_manager,
          tool_opts: [mcp_tools: inventory]
        )

      assert activating.tool_disclosure.active == true

      overridden =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings_manager,
          tool_opts: [mcp_tools: inventory, tool_disclosure: [enabled: false]]
        )

      assert overridden.tool_disclosure.active == false
      assert overridden.tool_disclosure.reason == :disabled
      refute "tool_search" in names(overridden.tools)
    end

    test "custom_tools sessions are exempt", %{tmp_dir: tmp_dir} do
      custom = %AgentTool{
        name: "custom_only_tool",
        description: String.duplicate("y", 200_000),
        parameters: %{},
        label: "custom",
        execute: fn _, _, _, _ -> %AgentToolResult{content: []} end
      }

      for profile <- [:legacy, :coding] do
        result =
          ExtensionLifecycle.initialize(
            cwd: tmp_dir,
            settings_manager: settings(),
            tool_opts: [tool_disclosure: [budget_tokens: 1, profile: profile]],
            custom_tools: [custom]
          )

        assert result.tool_disclosure.reason == :custom_tools
        refute result.tool_disclosure.active
        assert result.tool_disclosure.profile == profile
        assert result.tools == [custom]
      end
    end

    test "telemetry is emitted once per initialize", %{tmp_dir: tmp_dir} do
      handler_id = "disclosure-telemetry-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:coding_agent, :tool_disclosure, :applied],
        fn _event, measurements, metadata, _ ->
          # Telemetry invokes handlers synchronously in the emitting process.
          if self() == parent do
            send(parent, {:disclosure_telemetry, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # The handler is VM-global, including sessions that outlive other tests.
      # Force a foreign initialize before ours instead of relying on scheduling.
      foreign =
        Task.async(fn ->
          ExtensionLifecycle.initialize(
            cwd: tmp_dir,
            settings_manager: settings(),
            custom_tools: [],
            tool_opts: [extension_inventory: {[], []}, mcp_tools: []]
          )
        end)
        |> Task.await()

      assert foreign.tool_disclosure.hidden_count == 0

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [
            mcp_tools: [mcp_tool("mcp_fixture_alpha")],
            tool_disclosure: [budget_tokens: 1]
          ]
        )

      assert result.tool_disclosure.hidden_count == 1
      assert_received {:disclosure_telemetry, measurements, metadata}
      assert measurements.hidden_count == 1
      assert metadata.active == true
      assert metadata.reason == nil
      assert metadata.catalog_digest == result.tool_disclosure.catalog_digest
      assert metadata.diagnostic_events_version == 1
      assert metadata.catalog_digest =~ ~r/\A[0-9a-f]{64}\z/
      assert measurements.estimated_tokens == result.tool_disclosure.estimated_tokens
      assert measurements.disclosed_tokens == result.tool_disclosure.disclosed_tokens
      refute_received {:disclosure_telemetry, _, _}
    end
  end

  describe "policy enforcement through the funnel" do
    test "a denied tool is neither searchable nor invokable", %{tmp_dir: tmp_dir} do
      inventory = [
        mcp_tool("mcp_srv_secret", description: "secret sauce"),
        mcp_tool("mcp_srv_ok")
      ]

      result =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [
            mcp_tools: inventory,
            tool_policy: ToolPolicy.custom(deny: ["mcp_srv_secret"]),
            tool_disclosure: [budget_tokens: 1]
          ]
        )

      refute "mcp_srv_secret" in result.tool_disclosure.hidden_names
      assert "mcp_srv_ok" in result.tool_disclosure.hidden_names

      search = find(result.tools, "tool_search")

      assert search.execute.("id", %{"query" => "secret"}, nil, nil).details.matched == []

      select = search.execute.("id", %{"query" => "select:mcp_srv_secret"}, nil, nil)
      assert select.details.matched == []
      assert select.content |> hd() |> Map.get(:text) =~ "Not found: mcp_srv_secret"

      invoke = find(result.tools, "tool_invoke")

      assert {:error, message} =
               invoke.execute.("id", %{"name" => "mcp_srv_secret", "args" => %{}}, nil, nil)

      assert message =~ "Unknown tool 'mcp_srv_secret'"
    end

    test "approval gating still runs when the tool is called through tool_invoke", %{
      tmp_dir: tmp_dir
    } do
      parent = self()

      inventory = [
        mcp_tool("mcp_srv_danger",
          execute: fn _, _, _, _ ->
            send(parent, :danger_ran)
            %AgentToolResult{content: [%TextContent{text: "danger ran"}]}
          end
        )
      ]

      build = fn decision ->
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [
            mcp_tools: inventory,
            tool_disclosure: [budget_tokens: 1],
            tool_policy: ToolPolicy.custom(require_approval: ["mcp_srv_danger"]),
            approval_context: %{
              run_id: "run-1",
              session_id: "session-1",
              session_key: "key-1",
              approval_request_fun: decision
            }
          ]
        )
      end

      denied = build.(fn _ -> {:ok, :denied} end)
      invoke = find(denied.tools, "tool_invoke")

      result = invoke.execute.("id", %{"name" => "mcp_srv_danger", "args" => %{}}, nil, nil)

      refute_received :danger_ran
      assert %AgentToolResult{} = result
      assert result.content |> hd() |> Map.get(:text) =~ "denied"

      approved = build.(fn _ -> {:ok, :approved, :once} end)
      approved_invoke = find(approved.tools, "tool_invoke")

      approved_result =
        approved_invoke.execute.("id", %{"name" => "mcp_srv_danger", "args" => %{}}, nil, nil)

      assert_received :danger_ran
      assert approved_result.content |> hd() |> Map.get(:text) == "danger ran"
    end
  end

  describe "reload/1" do
    test "recomputes disclosure and stays deterministic across identical reloads", %{
      tmp_dir: tmp_dir
    } do
      inventory = [mcp_tool("mcp_fixture_alpha"), mcp_tool("mcp_fixture_beta")]

      initial =
        ExtensionLifecycle.initialize(
          cwd: tmp_dir,
          settings_manager: settings(),
          tool_opts: [mcp_tools: inventory]
        )

      assert initial.tool_disclosure.active == false
      refute "tool_search" in names(initial.tools)

      reload_opts = [
        cwd: tmp_dir,
        settings_manager: settings(),
        tool_opts: [mcp_tools: inventory, tool_disclosure: [budget_tokens: 1]],
        previous_status_report: initial.extension_status_report
      ]

      first = ExtensionLifecycle.reload(reload_opts)
      second = ExtensionLifecycle.reload(reload_opts)

      assert first.tool_disclosure.active == true
      refute "mcp_fixture_alpha" in names(first.tools)
      assert Enum.take(names(first.tools), -2) == ["tool_search", "tool_invoke"]
      assert first.extension_status_report.tool_disclosure.hidden_count == 2

      assert names(first.tools) == names(second.tools)

      assert find(first.tools, "tool_search").description ==
               find(second.tools, "tool_search").description
    end
  end

  describe "extensions_status rendering" do
    test "renders an active disclosure section" do
      report = %{
        active: true,
        reason: nil,
        estimated_tokens: 61_240,
        budget_tokens: 40_000,
        total_tools: 89,
        disclosed_count: 52,
        hidden_count: 37,
        hidden_names: ["mcp_a", "mcp_b"],
        catalog_tier: :inline_descriptions,
        shadowed_by_bridge: []
      }

      summary = ExtensionsStatus.format_tool_disclosure_section(report, false)

      assert summary =~ "## Tool Disclosure"
      assert summary =~ "**Active:** true"
      assert summary =~ "61240 (budget 40000)"
      assert summary =~ "**Disclosed tools:** 52"
      assert summary =~ "**Hidden tools:** 37"
      assert summary =~ "**Catalog tier:** inline_descriptions"
      refute summary =~ "mcp_a"

      detailed = ExtensionsStatus.format_tool_disclosure_section(report, true)
      assert detailed =~ "**Hidden:** mcp_a, mcp_b"
    end

    test "renders an inactive disclosure section with its reason" do
      summary =
        ExtensionsStatus.format_tool_disclosure_section(
          ToolDisclosure.skipped_report(:custom_tools),
          true
        )

      assert summary =~ "**Active:** false (custom_tools)"
    end
  end

  defp extension_tools_code(tool_name) do
    """
    [
      %LemonAgent.Types.AgentTool{
        name: "#{tool_name}",
        description: "tool #{tool_name}",
        parameters: %{},
        label: "#{tool_name}",
        execute: fn _, _, _, _ -> %LemonAgent.Types.AgentToolResult{content: [], details: nil} end
      }
    ]
    """
  end

  defp create_extension_file(tmp_dir, module_name, opts) do
    tools = Keyword.get(opts, :tools, "[]")
    hooks = Keyword.get(opts, :hooks, "[]")

    extension_code = """
    defmodule #{module_name} do
      @behaviour CodingAgent.Extensions.Extension

      @impl true
      def name, do: "#{String.downcase(module_name)}"

      @impl true
      def version, do: "1.0.0"

      @impl true
      def tools(_cwd), do: #{tools}

      @impl true
      def hooks, do: #{hooks}
    end
    """

    ext_dir = Path.join(tmp_dir, ".lemon/extensions")
    File.mkdir_p!(ext_dir)
    File.write!(Path.join(ext_dir, "#{String.downcase(module_name)}.ex"), extension_code)

    Module.concat([module_name])
  end

  defp cleanup_module(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
