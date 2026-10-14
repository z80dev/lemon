defmodule LemonControlPlane.Methods.NodeMcpDiscover do
  @moduledoc """
  Discovers one MCP server on an explicitly selected execution node.

  Only operator administrators may invoke this asynchronous method. Configuration
  is normalized here, but connections and encrypted secret resolution belong to
  the destination. The controller never opens an MCP client.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "node.mcp.discover"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def dispatch_mode, do: :async

  @impl true
  def handle(params, %{auth: %{role: :operator} = auth} = ctx) do
    with :ok <- Authorize.authorize(auth, name(), scopes()),
         :ok <- validate_node_id(params["nodeId"]),
         {:ok, [server]} <- LemonCore.ProfileStore.normalize_mcp_servers([params["server"]]) do
      LemonControlPlane.NodeIO.invoke(params["nodeId"], name(), %{"server" => server}, ctx)
    else
      {:error, {:forbidden, _}} = error -> error
      _ -> {:error, Errors.invalid_request("Invalid discovery request")}
    end
  rescue
    _ -> {:error, Errors.unavailable("MCP discovery is unavailable")}
  catch
    _, _ -> {:error, Errors.unavailable("MCP discovery is unavailable")}
  end

  def handle(_params, _ctx),
    do: {:error, Errors.forbidden("MCP discovery requires operator administrator access")}

  defp validate_node_id(node_id) when is_binary(node_id) do
    if String.valid?(node_id) and byte_size(node_id) in 1..128 and
         String.trim(node_id) == node_id and not String.contains?(node_id, <<0>>),
       do: :ok,
       else: {:error, :invalid_node_id}
  end

  defp validate_node_id(_node_id), do: {:error, :invalid_node_id}
end
