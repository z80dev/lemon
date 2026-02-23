defmodule LemonControlPlane.Methods.EventsUnsubscribe do
  @moduledoc """
  Handler for the `events.unsubscribe` control-plane method.

  Remove an agent session's subscription to external events.

  ## Parameters

    * `sessionKey` - Required. The session to unsubscribe

  ## Examples

      {
        "method": "events.unsubscribe",
        "params": {
          "sessionKey": "agent:zeebot:main"
        }
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "events.unsubscribe"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, session_key} <- get_required_param(params, "sessionKey"),
         :ok <- ensure_ingestion_loaded(),
         :ok <- LemonIngestion.unsubscribe(session_key) do
      {:ok, %{"sessionKey" => session_key, "unsubscribed" => true}}
    else
      {:error, :app_not_loaded} ->
        {:error, {:internal_error, "Ingestion service not available", nil}}

      {:error, reason} ->
        {:error, {:internal_error, "Failed to unsubscribe", inspect(reason)}}
    end
  end

  defp ensure_ingestion_loaded do
    if Code.ensure_loaded?(LemonIngestion) do
      :ok
    else
      {:error, :app_not_loaded}
    end
  end

  defp get_required_param(params, key) do
    case Map.get(params, key) || Map.get(params, Macro.underscore(key)) do
      nil -> {:error, :missing_param, key}
      "" -> {:error, :missing_param, key}
      value -> {:ok, value}
    end
  end
end
