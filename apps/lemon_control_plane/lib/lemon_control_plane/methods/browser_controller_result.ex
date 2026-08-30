defmodule LemonControlPlane.Methods.BrowserControllerResult do
  @moduledoc "Accept a browser command result from its exact registered WebSocket."

  @behaviour LemonControlPlane.Method

  alias LemonBrowser.ControllerBroker
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "browser.controller.result"

  @impl true
  def scopes, do: []

  @impl true
  def handle(params, ctx) do
    controller_id = params["controllerId"]
    request_id = params["requestId"]
    conn_pid = ctx[:conn_pid]

    cond do
      not is_binary(controller_id) or controller_id == "" ->
        {:error, Errors.invalid_request("controllerId is required")}

      not is_binary(request_id) or request_id == "" ->
        {:error, Errors.invalid_request("requestId is required")}

      not is_pid(conn_pid) ->
        {:error, Errors.unavailable("Browser controller requires a WebSocket connection")}

      true ->
        result =
          if is_nil(params["error"]),
            do: {:ok, params["result"]},
            else: {:error, params["error"]}

        case ControllerBroker.complete(controller_id, conn_pid, request_id, result) do
          :ok -> {:ok, %{"requestId" => request_id, "received" => true}}
          {:error, reason} -> {:error, Errors.forbidden("Browser result rejected: #{reason}")}
        end
    end
  end
end
