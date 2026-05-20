defmodule LemonControlPlane.Methods.Wake do
  @moduledoc """
  Handler for the wake control plane method.

  Triggers an immediate agent wake/prompt execution.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.RunRequest

  @impl true
  def name, do: "wake"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    agent_id = params["agentId"] || params["agent_id"] || "default"
    prompt = params["prompt"]
    session_key = params["sessionKey"] || params["session_key"]

    if is_nil(prompt) or prompt == "" do
      {:error, Errors.invalid_request("prompt is required")}
    else
      # Use the LemonAutomation.Wake module if available
      if Code.ensure_loaded?(LemonAutomation.Wake) do
        case LemonAutomation.Wake.trigger(%{
               agent_id: agent_id,
               prompt: prompt,
               session_key: session_key
             }) do
          {:ok, run_id} ->
            {:ok,
             %{
               "runId" => run_id,
               "agentId" => agent_id,
               "triggered" => true,
               "summary" => summary(agent_id, run_id, session_key, prompt)
             }}

          {:error, reason} ->
            {:error, Errors.internal_error("Wake failed", inspect(reason))}
        end
      else
        # Fallback: submit directly via router
        if Code.ensure_loaded?(LemonRouter.RunOrchestrator) do
          session_key = session_key || LemonCore.SessionKey.main(agent_id)

          request =
            RunRequest.new(%{
              origin: :control_plane,
              session_key: session_key,
              agent_id: agent_id,
              prompt: prompt,
              queue_mode: :collect,
              meta: %{triggered_by: :wake}
            })

          case LemonRouter.RunOrchestrator.submit(request) do
            {:ok, run_id} ->
              {:ok,
               %{
                 "runId" => run_id,
                 "agentId" => agent_id,
                 "triggered" => true,
                 "summary" => summary(agent_id, run_id, session_key, prompt)
               }}

            {:error, reason} ->
              {:error, Errors.internal_error("Wake failed", inspect(reason))}
          end
        else
          {:error, Errors.not_implemented("RunOrchestrator not available")}
        end
      end
    end
  end

  defp summary(agent_id, run_id, session_key, prompt) do
    %{
      "action" => name(),
      "triggered" => true,
      "agentIdReturned" => is_binary(agent_id) and agent_id != "",
      "runIdReturned" => is_binary(run_id) and run_id != "",
      "sessionKeyReturned" => is_binary(session_key) and session_key != "",
      "promptBytes" => byte_size(prompt || ""),
      "cleanup" => %{
        "includesPrompt" => false,
        "includesMessageText" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end
end
