defmodule LemonCore.EventBridge do
  @moduledoc """
  Optional bridge for subscribing/unsubscribing external event fanout.

  `:lemon_router` wants to request "subscribe this run_id" for WebSocket/event
  delivery, but should not depend on `:lemon_control_plane` at compile time.

  This module performs dynamic dispatch to a configured implementation module.
  If no implementation is configured, calls are no-ops.
  """

  @impl_key :event_bridge_impl
  @type configure_mode :: :replace | :if_unset

  @doc """
  Configure the implementation module.

  Typically called by `LemonControlPlane.Application` at startup:

      LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)
  """
  @spec configure(module() | nil) :: :ok | {:error, term()}
  def configure(nil) do
    configure(nil, mode: :replace)
  end

  def configure(mod) when is_atom(mod) do
    configure(mod, mode: :replace)
  end

  @doc """
  Configure the implementation module with overwrite controls.

  Modes:
  - `:replace` - overwrite any existing implementation (legacy behavior)
  - `:if_unset` - set only when unset or already matching
  """
  @spec configure(module() | nil, keyword()) :: :ok | {:error, term()}
  def configure(nil, opts) when is_list(opts) do
    LemonCore.RuntimeSeam.configure_provider(@impl_key, nil, Keyword.get(opts, :mode, :replace))
  end

  def configure(mod, opts) when is_atom(mod) and is_list(opts) do
    LemonCore.RuntimeSeam.configure_provider(@impl_key, mod, Keyword.get(opts, :mode, :replace))
  end

  @doc """
  Configure the bridge implementation only if no conflicting implementation is set.
  """
  @spec configure_guarded(module()) :: :ok | {:error, term()}
  def configure_guarded(mod) when is_atom(mod) do
    configure(mod, mode: :if_unset)
  end

  @doc """
  Subscribe to events for the given run ID.

  Dispatches to the configured implementation module. No-op if unconfigured.
  """
  @spec subscribe_run(binary()) :: :ok
  def subscribe_run(run_id) when is_binary(run_id) do
    dispatch(:subscribe_run, [run_id])
  end

  @doc """
  Unsubscribe from events for the given run ID.

  Dispatches to the configured implementation module. No-op if unconfigured.
  """
  @spec unsubscribe_run(binary()) :: :ok
  def unsubscribe_run(run_id) when is_binary(run_id) do
    dispatch(:unsubscribe_run, [run_id])
  end

  defp dispatch(fun, args) do
    _ = LemonCore.RuntimeSeam.invoke(current_impl(), fun, args, unavailable: :ok)
    :ok
  end

  defp current_impl, do: LemonCore.RuntimeSeam.provider(@impl_key)
end
