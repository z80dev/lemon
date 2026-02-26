defmodule LemonControlPlane.Methods.SessionsPatch do
  @moduledoc """
  Handler for the sessions.patch method.

  Updates session properties (like tool policy overrides).
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.patch"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      patch =
        %{
          tool_policy: params["toolPolicy"],
          model: params["model"],
          thinking_level: params["thinkingLevel"],
          preferred_engine: params["preferredEngine"]
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()

      case apply_session_patch(session_key, patch) do
        :ok ->
          {:ok, %{"success" => true, "sessionKey" => session_key}}

        {:error, reason} ->
          {:error, {:internal_error, "Failed to patch session", reason}}
      end
    end
  end

  defp apply_session_patch(session_key, patch) do
    # Store session policies (router reads from :session_policies, not :session_overrides)
    existing = LemonCore.Store.get_session_policy(session_key) || %{}
    updated = Map.merge(existing, patch)
    LemonCore.Store.put_session_policy(session_key, updated)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end
end
