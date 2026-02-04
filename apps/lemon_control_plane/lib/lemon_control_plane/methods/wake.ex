defmodule LemonControlPlane.Methods.Wake do
  @moduledoc """
  Handler for the wake control plane method.

  Triggers an immediate agent wake/prompt execution.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Protocol.Errors

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
            {:ok, %{
              "runId" => run_id,
              "agentId" => agent_id,
              "triggered" => true
            }}

          {:error, reason} ->
            {:error, Errors.internal_error("Wake failed", inspect(reason))}
        end
      else
        # Fallback: submit directly via router
        if Code.ensure_loaded?(LemonRouter.RunOrchestrator) do
          session_key = session_key || LemonRouter.SessionKey.main(agent_id)

          case LemonRouter.RunOrchestrator.submit(%{
                 origin: :control_plane,
                 session_key: session_key,
                 agent_id: agent_id,
                 prompt: prompt,
                 queue_mode: :collect,
                 meta: %{triggered_by: :wake}
               }) do
            {:ok, run_id} ->
              {:ok, %{
                "runId" => run_id,
                "agentId" => agent_id,
                "triggered" => true
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
end
