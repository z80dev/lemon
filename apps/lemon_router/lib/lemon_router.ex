defmodule LemonRouter do
  @moduledoc """
  LemonRouter provides orchestration and routing for agent runs.

  This app is responsible for:

  - Session key management and parsing
  - Run orchestration and lifecycle
  - Stream coalescing for efficient channel output
  - Policy merging for tool execution
  - Abort handling and run cancellation
  - Bridging between channels and gateway

  ## Session Keys

  Session keys provide a stable identifier for routing and state:

  - Main: `agent:<agent_id>:main`
  - Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>]`

  ## Architecture

  ```
  [Channels] -> [Router] -> [Gateway] -> [Engine]
       ^          |
       |          v
       +--- [StreamCoalescer]
  ```
  """

  @doc """
  Submit a run request to the router.
  """
  defdelegate submit(params), to: LemonRouter.RunOrchestrator

  @doc """
  Abort a session's active run.
  """
  defdelegate abort(session_key, reason \\ :user_requested), to: LemonRouter.Router

  @doc """
  Abort a specific run by ID.
  """
  defdelegate abort_run(run_id, reason \\ :user_requested), to: LemonRouter.Router
end
