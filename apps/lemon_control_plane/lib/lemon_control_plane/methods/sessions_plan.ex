defmodule LemonControlPlane.Methods.SessionsPlan do
  @moduledoc """
  Inspect, enter or exit native plan mode. Leaving plan mode never approves a
  plan: approval is the user's answer to the agent's `propose_plan` request.
  """
  @behaviour LemonControlPlane.Method

  alias LemonCore.AgentRuntime
  alias LemonControlPlane.Methods.NativeSessions

  @actions %{"status" => :status, "enter" => :enter, "exit" => :exit}
  @impl true
  def name, do: "sessions.plan"
  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    with {:ok, key, cwd} <- NativeSessions.target(params),
         {:ok, action} <- action(params) do
      args = [key, cwd, action, []]

      # `status` only reads the plan; `enter` and `exit` change the session.
      result =
        if action == :status,
          do: AgentRuntime.query(:session_plan, args),
          else: AgentRuntime.mutate(:session_plan, args)

      case result do
        {:ok, plan} when is_map(plan) -> {:ok, %{"sessionKey" => key, "plan" => plan}}
        {:error, reason} -> NativeSessions.failure(reason)
        _ when action == :status -> NativeSessions.failure(:invalid_response)
        _ -> NativeSessions.failure(:outcome_unknown)
      end
    end
  end

  defp action(params) do
    case Map.fetch(@actions, params["action"]) do
      {:ok, action} -> {:ok, action}
      :error -> NativeSessions.invalid("action must be status, enter, or exit")
    end
  end
end
