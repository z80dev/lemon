defmodule LemonGateway do
  @moduledoc """
  Public API for submitting jobs to the Lemon Gateway.

  The gateway orchestrates AI agent runs across multiple transport channels
  (Telegram, Discord, Email, Farcaster, XMTP, Webhooks) and engine backends
  (Lemon, Claude, Codex, Opencode, Pi).

  ## Usage

      job = %LemonGateway.Types.Job{
        prompt: "Fix the failing test",
        engine_id: "lemon",
        session_key: "telegram:12345"
      }

      LemonGateway.submit(job)
  """

  alias LemonGateway.Types.Job

  @doc """
  Submits a job for execution.

  The job is routed through the scheduler, which handles auto-resume,
  session threading, and concurrency limiting.
  """
  @spec submit(Job.t()) :: :ok
  def submit(%Job{} = job), do: LemonGateway.Runtime.submit(job)
end
