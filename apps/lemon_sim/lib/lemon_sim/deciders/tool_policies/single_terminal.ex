defmodule LemonSim.Deciders.ToolPolicies.SingleTerminal do
  @moduledoc false

  defdelegate validate_tool_calls(resolved_calls, opts),
    to: LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal

  defdelegate decision_from_call(tool_call, tool, result, opts),
    to: LemonSim.LLM.Deciders.ToolPolicies.SingleTerminal
end
