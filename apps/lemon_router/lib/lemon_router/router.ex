defmodule LemonRouter.Router do
  @moduledoc """
  Main router for handling inbound messages and control plane requests.

  The router is responsible for:
  - Normalizing inbound messages from different channels
  - Routing to the appropriate session
  - Handling abort requests
  - Delegating policy-bound submission preparation to the orchestrator
  """

  alias LemonCore.RunRequest
  alias LemonCore.SessionKey
  alias LemonRouter.RunOrchestrator

  @doc """
  Handle an inbound message from a channel.

  Normalizes the message and submits it to the orchestrator. Pending compaction
  is prepared by the submission builder after resolving execution capabilities.
  """
  @spec handle_inbound(LemonCore.InboundMessage.t()) :: :ok | {:error, term()}
  def handle_inbound(%LemonCore.InboundMessage{} = msg) do
    # Emit inbound telemetry
    emit_inbound_telemetry(msg)

    meta = normalize_meta(msg.meta)
    session_key = resolve_session_key(msg)

    agent_id =
      meta[:agent_id] || meta["agent_id"] || SessionKey.agent_id(session_key) || "default"

    request = build_inbound_run_request(msg, meta, session_key, agent_id)

    # Submit to orchestrator
    case run_orchestrator().submit(request) do
      {:ok, run_id} when is_binary(run_id) and run_id != "" ->
        :ok

      {:error, _reason} = error ->
        error

      _malformed_acknowledgement ->
        # Submission may already have reached the coordinator. Without a
        # usable run id, neither acceptance nor safe redelivery can be proved.
        {:error, :outcome_unknown}
    end
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
    meta = normalize_meta(msg.meta)

    LemonCore.Telemetry.channel_inbound(msg.channel_id, %{
      account_id: msg.account_id,
      peer_kind: msg.peer.kind,
      agent_id: meta[:agent_id] || meta["agent_id"] || "default"
    })
  end

  @doc """
  Handle a control plane agent request.

  Returns the run_id and session_key for tracking.
  """
  @spec handle_control_agent(params :: map(), ctx :: map()) ::
          {:ok, %{run_id: binary(), session_key: binary()}}
          | {:error, %{code: binary(), message: binary(), details: term()}}
  def handle_control_agent(params, ctx) do
    session_key = control_param(params, :session_key)
    agent_id = control_param(params, :agent_id) || "default"
    session_key = session_key || SessionKey.main(agent_id)

    request =
      RunRequest.new(%{
        origin: :control_plane,
        session_key: session_key,
        agent_id: agent_id,
        prompt: control_param(params, :prompt),
        queue_mode: control_param(params, :queue_mode),
        model: control_param(params, :model),
        cwd: control_param(params, :cwd),
        tool_policy: control_param(params, :tool_policy),
        meta:
          Map.merge(normalize_meta(control_param(params, :meta)), %{
            control_plane_ctx: ctx
          })
      })

    case run_orchestrator().submit(request) do
      {:ok, run_id} ->
        {:ok, %{run_id: run_id, session_key: session_key}}

      {:error, reason} ->
        {:error, %{code: "SUBMIT_FAILED", message: "Failed to submit run", details: reason}}
    end
  end

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

  defp build_inbound_run_request(msg, meta, session_key, agent_id) do
    RunRequest.new(%{
      origin: :channel,
      session_key: session_key,
      agent_id: agent_id,
      prompt: msg.message.text,
      queue_mode: meta[:queue_mode] || meta["queue_mode"],
      resume: normalize_resume_token(meta[:resume] || meta["resume"]),
      meta:
        Map.merge(Map.delete(meta, "channel_identity"), %{
          channel_id: msg.channel_id,
          account_id: msg.account_id,
          peer: msg.peer,
          sender: msg.sender,
          channel_identity: inbound_channel_identity(msg),
          raw: msg.raw,
          # Read by LemonRouter.Policy so per-channel and group-chat tool
          # restrictions apply to real channel ingress. Always derived from
          # the transport-normalized message, never from caller meta.
          channel_context: %{
            channel_id: msg.channel_id,
            account_id: msg.account_id,
            peer_kind: msg.peer.kind,
            peer_id: msg.peer.id,
            thread_id: msg.peer.thread_id
          }
        })
    })
  end

  defp inbound_channel_identity(%{channel_id: channel, sender: %{id: sender} = identity})
       when is_binary(channel) and is_binary(sender) and sender != "" do
    %{
      channel_id: channel,
      sender_id: sender,
      is_bot: Map.get(identity, :bot, false) == true,
      owner?: Map.get(identity, :owner?, false) == true
    }
  end

  defp inbound_channel_identity(_), do: nil

  defp control_param(params, key) when is_map(params) and is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp normalize_resume_token(%LemonCore.ResumeToken{} = resume), do: resume

  defp normalize_resume_token(%{engine: engine, value: value})
       when is_binary(engine) and is_binary(value) do
    %LemonCore.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(%{"engine" => engine, "value" => value})
       when is_binary(engine) and is_binary(value) do
    %LemonCore.ResumeToken{engine: engine, value: value}
  end

  defp normalize_resume_token(_), do: nil

  defp run_orchestrator do
    Application.get_env(:lemon_router, :run_orchestrator, RunOrchestrator)
  end

  defp session_coordinator do
    Application.get_env(:lemon_router, :session_coordinator, LemonRouter.SessionCoordinator)
  end
end
