defmodule CodingAgent.Tools.ToolDeadlinesTest do
  use ExUnit.Case, async: true
  alias CodingAgent.Tools

  test "deadline-owning native tools declare their runtime exemption" do
    for module <- [
          Tools.Task,
          Tools.Task.Wait,
          Tools.Bash,
          Tools.Agent,
          Tools.Eval,
          Tools.Debug,
          Tools.Ask,
          Tools.AskParent
        ] do
      tool = module.tool("/tmp", [])
      assert tool.timeout_ms == :infinity, tool.name
    end

    assert Tools.Browser.tool("/tmp", [], Tools.Browser.spec(:navigate)).timeout_ms == :infinity
    assert Tools.Read.tool("/tmp", []).timeout_ms == nil
  end
end
