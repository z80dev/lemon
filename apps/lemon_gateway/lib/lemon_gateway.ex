defmodule LemonGateway do
  @moduledoc """
  Public API for submitting execution commands to the Lemon Gateway.

  The gateway schedules native AI agent runs across transport channels
  (Telegram, Discord, Email, XMTP, and Webhooks) through one configured
  executor.

  ## Usage

      command = %LemonCore.ExecutionCommand{
        run_id: "run_123",
        prompt: "Fix the failing test",
        session_key: "telegram:12345",
        conversation_key: {:session, "telegram:12345"}
      }

      LemonGateway.submit(command)
  """

  alias LemonCore.ExecutionCommand

  @doc """
  Submits an execution command for execution.

  Starts a Run directly. The Run claims its engine session before waiting
  for a global execution permit; the router owns conversation ordering. No
  router admission covers this run, so it is refused with
  `{:error, :session_lifecycle_in_progress}` while a session reset or delete
  holds its session, and is reported as session activity until it ends.
  """
  @spec submit(ExecutionCommand.t()) :: :ok | {:error, term()}
  def submit(%ExecutionCommand{} = command), do: LemonGateway.Runtime.submit_unadmitted(command)
end
