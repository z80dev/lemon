defmodule LemonControlPlane.Methods.BrowserRequest do
  @moduledoc """
  Handler for the browser.request control plane method.

  Proxies browser automation requests to a paired browser node.

  ## Supported Methods

  - `navigate` - Navigate to a URL
  - `screenshot` - Take a screenshot
  - `click` - Click an element
  - `type` - Type text into an element
  - `evaluate` - Evaluate JavaScript
  - `waitForSelector` - Wait for an element
  - `getContent` - Get page HTML content
  - `getCookies` - Get cookies
  - `setCookies` - Set cookies

  ## Usage

  1. Pair a browser node using `node.pair.request`/`node.pair.approve`
  2. Call browser.request with method and args
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "browser.request"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    method = params["method"]
    args = params["args"] || %{}
    node_id = params["nodeId"] || params["node_id"]

    cond do
      is_nil(method) or method == "" ->
        {:error, Errors.invalid_request("method is required")}

      true ->
        # Find browser node
        browser_node = find_browser_node(node_id)

        case browser_node do
          nil ->
            {:error, Errors.not_found("No browser node available. Pair a browser node first.")}

          node ->
            # Get node ID (handle both atom and string keys)
            actual_node_id = get_field(node, :id) || node_id
            status = get_field(node, :status)

            if status != :online and status != "online" do
              {:error, Errors.unavailable("Browser node is not online")}
            else
              # Forward request to browser node via node.invoke
              invoke_params = %{
                "nodeId" => actual_node_id,
                "method" => "browser.#{method}",
                "args" => args,
                "timeoutMs" => params["timeoutMs"] || 30_000
              }

              LemonControlPlane.Methods.NodeInvoke.handle(invoke_params, ctx)
            end
        end
    end
  end

  defp find_browser_node(nil) do
    # Try to find a default browser node
    case LemonCore.Store.list(:nodes_registry) do
      nodes when is_list(nodes) ->
        Enum.find_value(nodes, fn {_id, node} ->
          node_type = get_field(node, :type)
          if node_type == "browser" or node_type == :browser, do: node
        end)

      _ ->
        nil
    end
  end

  defp find_browser_node(node_id) do
    LemonCore.Store.get(:nodes_registry, node_id)
  end

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
