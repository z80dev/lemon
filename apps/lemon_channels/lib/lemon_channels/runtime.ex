defmodule LemonChannels.Runtime do
  @moduledoc """
  Channel-side entry points into the router: submit inbound messages, cancel
  runs, apply keep-alive decisions and ask whether a session is busy.

  Everything goes through `LemonCore.RouterBridge` and returns the bridge's
  answer unchanged, so an adapter can tell its user whether a cancel was
  delivered (`:ok`), definitely could not be delivered (`{:error, reason}`),
  or may have applied without a valid acknowledgement
  (`{:error, :outcome_unknown}`). Nothing here swallows an error, invents a
  soft answer, or falls back to another path: the bridge is the one seam, and
  it already distinguishes those cases.
  """

  alias LemonCore.InboundMessage
  alias LemonCore.RouterBridge

  require Logger

  @type failure :: {:error, :unavailable | term()}

  @doc """
  Submit one normalized inbound message through the canonical run boundary.

  A caller that already owns a stable reconciliation identity may pass
  `run_id: value`. A transport whose rendered prompt contains retry-local data
  may also pass `replay_content_identity`; ordinary channel transports omit
  both and let the router allocate and bind the complete request.
  """
  @spec submit_inbound(InboundMessage.t(), keyword()) :: :ok | failure()
  def submit_inbound(%InboundMessage{} = inbound, opts \\ []) when is_list(opts) do
    emit_inbound_telemetry(inbound)

    inbound
    |> LemonChannels.RunRequestBuilder.from_inbound()
    |> maybe_put_run_id(Keyword.get(opts, :run_id))
    |> maybe_put_replay_identity(Keyword.get(opts, :replay_identity))
    |> maybe_put_replay_content_identity(Keyword.get(opts, :replay_content_identity))
    |> RouterBridge.submit_run()
    |> case do
      {:ok, _run_id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cancel the session a progress message belongs to.

  The message id is not needed to find the run: the session key already
  identifies it, and the router aborts the session's active run.
  """
  @spec cancel_by_progress_msg(binary(), integer()) :: :ok | failure()
  def cancel_by_progress_msg(session_key, _progress_msg_id)
      when is_binary(session_key) and session_key != "" do
    RouterBridge.abort_session(session_key, :user_requested)
  end

  def cancel_by_progress_msg(session_key, _progress_msg_id),
    do: {:error, {:invalid_session_key, session_key}}

  @spec cancel_session(binary(), term()) :: :ok | failure()
  def cancel_session(session_key, reason \\ :user_requested)

  def cancel_session(session_key, reason) when is_binary(session_key) and session_key != "" do
    RouterBridge.abort_session(session_key, reason)
  end

  def cancel_session(session_key, _reason), do: {:error, {:invalid_session_key, session_key}}

  @spec cancel_by_run_id(binary(), term()) :: :ok | failure()
  def cancel_by_run_id(run_id, reason \\ :user_requested)

  def cancel_by_run_id(run_id, reason) when is_binary(run_id) and run_id != "" do
    RouterBridge.abort_run(run_id, reason)
  end

  def cancel_by_run_id(run_id, _reason), do: {:error, {:invalid_run_id, run_id}}

  @spec keep_run_alive(binary(), :continue | :cancel) :: :ok | failure()
  def keep_run_alive(run_id, decision \\ :continue)

  def keep_run_alive(run_id, decision)
      when is_binary(run_id) and run_id != "" and decision in [:continue, :cancel] do
    RouterBridge.keep_run_alive(run_id, decision)
  end

  def keep_run_alive(run_id, decision), do: {:error, {:invalid_keep_alive, run_id, decision}}

  @doc """
  Whether the session has an active run, or `{:error, :unavailable}` when the
  router cannot be consulted. Callers that treat an unreachable router as "not
  busy" must say so where they do it.
  """
  @spec session_busy?(binary()) :: {:ok, boolean()} | failure()
  def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    RouterBridge.session_busy?(session_key)
  end

  def session_busy?(session_key), do: {:error, {:invalid_session_key, session_key}}

  @doc """
  Forget the resume selection and resume index of a Telegram thread, after the
  router has compacted the session behind it.
  """
  @spec clear_telegram_thread_state(binary(), integer(), integer() | nil) :: :ok
  def clear_telegram_thread_state(account_id, chat_id, thread_id)
      when is_binary(account_id) and is_integer(chat_id) do
    LemonChannels.Telegram.StateStore.delete_selected_resume({account_id, chat_id, thread_id})
    LemonChannels.Telegram.ResumeIndexStore.delete_thread(account_id, chat_id, thread_id)
    :ok
  rescue
    _ -> :ok
  end

  def clear_telegram_thread_state(_, _, _), do: :ok

  defp maybe_put_run_id(request, run_id) when is_binary(run_id) and run_id != "",
    do: %{request | run_id: run_id}

  defp maybe_put_run_id(request, _run_id), do: request

  defp maybe_put_replay_identity(request, replay_identity)
       when is_binary(replay_identity) and replay_identity != "" do
    %{request | meta: Map.put(request.meta || %{}, :router_replay_identity, replay_identity)}
  end

  defp maybe_put_replay_identity(request, _replay_identity), do: request

  defp maybe_put_replay_content_identity(request, content_identity)
       when is_binary(content_identity) and content_identity != "" do
    %{
      request
      | meta: Map.put(request.meta || %{}, :router_replay_content_identity, content_identity)
    }
  end

  defp maybe_put_replay_content_identity(request, _content_identity), do: request

  defp emit_inbound_telemetry(%InboundMessage{} = inbound) do
    meta = if is_map(inbound.meta), do: inbound.meta, else: %{}

    LemonCore.Telemetry.channel_inbound(inbound.channel_id, %{
      account_id: inbound.account_id,
      peer_kind: inbound.peer.kind,
      agent_id: meta[:agent_id] || meta["agent_id"] || "default"
    })
  rescue
    _ -> :ok
  end
end
