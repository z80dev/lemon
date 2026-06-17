defmodule LemonSim.GameHelpers.Tools do
  @moduledoc false

  defdelegate statement_tool(actor_id, opts \\ []), to: LemonSim.Examples.Helpers.Tools
  defdelegate vote_tool(actor_id, valid_targets, opts \\ []), to: LemonSim.Examples.Helpers.Tools

  defdelegate whisper_tool(actor_id, valid_targets, opts \\ []),
    to: LemonSim.Examples.Helpers.Tools

  defdelegate add_thought_param(tool), to: LemonSim.Examples.Helpers.Tools
end
