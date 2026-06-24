defmodule LemonGateway do
  @moduledoc """
  Public API for submitting execution commands to the Lemon Gateway.

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

  @doc """
  Submits an execution command for execution.

  The request is routed through the scheduler, which handles concurrency
  limiting per conversation key.
  """
  @spec submit(ExecutionCommand.t()) :: :ok
  def submit(%ExecutionCommand{} = command), do: LemonGateway.Runtime.submit_execution(command)
end
