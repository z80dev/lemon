defmodule LemonControlPlane.Methods.GoalClear do
  @moduledoc """
  Handler for `goal.clear`.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "goal.clear"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = param(params || %{}, "sessionKey")

    if is_nil(session_key) or String.trim(to_string(session_key)) == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      case LemonCore.GoalStore.clear(session_key) do
        :ok ->
          {:ok,
           %{"sessionKey" => session_key, "cleared" => true, "summary" => summary(session_key)}}

        {:error, reason} ->
          {:error, {:internal_error, inspect(reason), nil}}
      end
    end
  end

  defp summary(session_key) do
    %{
      "sessionKey" => session_key,
      "cleared" => true,
      "objectiveReturned" => false,
      "cleanup" => %{
        "includesObjectiveText" => false,
        "includesPromptText" => false,
        "includesMessageBodies" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, Macro.underscore(key))
end
