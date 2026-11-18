defmodule LemonRouter.Router do
  @moduledoc """
  Router control surface registered with `LemonCore.RouterBridge`: session
  and run aborts, keep-alive decisions and session queries.

  Channel ingress does not pass through this module: adapters submit a
  canonical `LemonCore.RunRequest` built by `LemonChannels.RunRequestBuilder`
  via `LemonCore.RouterBridge.submit_run/1`.
  """

  alias LemonRouter.RunOrchestrator

  @doc """
  Abort all runs for a session.
  """
  @spec abort(session_key :: binary(), reason :: term()) :: :ok | {:error, term()}
  def abort(session_key, reason \\ :user_requested) do
    session_coordinator().abort_session(session_key, reason)
  end

  @spec session_busy?(binary()) :: boolean() | {:error, term()}
  def session_busy?(session_key) when is_binary(session_key) do
    session_coordinator().busy?(session_key)
  end

  @spec active_run(binary()) :: {:ok, binary()} | :none | {:error, term()}
  def active_run(session_key) when is_binary(session_key) do
    session_coordinator().active_run_for_session(session_key)
  end

  @spec list_active_sessions() ::
          [%{session_key: binary(), run_id: binary()}] | {:error, term()}
  def list_active_sessions do
    session_coordinator().list_active_sessions()
  end

  @doc """
  Abort a specific run by ID.

  The abort is first serialized with router submission acceptance. If the run
  has not reached the orchestrator yet, a bounded tombstone rejects that future
  submission; if it was already accepted, the normal coordinator and process
  cancellation paths apply.
  """
  @spec abort_run(run_id :: binary(), reason :: term()) :: :ok | {:error, term()}
  def abort_run(run_id, reason \\ :user_requested) do
    # Registration and dispatch are one queued orchestrator operation. If this
    # caller times out, that operation may still complete, but it cannot leave
    # behind a tombstone without also attempting cancellation.
    register_abort_tombstone(run_id, reason)
  end

  defp register_abort_tombstone(run_id, reason) do
    RunOrchestrator.register_abort(run_id, reason)
  catch
    :exit, _reason -> {:error, :outcome_unknown}
  end

  @doc """
  Apply a watchdog keepalive decision to a specific run.
  """
  @spec keep_run_alive(run_id :: binary(), decision :: :continue | :cancel) :: :ok
  def keep_run_alive(run_id, decision \\ :continue) when is_binary(run_id) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] ->
        LemonRouter.RunProcess.keep_alive(pid, decision)

      _ ->
        :ok
    end
  end

  defp session_coordinator do
    Application.get_env(:lemon_router, :session_coordinator, LemonRouter.SessionCoordinator)
  end
end
