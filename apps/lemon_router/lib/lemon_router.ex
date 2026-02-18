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

  alias LemonCore.RunRequest

  @doc """
  Submit a run request to the router.

  Accepts either a normalized `%LemonCore.RunRequest{}` or a legacy map/keyword
  payload that can be normalized into one.
  """
  @spec submit(RunRequest.t() | map() | keyword()) :: {:ok, binary()} | {:error, term()}
  def submit(%RunRequest{} = params), do: LemonRouter.RunOrchestrator.submit(params)

  def submit(params) when is_map(params) or is_list(params) do
    params
    |> RunRequest.new()
    |> LemonRouter.RunOrchestrator.submit()
  end

  @doc """
  Abort a session's active run.
  """
  defdelegate abort(session_key, reason \\ :user_requested), to: LemonRouter.Router

  @doc """
  Abort a specific run by ID.
  """
  defdelegate abort_run(run_id, reason \\ :user_requested), to: LemonRouter.Router
end
