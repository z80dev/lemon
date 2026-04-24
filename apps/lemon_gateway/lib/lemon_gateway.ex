defmodule LemonGateway do
  @moduledoc """
  Public API for submitting execution requests to the Lemon Gateway.

  The gateway orchestrates AI agent runs across multiple transport channels
  (Telegram, Discord, Email, Farcaster, XMTP, Webhooks) and engine backends
  (Lemon, Claude, Codex, Opencode, Pi).

  ## Usage

      command = %LemonCore.ExecutionCommand{
        run_id: "run_123",
        prompt: "Fix the failing test",
        engine_id: "lemon",
        session_key: "telegram:12345",
        conversation_key: {:session, "telegram:12345"}
      }

      LemonGateway.submit(command)
  """

  alias LemonCore.ExecutionCommand
  alias LemonGateway.ExecutionRequest

  @doc """
  Submits an execution request for execution.

  The request is routed through the scheduler, which handles concurrency
  limiting per conversation key.
  """
  @spec submit(ExecutionCommand.t() | ExecutionRequest.t()) :: :ok
  def submit(%ExecutionCommand{} = command), do: LemonGateway.Runtime.submit_execution(command)
  def submit(%ExecutionRequest{} = request), do: LemonGateway.Runtime.submit_execution(request)
end
