defmodule LemonControlPlane.Methods.BrowserControllerStatus do
  @moduledoc "Return redacted browser-controller broker status."

  @behaviour LemonControlPlane.Method

  alias LemonBrowser.ControllerBroker

  @impl true
  def name, do: "browser.controller.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    status = ControllerBroker.status()

    {:ok,
     %{
       "controllerCount" => status.controller_count,
       "pendingRequestCount" => status.pending_request_count,
       "unconsumedTicketCount" => status.unconsumed_ticket_count,
       "allowedCapabilities" => status.allowed_capabilities,
       "controllers" => Enum.map(status.controllers, &public/1)
     }}
  end

  defp public(controller) do
    %{
      "controllerId" => controller.controller_id,
      "browserProfileId" => controller.browser_profile_id,
      "sessionId" => controller.session_id,
      "runId" => controller.run_id,
      "capabilities" => controller.capabilities,
      "metadata" => controller.metadata,
      "connectedAtMs" => controller.connected_at_ms,
      "lastHeartbeatAtMs" => controller.last_heartbeat_at_ms
    }
  end
end
