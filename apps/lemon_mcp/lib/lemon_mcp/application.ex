defmodule LemonMCP.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # MCP Client pool will be added here
      # MCP Server will be added here
    ]

    opts = [strategy: :one_for_one, name: LemonMCP.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
