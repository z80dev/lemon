defmodule LemonComputerUse.ContextContributor do
  @moduledoc """
  Puts the computer-use runtime's own MCP initialization instructions into the
  system prompt, as Codex and LCU's other harness adapters do before the first
  call.

  The text is whatever the connected server returned and is the same for the
  life of the connection, so it is a `:system` section (prompt-cache stable).
  It reads only the cached catalog: before the first connection there is
  nothing to add and the turn is skipped.
  """

  @behaviour LemonAgent.ContextRegistry

  alias LemonComputerUse.Server

  @impl true
  def contribute(_request) do
    case Server.cached_catalog() do
      %{instructions: instructions} when is_binary(instructions) ->
        case String.trim(instructions) do
          "" -> :skip
          text -> {:ok, %{title: "Computer use", body: text, placement: :system}}
        end

      _ ->
        :skip
    end
  end
end
