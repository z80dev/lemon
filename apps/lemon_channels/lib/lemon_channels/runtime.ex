defmodule LemonChannels.Runtime do
  @moduledoc false

  alias LemonCore.InboundMessage

  @router_mod :"Elixir.LemonRouter.Router"

  @spec submit_inbound(InboundMessage.t()) :: :ok | {:error, term()}
  def submit_inbound(%InboundMessage{} = inbound) do
    emit_inbound_telemetry(inbound)

    inbound
    |> LemonChannels.RunRequestBuilder.from_inbound()
    |> LemonCore.RouterBridge.submit_run()
    |> case do
      {:ok, _run_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cancel_by_progress_msg(binary(), integer()) :: :ok
  def cancel_by_progress_msg(session_key, _progress_msg_id)
      when is_binary(session_key) and session_key != "" do
    _ = LemonCore.RouterBridge.abort_session(session_key, :user_requested)
    :ok
  rescue
    _ -> :ok
  end

  def cancel_by_progress_msg(_, _), do: :ok

  @spec cancel_by_run_id(binary(), term()) :: :ok
  def cancel_by_run_id(run_id, reason \\ :user_requested)

  def cancel_by_run_id(run_id, reason) when is_binary(run_id) and run_id != "" do
    cond do
      function_exported?(LemonCore.RouterBridge, :abort_run, 2) ->
        _ = LemonCore.RouterBridge.abort_run(run_id, reason)
        :ok

      Code.ensure_loaded?(@router_mod) and function_exported?(@router_mod, :abort_run, 2) ->
        _ = apply(@router_mod, :abort_run, [run_id, reason])
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def cancel_by_run_id(_, _), do: :ok

  @spec keep_run_alive(binary(), :continue | :cancel) :: :ok
  def keep_run_alive(run_id, decision \\ :continue)

  def keep_run_alive(run_id, decision)
      when is_binary(run_id) and run_id != "" and decision in [:continue, :cancel] do
    cond do
      function_exported?(LemonCore.RouterBridge, :keep_run_alive, 2) ->
        _ = LemonCore.RouterBridge.keep_run_alive(run_id, decision)
        :ok

      Code.ensure_loaded?(@router_mod) and function_exported?(@router_mod, :keep_run_alive, 2) ->
        _ = apply(@router_mod, :keep_run_alive, [run_id, decision])
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def keep_run_alive(_, _), do: :ok

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

  @spec session_busy?(binary()) :: boolean()
  def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    LemonCore.RouterBridge.session_busy?(session_key)
  rescue
    _ -> false
  end

  def session_busy?(_), do: false

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
