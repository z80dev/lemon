defmodule LemonControlPlane.Methods.BrowserRequest do
  @moduledoc """
  Handler for the browser.request control plane method.

  Proxies browser automation requests to a paired browser node.
  Awaited requests consume the registry's private terminal delivery directly;
  durable invocation records remain summary-only.

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

  alias LemonControlPlane.NodeStore
  alias LemonControlPlane.Methods.NodeInvokeResult
  alias LemonControlPlane.Protocol.Errors
  alias LemonBrowser.RoutePolicy

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

    case normalize_method(method) do
      {:ok, method} ->
        # Find browser node
        browser_node = if(force_local, do: nil, else: find_browser_node(node_id))

        cond do
          browser_node == nil and local_fallback_enabled?() ->
            with {:ok, args, network_policy} <- prepare_request(method, args) do
              run_local(method, args, timeout_ms, network_policy)
            end

          browser_node == nil ->
            {:error, Errors.not_found("No browser node available. Pair a browser node first.")}

          true ->
            node = browser_node

            # Get node ID (handle both atom and string keys)
            actual_node_id = get_field(node, :id) || node_id

            if LemonCore.NodeRegistry.online?(actual_node_id) do
              with {:ok, args, network_policy} <- prepare_request(method, args),
                   {:ok, invoke} <-
                     invoke_browser_node(actual_node_id, method, args, timeout_ms, ctx) do
                complete_invoke(invoke, network_policy, await_result, timeout_ms)
              end
            else
              {:error, Errors.unavailable("Browser node is not online")}
            end
        end

      {:error, {:invalid_request, _message} = error} ->
        {:error, error}

      {:error, message} when is_binary(message) ->
        {:error, Errors.invalid_request(message)}
    end
  end

  defp normalize_method(nil), do: {:error, Errors.invalid_request("method is required")}
  defp normalize_method(""), do: {:error, Errors.invalid_request("method is required")}

  defp normalize_method(method) when not is_binary(method),
    do: {:error, "method must be a string"}

  defp normalize_method("browser." <> rest = method) when rest != "", do: {:ok, method}
  defp normalize_method(method), do: {:ok, "browser.#{method}"}

  defp prepare_request("browser.navigate", args) when is_map(args) do
    route = Map.get(args, "route")

    with {:ok, url} <- required_url(args),
         {:ok, policy} <- RoutePolicy.validate_navigation(url, route) do
      {:ok, Map.delete(args, "route"), policy}
    else
      {:error, message} when is_binary(message) ->
        {:error, Errors.invalid_request(message)}
    end
  end

  defp prepare_request(_method, args) when is_map(args), do: {:ok, args, nil}

  defp prepare_request(_method, _args),
    do: {:error, Errors.invalid_request("args must be an object")}

  defp required_url(%{"url" => url}) when is_binary(url) and url != "", do: {:ok, url}
  defp required_url(_args), do: {:error, "url is required"}

  defp maybe_add_network_policy(result, nil), do: result

  defp maybe_add_network_policy(result, policy) when is_map(result) do
    Map.put(result, "networkPolicy", RoutePolicy.safe(policy))
  end

  defp maybe_add_network_policy(result, _policy), do: result

  defp invoke_browser_node(node_id, method, args, timeout_ms, ctx) do
    invoke_params = %{
      "nodeId" => node_id,
      "method" => method,
      "args" => args,
      "timeoutMs" => timeout_ms
    }

    LemonControlPlane.Methods.NodeInvoke.handle(invoke_params, ctx)
  end

  defp complete_invoke(invoke, network_policy, true, timeout_ms) do
    invoke
    |> maybe_add_network_policy(network_policy)
    |> await_invoke(timeout_ms)
    |> attach_summary("node", network_policy, true, timeout_ms)
  end

  defp complete_invoke(invoke, network_policy, false, timeout_ms) do
    invoke
    |> maybe_add_network_policy(network_policy)
    |> attach_summary("node", network_policy, false, timeout_ms)
  end

  defp add_network_policy_to_local_result(result, nil), do: result

  defp add_network_policy_to_local_result(result, policy) when is_map(result) do
    Map.put(result, "networkPolicy", RoutePolicy.safe(policy))
  end

  defp add_network_policy_to_local_result(result, _policy), do: result

  defp local_fallback_enabled? do
    Application.get_env(:lemon_control_plane, :browser_local_fallback, true)
  end

  defp run_local(method, args, timeout_ms, network_policy) do
    case LemonBrowser.LocalServer.request(method, args, timeout_ms) do
      {:ok, result} ->
        %{
          "mode" => "local",
          "ok" => true,
          "method" => method,
          "result" => add_network_policy_to_local_result(result, network_policy)
        }
        |> attach_summary("local", network_policy, true, timeout_ms)

      {:error, reason} ->
        {:error, Errors.unavailable(reason)}
    end
  end

  defp await_invoke(%{"invokeId" => invoke_id} = invoke, timeout_ms) when is_binary(invoke_id) do
    receive do
      {:lemon_node_result, ^invoke_id, result} ->
        finish_awaited_invoke(invoke, invoke_id, result)
    after
      max(0, timeout_ms) ->
        # The registry owns the remote cancellation and sends the same private
        # terminal notification whether its timer or this local deadline wins.
        :ok = LemonCore.NodeRegistry.cancel(invoke_id, :timeout)

        receive do
          {:lemon_node_result, ^invoke_id, result} ->
            finish_awaited_invoke(invoke, invoke_id, result)
        after
          0 -> {:ok, invoke}
        end
    end
  end

  defp await_invoke(invoke, _timeout_ms), do: {:ok, invoke}

  defp attach_summary(
         {:ok, %{"method" => method} = payload},
         mode,
         network_policy,
         await_result,
         timeout_ms
       ) do
    {:ok, attach_summary(payload, method, mode, network_policy, await_result, timeout_ms)}
  end

  defp attach_summary({:ok, payload}, mode, network_policy, await_result, timeout_ms)
       when is_map(payload) do
    method = payload["method"] || payload[:method] || "browser.unknown"
    {:ok, attach_summary(payload, method, mode, network_policy, await_result, timeout_ms)}
  end

  defp attach_summary(
         %{"method" => method} = payload,
         mode,
         network_policy,
         await_result,
         timeout_ms
       ) do
    {:ok, attach_summary(payload, method, mode, network_policy, await_result, timeout_ms)}
  end

  defp attach_summary(payload, mode, network_policy, await_result, timeout_ms)
       when is_map(payload) do
    method = payload["method"] || payload[:method] || "browser.unknown"
    {:ok, attach_summary(payload, method, mode, network_policy, await_result, timeout_ms)}
  end

  defp attach_summary(other, _mode, _network_policy, _await_result, _timeout_ms), do: other

  defp attach_summary(payload, method, mode, network_policy, await_result, timeout_ms) do
    payload
    |> maybe_put_node_summary()
    |> Map.put(
      "summary",
      browser_summary(payload, method, mode, network_policy, await_result, timeout_ms)
    )
  end

  defp maybe_put_node_summary(%{"summary" => node_summary} = payload) when is_map(node_summary),
    do: Map.put(payload, "nodeInvokeSummary", node_summary)

  defp maybe_put_node_summary(payload), do: payload

  defp browser_summary(payload, method, mode, network_policy, await_result, timeout_ms) do
    result_returned = Map.has_key?(payload, "result") or Map.has_key?(payload, :result)
    error_returned = Map.has_key?(payload, "error") or Map.has_key?(payload, :error)

    %{
      "mode" => mode,
      "method" => method,
      "awaited" => await_result,
      "timeoutMs" => timeout_ms,
      "resultReturned" => result_returned,
      "errorReturned" => error_returned,
      "networkPolicyReturned" => not is_nil(network_policy),
      "cleanup" => browser_cleanup(method, result_returned, error_returned)
    }
  end

  defp browser_cleanup(method, result_returned, error_returned) do
    %{
      "includesArgs" => false,
      "includesRawUrl" => false,
      "includesSelectors" => false,
      "includesTypedText" => false,
      "includesPageContent" => result_returned and method == "browser.getContent",
      "includesScreenshotData" => result_returned and method == "browser.screenshot",
      "includesCookieValues" => result_returned and method == "browser.getCookies",
      "includesEvaluatedResult" => result_returned and method == "browser.evaluate",
      "includesErrorText" => error_returned,
      "includesCredentials" => false,
      "includesSecretValues" => false
    }
  end

  defp finish_awaited_invoke(invoke, invoke_id, result) do
    :ok = NodeInvokeResult.record_registry_result(invoke_id, result)
    {:ok, Map.merge(invoke, awaited_result(result))}
  end

  defp awaited_result({:ok, result}) do
    %{"status" => "completed", "ok" => true, "result" => result}
  end

  defp awaited_result({:error, {:remote, error}}) do
    %{"status" => "error", "ok" => false, "error" => error}
  end

  defp awaited_result({:error, reason}) do
    error = inspect(reason, limit: 20, printable_limit: 1_000)
    %{"status" => "error", "ok" => false, "error" => error}
  end

  defp find_browser_node(nil) do
    # Try to find a default browser node
    case NodeStore.list_nodes() do
      nodes when is_list(nodes) ->
        Enum.find_value(nodes, fn {_id, node} ->
          node_type = get_field(node, :type)
          node_id = get_field(node, :id)

          if (node_type == "browser" or node_type == :browser) and
               is_binary(node_id) and LemonCore.NodeRegistry.online?(node_id),
             do: node
        end)

      _ ->
        nil
    end
  end

  defp find_browser_node(node_id) do
    NodeStore.get_node(node_id)
  end

  # Safe map access supporting both atom and string keys
  defp get_field(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
