defmodule CodingAgent.Tools.AbortHelpers do
  defdelegate aborted?(signal), to: AgentCore.Tools.AbortHelpers
  defdelegate check_abort(signal), to: AgentCore.Tools.AbortHelpers
  defdelegate check_aborted(signal), to: AgentCore.Tools.AbortHelpers
end
