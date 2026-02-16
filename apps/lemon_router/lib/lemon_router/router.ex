defmodule LemonRouter.Router do
  @moduledoc """
  Main router for handling inbound messages and control plane requests.

  The router is responsible for:
  - Normalizing inbound messages from different channels
  - Routing to the appropriate session
  - Handling abort requests
  """

  alias LemonCore.RunRequest
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

    meta = normalize_meta(msg.meta)
    session_key = resolve_session_key(msg)

    agent_id =
      meta[:agent_id] || meta["agent_id"] || SessionKey.agent_id(session_key) || "default"

    request = build_inbound_run_request(msg, meta, session_key, agent_id)

    # Submit to orchestrator
    case run_orchestrator().submit(request) do
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
    meta = normalize_meta(msg.meta)

    LemonCore.Telemetry.channel_inbound(msg.channel_id, %{
      account_id: msg.account_id,
      peer_kind: msg.peer.kind,
      agent_id: meta[:agent_id] || meta["agent_id"] || "default"
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
        engine_id: control_param(params, :engine_id),
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

  defp build_inbound_run_request(msg, meta, session_key, agent_id) do
    RunRequest.new(%{
      origin: :channel,
      session_key: session_key,
      agent_id: agent_id,
      prompt: msg.message.text,
      queue_mode: meta[:queue_mode] || meta["queue_mode"],
      engine_id: meta[:engine_id] || meta["engine_id"],
      meta:
        Map.merge(meta, %{
          channel_id: msg.channel_id,
          account_id: msg.account_id,
          peer: msg.peer,
          sender: msg.sender,
          raw: msg.raw
        })
    })
  end

  defp control_param(params, key) when is_map(params) and is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp run_orchestrator do
    Application.get_env(:lemon_router, :run_orchestrator, RunOrchestrator)
  end
end
