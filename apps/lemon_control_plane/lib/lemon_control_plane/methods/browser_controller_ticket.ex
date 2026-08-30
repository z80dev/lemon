defmodule LemonControlPlane.Methods.BrowserControllerTicket do
  @moduledoc "Mint a scoped, short-lived browser-controller registration ticket."

  @behaviour LemonControlPlane.Method

  alias LemonBrowser.ControllerBroker
  alias LemonControlPlane.Protocol.Errors

  @impl true
  def name, do: "browser.controller.ticket"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    with {:ok, principal_id} <- authenticated_principal(ctx),
         {:ok, attrs} <- identity_attrs(params, principal_id),
         {:ok, issued} <-
           ControllerBroker.issue_ticket(attrs, ttl_ms: params["ttlMs"] || 30_000) do
      {:ok,
       %{
         "ticket" => issued.ticket,
         "expiresAtMs" => issued.expires_at_ms,
         "controllerId" => issued.controller_id,
         "capabilities" => issued.capabilities,
         "singleUse" => true
       }}
    else
      {:error, :browser_controller_auth_required} ->
        {:error,
         Errors.forbidden(
           "Browser controller tickets require an authenticated control-plane token"
         )}

      {:error, {:missing_browser_controller_identity, field}} ->
        {:error, Errors.invalid_request("#{camel(field)} is required")}

      {:error, reason} ->
        {:error, Errors.invalid_request(inspect(reason))}
    end
  end

  defp authenticated_principal(ctx) do
    auth = ctx[:auth] || %{}
    token = auth[:token]

    if is_binary(token) and token != "" do
      digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
      {:ok, "token-sha256:#{digest}"}
    else
      {:error, :browser_controller_auth_required}
    end
  end

  defp identity_attrs(params, principal_id) do
    attrs = %{
      controller_id: params["controllerId"],
      browser_profile_id: params["browserProfileId"],
      session_id: params["sessionId"],
      run_id: params["runId"],
      capabilities: params["capabilities"] || [],
      principal_id: principal_id
    }

    required = [:controller_id, :browser_profile_id, :session_id]

    case Enum.find(required, &blank?(Map.get(attrs, &1))) do
      nil -> {:ok, attrs}
      field -> {:error, {:missing_browser_controller_identity, field}}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp camel(:controller_id), do: "controllerId"
  defp camel(:browser_profile_id), do: "browserProfileId"
  defp camel(:session_id), do: "sessionId"
end
