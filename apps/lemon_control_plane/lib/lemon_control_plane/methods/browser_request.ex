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
    await_result = params["await"] == true
    force_local = params["local"] == true
    timeout_ms = params["timeoutMs"] || 30_000

    cond do
      is_nil(method) or method == "" ->
        {:error, Errors.invalid_request("method is required")}

      true ->
        # Find browser node
        browser_node = if(force_local, do: nil, else: find_browser_node(node_id))

        cond do
          browser_node == nil and local_fallback_enabled?() ->
            run_local(method, args, timeout_ms)

          browser_node == nil ->
            {:error, Errors.not_found("No browser node available. Pair a browser node first.")}

          true ->
            node = browser_node

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
                "timeoutMs" => timeout_ms
              }

              with {:ok, invoke} <-
                     LemonControlPlane.Methods.NodeInvoke.handle(invoke_params, ctx) do
                if await_result do
                  await_invoke(invoke, timeout_ms)
                else
                  {:ok, invoke}
                end
              end
            end
        end
    end
  end

  defp local_fallback_enabled? do
    Application.get_env(:lemon_control_plane, :browser_local_fallback, true)
  end

  defp run_local(method, args, timeout_ms) do
    full = if String.starts_with?(method, "browser."), do: method, else: "browser.#{method}"

    case LemonCore.Browser.LocalServer.request(full, args, timeout_ms) do
      {:ok, result} ->
        {:ok,
         %{
           "mode" => "local",
           "ok" => true,
           "result" => result
         }}

      {:error, reason} ->
        {:error, Errors.unavailable(reason)}
    end
  end

  defp await_invoke(%{"invokeId" => invoke_id} = invoke, timeout_ms) when is_binary(invoke_id) do
    deadline = System.monotonic_time(:millisecond) + max(0, timeout_ms)

    poll = fn ->
      case LemonCore.Store.get(:node_invocations, invoke_id) do
        nil ->
          :pending

        inv when is_map(inv) ->
          status = get_field(inv, :status)
          result = get_field(inv, :result)
          error = get_field(inv, :error)

          cond do
            status in [:completed, "completed"] ->
              {:done, %{"status" => "completed", "ok" => true, "result" => result}}

            status in [:error, "error"] ->
              {:done, %{"status" => "error", "ok" => false, "error" => error}}

            true ->
              :pending
          end
      end
    end

    await_loop(invoke, deadline, poll)
  end

  defp await_invoke(invoke, _timeout_ms), do: {:ok, invoke}

  defp await_loop(invoke, deadline, poll) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      # Timed out waiting; return the pending invocation.
      {:ok, invoke}
    else
      case poll.() do
        {:done, extra} ->
          {:ok, Map.merge(invoke, extra)}

        :pending ->
          Process.sleep(50)
          await_loop(invoke, deadline, poll)
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
