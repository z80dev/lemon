defmodule LemonGateway do
  @moduledoc """
  Public API for submitting execution requests to the Lemon Gateway.

  The gateway orchestrates AI agent runs across multiple transport channels
  (Telegram, Discord, Email, Farcaster, XMTP, Webhooks) and engine backends
  (Lemon, Claude, Codex, Opencode, Pi).

  ## Usage

      request = %LemonGateway.ExecutionRequest{
        prompt: "Fix the failing test",
        engine_id: "lemon",
        session_key: "telegram:12345",
        conversation_key: {:session, "telegram:12345"}
      }

      LemonGateway.submit(request)
  """

  alias LemonGateway.ExecutionRequest

  @doc """
  Submits an execution request for execution.

  The request is routed through the scheduler, which handles concurrency
  limiting per conversation key.
  """
  @spec submit(ExecutionRequest.t()) :: :ok
  def submit(%ExecutionRequest{} = request), do: LemonGateway.Runtime.submit_execution(request)
end
