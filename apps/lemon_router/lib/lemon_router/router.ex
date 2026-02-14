defmodule LemonRouter.Router do
  @moduledoc """
  Main router for handling inbound messages and control plane requests.

  The router is responsible for:
  - Normalizing inbound messages from different channels
  - Routing to the appropriate session
  - Handling abort requests
  """

  alias LemonRouter.{RunOrchestrator, SessionKey}

  require Logger

  @doc """
  Handle an inbound message from a channel.

  Normalizes the message and submits it to the orchestrator.
  """
  @spec handle_inbound(LemonCore.InboundMessage.t()) :: :ok
  def handle_inbound(%LemonCore.InboundMessage{} = msg) do
    # Emit inbound telemetry
    emit_inbound_telemetry(msg)

    session_key = resolve_session_key(msg)
    agent_id = msg.meta[:agent_id] || SessionKey.agent_id(session_key) || "default"

    # Submit to orchestrator
    case RunOrchestrator.submit(%{
           origin: :channel,
           session_key: session_key,
           agent_id: agent_id,
           prompt: msg.message.text,
           queue_mode: msg.meta[:queue_mode] || :collect,
           engine_id: msg.meta[:engine_id],
           meta:
             Map.merge(msg.meta || %{}, %{
               channel_id: msg.channel_id,
               account_id: msg.account_id,
               peer: msg.peer,
               sender: msg.sender,
               raw: msg.raw
             })
         }) do
      {:ok, _run_id} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RunOrchestrator.submit failed for inbound (channel_id=#{inspect(msg.channel_id)} account_id=#{inspect(msg.account_id)} peer_id=#{inspect(msg.peer && msg.peer.id)}): " <>
            inspect(reason)
        )

        :ok
    end

    :ok
  end

  @doc false
  def resolve_session_key(%LemonCore.InboundMessage{} = msg) do
    meta = msg.meta || %{}

    candidate =
      cond do
        is_binary(meta[:session_key]) and meta[:session_key] != "" ->
          meta[:session_key]

        is_binary(meta["session_key"]) and meta["session_key"] != "" ->
          meta["session_key"]

        true ->
          nil
      end

    if is_binary(candidate) and SessionKey.valid?(candidate) do
      candidate
    else
      SessionKey.channel_peer(%{
        agent_id: meta[:agent_id] || meta["agent_id"] || "default",
        channel_id: msg.channel_id,
        account_id: msg.account_id,
        peer_kind: msg.peer.kind,
        peer_id: msg.peer.id,
        thread_id: msg.peer.thread_id
      })
    end
  end

  defp emit_inbound_telemetry(msg) do
    LemonCore.Telemetry.channel_inbound(msg.channel_id, %{
      account_id: msg.account_id,
      peer_kind: msg.peer.kind,
      agent_id: msg.meta[:agent_id] || "default"
    })
  rescue
    _ -> :ok
  end

  @doc """
  Handle a control plane agent request.

  Returns the run_id and session_key for tracking.
  """
  @spec handle_control_agent(params :: map(), ctx :: map()) ::
          {:ok, %{run_id: binary(), session_key: binary()}}
          | {:error, %{code: binary(), message: binary(), details: term()}}
  def handle_control_agent(params, ctx) do
    session_key = params[:session_key] || SessionKey.main(params[:agent_id] || "default")

    case RunOrchestrator.submit(%{
           origin: :control_plane,
           session_key: session_key,
           agent_id: params[:agent_id] || "default",
           prompt: params[:prompt],
           queue_mode: params[:queue_mode] || :collect,
           engine_id: params[:engine_id],
           meta:
             Map.merge(params[:meta] || %{}, %{
               control_plane_ctx: ctx
             })
         }) do
      {:ok, run_id} ->
        {:ok, %{run_id: run_id, session_key: session_key}}

      {:error, reason} ->
        {:error, %{code: "SUBMIT_FAILED", message: "Failed to submit run", details: reason}}
    end
  end

  @doc """
  Abort all runs for a session.
  """
  @spec abort(session_key :: binary(), reason :: term()) :: :ok
  def abort(session_key, reason \\ :user_requested) do
    # Find active run for session
    LemonRouter.SessionRegistry
    |> Registry.lookup(session_key)
    |> Enum.reduce(MapSet.new(), fn
      {_pid, %{run_id: run_id}}, acc when is_binary(run_id) -> MapSet.put(acc, run_id)
      _, acc -> acc
    end)
    |> Enum.each(&abort_run(&1, reason))

    :ok
  end

  @doc """
  Abort a specific run by ID.
  """
  @spec abort_run(run_id :: binary(), reason :: term()) :: :ok
  def abort_run(run_id, reason \\ :user_requested) do
    case Registry.lookup(LemonRouter.RunRegistry, run_id) do
      [{pid, _}] ->
        LemonRouter.RunProcess.abort(pid, reason)

      _ ->
        # Run not found, might have already completed
        :ok
    end
  end
end
