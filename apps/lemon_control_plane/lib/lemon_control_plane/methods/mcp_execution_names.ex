defmodule LemonControlPlane.Methods.McpExecutionNames do
  @moduledoc """
  Pure native execution-name projection for public profile HTTP server identity.

  This inline read requires neither a profile nor an execution node. It uses the owning
  MCP alias implementation without opening a client, resolving DNS, or reading
  secrets. Authentication configuration is deliberately not accepted.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "mcp.execution_names"

  @impl true
  def scopes, do: [:read]

  @impl true
  def dispatch_mode, do: :inline

  @impl true
  def handle(params, %{auth: %{role: :operator} = auth}) when is_map(params) do
    with :ok <- Authorize.authorize(auth, name(), scopes()),
         true <- Enum.sort(Map.keys(params)) == ~w(server toolNames),
         %{} = server <- params["server"],
         true <- Enum.sort(Map.keys(server)) == ~w(name url),
         {:ok, result} <- LemonSkills.McpDiscovery.execution_names(server, params["toolNames"]) do
      {:ok, result}
    else
      {:error, {:forbidden, _}} = error -> error
      _ -> {:error, Errors.invalid_request("Invalid MCP execution name request")}
    end
  rescue
    _ -> {:error, Errors.invalid_request("Invalid MCP execution name request")}
  end

  def handle(_params, _ctx),
    do: {:error, Errors.forbidden("MCP execution names require operator read access")}
end
