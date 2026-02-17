defmodule LemonChannels.Runtime do
  @moduledoc false

  @router_mod :"Elixir.LemonRouter.Router"
  @session_registry :"Elixir.LemonRouter.SessionRegistry"

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

  @spec session_busy?(binary()) :: boolean()
  def session_busy?(session_key) when is_binary(session_key) and session_key != "" do
    with true <- Code.ensure_loaded?(Registry),
         true <- is_pid(Process.whereis(@session_registry)),
         [{_pid, _meta} | _] <- Registry.lookup(@session_registry, session_key) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def session_busy?(_), do: false
end
