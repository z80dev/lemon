defmodule LemonControlPlane.Methods.SessionsDelete do
  @moduledoc """
  Handler for the sessions.delete method.

  Deletes a session and its history through `LemonCore.SessionLifecycle.delete/1`
  under the session's run-admission fence
  (`LemonControlPlane.Methods.SessionLifecycleFence`). Success is reported only
  after the deletion is verified.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SessionLifecycleFence
  alias LemonCore.SessionLifecycle

  @impl true
  def name, do: "sessions.delete"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    case params["sessionKey"] do
      session_key when is_binary(session_key) and session_key != "" ->
        delete = &SessionLifecycle.delete(session_key, fence_generation: &1)

        case SessionLifecycleFence.run(session_key, :delete, delete) do
          {:ok, %{verified: true} = deletion} -> {:ok, summary(session_key, deletion)}
          {:error, reason} -> SessionLifecycleFence.failure(reason, "deletion")
          _unexpected -> SessionLifecycleFence.failure(:outcome_unknown, "deletion")
        end

      _ ->
        {:error, {:invalid_request, "sessionKey is required", nil}}
    end
  end

  defp summary(session_key, deletion) do
    %{
      "deleted" => true,
      "sessionKey" => session_key,
      "summary" => %{
        "sessionKey" => session_key,
        "deleted" => true,
        "existed" => deletion.existed,
        "verified" => true,
        "cleanup" => %{
          "deletedRunSession" => true,
          "deletedChatState" => true,
          "deletedSessionPolicy" => true,
          "deletedLifecycleMetadata" => true,
          "includesMessages" => false,
          "includesPolicy" => false,
          "includesSecretValues" => false
        }
      }
    }
  end
end
