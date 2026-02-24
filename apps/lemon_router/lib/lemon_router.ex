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

  @doc """
  Apply a watchdog keepalive decision to a specific run.
  """
  defdelegate keep_run_alive(run_id, decision \\ :continue), to: LemonRouter.Router

  @doc """
  Send a message to an agent inbox.

  Supports `session: :latest | :new | <session_key>`.
  """
  @spec send_to_agent(binary(), binary(), keyword()) ::
          {:ok, %{run_id: binary(), session_key: binary(), selector: term()}} | {:error, term()}
  def send_to_agent(agent_id, prompt, opts \\ []) do
    LemonRouter.AgentInbox.send(agent_id, prompt, opts)
  end

  @doc """
  Resolve an agent session selector (`:latest`, `:new`, explicit key) to a concrete session.
  """
  @spec resolve_agent_session(binary(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_agent_session(agent_id, selector \\ :latest, opts \\ []) do
    LemonRouter.AgentInbox.resolve_session(agent_id, selector, opts)
  end

  @doc """
  List agent directory entries with routing/session discoverability metadata.
  """
  @spec list_agent_directory(keyword()) :: [map()]
  def list_agent_directory(opts \\ []) do
    LemonRouter.AgentDirectory.list_agents(opts)
  end

  @doc """
  List known sessions from the agent directory/phonebook.
  """
  @spec list_agent_sessions(keyword()) :: [map()]
  def list_agent_sessions(opts \\ []) do
    LemonRouter.AgentDirectory.list_sessions(opts)
  end

  @doc """
  List known channel targets (for example Telegram rooms/topics) with friendly labels.
  """
  @spec list_agent_targets(keyword()) :: [map()]
  def list_agent_targets(opts \\ []) do
    LemonRouter.AgentDirectory.list_targets(opts)
  end

  @doc """
  List persisted endpoint aliases.
  """
  @spec list_agent_endpoints(keyword()) :: [map()]
  def list_agent_endpoints(opts \\ []) do
    LemonRouter.AgentEndpoints.list(opts)
  end

  @doc """
  Upsert an endpoint alias for an agent.
  """
  @spec set_agent_endpoint(binary(), binary(), term(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def set_agent_endpoint(agent_id, name, target, opts \\ []) do
    LemonRouter.AgentEndpoints.put(agent_id, name, target, opts)
  end

  @doc """
  Delete an endpoint alias.
  """
  @spec delete_agent_endpoint(binary(), binary()) :: :ok | {:error, term()}
  def delete_agent_endpoint(agent_id, name) do
    LemonRouter.AgentEndpoints.delete(agent_id, name)
  end
end
