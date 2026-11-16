defmodule CodingAgent.CodeModeProfileTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{ToolDisclosure, ToolRegistry}
  alias CodingAgent.Tools.{CodeMode, Eval}
  alias LemonAgent.Types.AgentTool

  @tag :tmp_dir
  test "code_mode is explicit and direct profiles keep their original eval tool", %{tmp_dir: cwd} do
    assert ToolDisclosure.config(nil).profile == :legacy
    assert ToolDisclosure.config(nil, nil, :coding).profile == :coding
    assert ToolDisclosure.config(nil, profile: "code_mode").profile == :code_mode

    direct = Eval.tool(cwd)
    assert direct.parameters["required"] == ["language", "code"]
    refute direct.description =~ "no ambient"

    coding = ToolDisclosure.config(nil, profile: :coding)
    assert Eval.tool(cwd, tool_disclosure: coding).description == direct.description

    code_mode = ToolDisclosure.config(nil, profile: :code_mode)
    sandbox = Eval.tool(cwd, tool_disclosure: code_mode)
    assert sandbox.parameters["required"] == ["code"]
    assert sandbox.description =~ "no ambient"
    refute sandbox.parameters["properties"] |> Map.has_key?("language")
  end

  @tag :tmp_dir
  test "the experimental surface retains discovery and renders the wrapped session catalog", %{
    tmp_dir: cwd
  } do
    cfg = ToolDisclosure.config(nil, profile: :code_mode)

    tuples =
      ToolRegistry.get_tool_tuples(cwd,
        tool_disclosure: cfg,
        include_extensions: false,
        include_mcp: false,
        enabled_only: ["eval", "eval_wait", "bash", "read"]
      )

    %{tools: tools, catalog: catalog, report: report} = ToolDisclosure.apply(tuples, [], cfg)
    names = Enum.map(tools, & &1.name)
    assert report.profile == :code_mode
    assert report.active
    assert names == ["read", "eval", "eval_wait", "tool_search", "tool_invoke"]
    assert catalog["bash"].hidden
    assert %AgentTool{name: "eval_wait"} = Enum.find(tools, &(&1.name == "eval_wait"))
    eval = Enum.find(tools, &(&1.name == "eval"))
    assert eval.description =~ "declare const tools:"
    assert eval.description =~ ~s("bash":)
    refute eval.description =~ ~s("eval_wait":)

    reversed = ToolDisclosure.apply(Enum.reverse(tuples), [], cfg)
    assert Enum.find(reversed.tools, &(&1.name == "eval")).description == eval.description
  end

  @tag :tmp_dir
  test "missing Deno fails closed without selecting the full-authority kernels", %{tmp_dir: cwd} do
    opts = [session_id: "missing-deno", code_mode_runtime: "lemon-no-such-deno-598"]
    tool = CodeMode.tool(cwd, opts)
    assert {:error, message} = tool.execute.("cell", %{"code" => "return 1"}, nil, nil)
    assert message =~ "requires Deno 2"
    assert message =~ "no unsandboxed fallback"
    assert :error = CodingAgent.Eval.KernelSupervisor.lookup({"missing-deno", "code_mode"})
  end
end
