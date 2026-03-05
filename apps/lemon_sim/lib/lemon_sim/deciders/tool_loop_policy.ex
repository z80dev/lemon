defmodule LemonSim.Deciders.ToolLoopPolicy do
  @moduledoc """
  Behaviour for defining tool-call semantics within `ToolLoopDecider`.

  Policies decide whether an assistant tool-call batch is valid and whether an
  executed tool call should terminate the current loop with a decision.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias Ai.Types.ToolCall

  @type resolved_tool_call :: %{
          required(:tool_call) => ToolCall.t(),
          required(:tool) => AgentTool.t()
        }

  @callback validate_tool_calls([resolved_tool_call()], keyword()) :: :ok | {:error, term()}

  @callback decision_from_call(
              tool_call :: ToolCall.t(),
              tool :: AgentTool.t(),
              result :: AgentToolResult.t(),
              opts :: keyword()
            ) :: map() | nil
end
