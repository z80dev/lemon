defmodule LemonControlPlane.Methods.SessionsReset do
  @moduledoc """
  Handler for the sessions.reset method.

  Resets a session's conversation history through
  `LemonCore.SessionLifecycle.reset/1` under the session's run-admission fence
  (`LemonControlPlane.Methods.SessionLifecycleFence`). Success is reported only
  after every deletion is verified.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SessionLifecycleFence
  alias LemonCore.SessionLifecycle

  @impl true
  def name, do: "sessions.reset"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    case params["sessionKey"] do
      session_key when is_binary(session_key) and session_key != "" ->
        reset = &SessionLifecycle.reset(session_key, fence_generation: &1)

        case SessionLifecycleFence.run(session_key, :reset, reset) do
          {:ok, %{verified: true}} -> {:ok, summary(session_key)}
          {:error, reason} -> SessionLifecycleFence.failure(reason, "reset")
          _unexpected -> SessionLifecycleFence.failure(:outcome_unknown, "reset")
        end

      _ ->
        {:error, {:invalid_request, "sessionKey is required", nil}}
    end
  end

  defp summary(session_key) do
    %{
      "success" => true,
      "sessionKey" => session_key,
      "summary" => %{
        "sessionKey" => session_key,
        "reset" => true,
        "verified" => true,
        "cleanup" => %{
          "deletedRunHistory" => true,
          "deletedChatState" => true,
          "deletedSessionPolicy" => true,
          "includesMessages" => false,
          "includesPolicy" => false,
          "includesSecretValues" => false
        }
      }
    }
  end
end
