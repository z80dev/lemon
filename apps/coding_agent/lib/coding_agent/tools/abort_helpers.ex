defmodule CodingAgent.Tools.AbortHelpers do
  @moduledoc """
  Coding-agent abort helper compatibility wrapper.

  The implementation lives in `LemonAgent.Tools.AbortHelpers`. This module
  preserves the existing import surface; new code should use the LemonAgent
  module directly.
  """

  defdelegate aborted?(signal), to: LemonAgent.Tools.AbortHelpers
  defdelegate check_abort(signal), to: LemonAgent.Tools.AbortHelpers
  defdelegate check_aborted(signal), to: LemonAgent.Tools.AbortHelpers
end
