defmodule CodingAgent.Tools.AbortHelpers do
  @moduledoc """
  Coding-agent abort helper compatibility wrapper.

  The implementation lives in `AgentCore.Tools.AbortHelpers`. This module
  preserves the existing import surface; new code should use the AgentCore
  module directly.
  """

  defdelegate aborted?(signal), to: AgentCore.Tools.AbortHelpers
  defdelegate check_abort(signal), to: AgentCore.Tools.AbortHelpers
  defdelegate check_aborted(signal), to: AgentCore.Tools.AbortHelpers
end
