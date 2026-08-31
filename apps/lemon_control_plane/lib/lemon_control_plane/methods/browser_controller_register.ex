defmodule LemonControlPlane.Methods.BrowserControllerRegister do
  @moduledoc "Consume a browser-controller ticket on the current WebSocket."

  @behaviour LemonControlPlane.Method

  alias LemonBrowser.ControllerBroker
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "browser.controller.register"

  @impl true
  def scopes, do: []

  @impl true
  def handle(params, ctx) do
    ticket = params["ticket"]
    conn_pid = ctx[:conn_pid]

    cond do
      not is_binary(ticket) or ticket == "" ->
        {:error, Errors.invalid_request("ticket is required")}

      not is_pid(conn_pid) ->
        {:error, Errors.unavailable("Browser controller requires a WebSocket connection")}

      true ->
        case ControllerBroker.register(ticket, conn_pid, params["metadata"] || %{}) do
          {:ok, controller} ->
            {:ok, public(controller)}

          {:error, reason} ->
            {:error, Errors.forbidden("Browser controller registration rejected: #{reason}")}
        end
    end
  end

  defp public(controller) do
    %{
      "controllerId" => controller.controller_id,
      "browserProfileId" => controller.browser_profile_id,
      "sessionId" => controller.session_id,
      "runId" => controller.run_id,
      "capabilities" => controller.capabilities,
      "connectedAtMs" => controller.connected_at_ms
    }
  end
end
