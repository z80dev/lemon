defmodule LemonSim.Deciders.ToolLoopPolicy do
  @moduledoc false

  @callback validate_tool_calls([map()], keyword()) :: :ok | {:error, term()}
  @callback decision_from_tool_result(map(), map(), map(), keyword()) :: map() | nil
end
