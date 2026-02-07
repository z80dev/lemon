defmodule LemonCore.EventBridge do
  @moduledoc """
  Optional bridge for subscribing/unsubscribing external event fanout.

  `:lemon_router` wants to request "subscribe this run_id" for WebSocket/event
  delivery, but should not depend on `:lemon_control_plane` at compile time.

  This module performs dynamic dispatch to a configured implementation module.
  If no implementation is configured, calls are no-ops.
  """

  @impl_key :event_bridge_impl

  @doc """
  Configure the implementation module.

  Typically called by `LemonControlPlane.Application` at startup:

      LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)
  """
  @spec configure(module() | nil) :: :ok
  def configure(nil) do
    Application.delete_env(:lemon_core, @impl_key)
    :ok
  end

  def configure(mod) when is_atom(mod) do
    Application.put_env(:lemon_core, @impl_key, mod)
    :ok
  end

  @spec subscribe_run(binary()) :: :ok
  def subscribe_run(run_id) when is_binary(run_id) do
    dispatch(:subscribe_run, [run_id])
  end

  @spec unsubscribe_run(binary()) :: :ok
  def unsubscribe_run(run_id) when is_binary(run_id) do
    dispatch(:unsubscribe_run, [run_id])
  end

  defp dispatch(fun, args) do
    mod = Application.get_env(:lemon_core, @impl_key)

    if is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      _ = apply(mod, fun, args)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end
end

