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
    mode = Keyword.get(opts, :mode, :replace)

    case mode do
      :replace ->
        Application.delete_env(:lemon_core, @impl_key)
        :ok

      :if_unset ->
        case current_impl() do
          nil ->
            Application.delete_env(:lemon_core, @impl_key)
            :ok

          _ ->
            {:error, :already_configured}
        end

      other ->
        {:error, {:invalid_mode, other}}
    end
  end

  def configure(mod, opts) when is_atom(mod) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :replace)

    case mode do
      :replace ->
        Application.put_env(:lemon_core, @impl_key, %{impl: mod})
        :ok

      :if_unset ->
        case current_impl() do
          nil ->
            Application.put_env(:lemon_core, @impl_key, %{impl: mod})
            :ok

          ^mod ->
            :ok

          existing ->
            {:error, {:already_configured, existing}}
        end

      other ->
        {:error, {:invalid_mode, other}}
    end
  end

  @doc """
  Configure the bridge implementation only if no conflicting implementation is set.
  """
  @spec configure_guarded(module()) :: :ok | {:error, term()}
  def configure_guarded(mod) when is_atom(mod) do
    configure(mod, mode: :if_unset)
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
    mod = current_impl()

    if is_atom(mod) and Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      _ = apply(mod, fun, args)
      :ok
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp current_impl do
    case Application.get_env(:lemon_core, @impl_key) do
      %{impl: mod} when is_atom(mod) -> mod
      mod when is_atom(mod) -> mod
      _ -> nil
    end
  end
end
