defmodule LemonControlPlane.Methods.BrowserControllerHeartbeat do
  @moduledoc "Refresh liveness for the controller bound to this WebSocket."

  @behaviour LemonControlPlane.Method

  alias LemonBrowser.ControllerBroker
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "browser.controller.heartbeat"

  @impl true
  def scopes, do: []

  @impl true
  def handle(params, ctx) do
    with controller_id when is_binary(controller_id) and controller_id != "" <-
           params["controllerId"],
         conn_pid when is_pid(conn_pid) <- ctx[:conn_pid],
         :ok <- ControllerBroker.heartbeat(controller_id, conn_pid) do
      {:ok, %{"controllerId" => controller_id, "alive" => true}}
    else
      nil -> {:error, Errors.invalid_request("controllerId is required")}
      false -> {:error, Errors.invalid_request("controllerId is required")}
      {:error, reason} -> {:error, Errors.forbidden("Browser controller rejected: #{reason}")}
      _ -> {:error, Errors.unavailable("Browser controller requires a WebSocket connection")}
    end
  end
end
