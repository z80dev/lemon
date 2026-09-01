defmodule LemonCore.EventBridge do
  @moduledoc """
  Optional bridge for subscribing external event fan-out to a run.

  `:lemon_router` asks for "subscribe this run_id" so WebSocket clients can
  follow the run, but must not depend on `:lemon_control_plane` at compile
  time. The control plane registers itself here at boot with `configure/1`;
  the module it registers must implement `LemonCore.EventBridge.Fanout`,
  which `configure/1` verifies with `LemonCore.Contract.validate/2`.

  With no fan-out configured, `subscribe_run/1` and `unsubscribe_run/1` are
  no-ops that answer `:ok`: a runtime without a control plane has nobody to
  fan out to, and that is a normal state, not a failure. A configured fan-out
  that raises or exits is a failure. It is logged with its reason and answered
  as `{:error, reason}`, never as `:ok`.
  """

  alias LemonCore.Contract

  require Logger

  @impl_key :event_bridge_impl
  @fanout LemonCore.EventBridge.Fanout

  @type configure_mode :: :replace | :if_unset

  @doc """
  Configure the fan-out module, replacing any existing one. `nil` clears it.

  Typically called by `LemonControlPlane.Application` at startup:

      LemonCore.EventBridge.configure(LemonControlPlane.EventBridge)
  """
  @spec configure(module() | nil) :: :ok | {:error, term()}
  def configure(mod) when is_atom(mod), do: configure(mod, mode: :replace)

  @doc """
  Configure the fan-out module with overwrite controls.

  Modes:
  - `:replace` - overwrite any existing implementation
  - `:if_unset` - set only when unset or already the same module

  A module that does not implement `LemonCore.EventBridge.Fanout` is rejected
  as `{:error, {:invalid_implementation, reason}}` and nothing changes.
  """
  @spec configure(module() | nil, keyword()) :: :ok | {:error, term()}
  def configure(nil, opts) when is_list(opts) do
    case Keyword.get(opts, :mode, :replace) do
      :replace ->
        clear()

      :if_unset ->
        case current_impl() do
          nil -> clear()
          _existing -> {:error, :already_configured}
        end

      other ->
        {:error, {:invalid_mode, other}}
    end
  end

  def configure(mod, opts) when is_atom(mod) and is_list(opts) do
    with :ok <- validate(mod) do
      case Keyword.get(opts, :mode, :replace) do
        :replace ->
          put(mod)

        :if_unset ->
          case current_impl() do
            nil -> put(mod)
            ^mod -> :ok
            existing -> {:error, {:already_configured, existing}}
          end

        other ->
          {:error, {:invalid_mode, other}}
      end
    end
  end

  @doc """
  Configure the fan-out module only if no conflicting one is set.
  """
  @spec configure_guarded(module()) :: :ok | {:error, term()}
  def configure_guarded(mod) when is_atom(mod), do: configure(mod, mode: :if_unset)

  @doc "The configured fan-out module, or `nil`."
  @spec impl() :: module() | nil
  def impl, do: current_impl()

  @doc """
  Subscribe external clients to the run's events. `:ok` when no fan-out is
  configured.
  """
  @spec subscribe_run(binary()) :: :ok | {:error, term()}
  def subscribe_run(run_id) when is_binary(run_id), do: dispatch(:subscribe_run, [run_id])

  @doc """
  Unsubscribe external clients from the run's events. `:ok` when no fan-out
  is configured.
  """
  @spec unsubscribe_run(binary()) :: :ok | {:error, term()}
  def unsubscribe_run(run_id) when is_binary(run_id), do: dispatch(:unsubscribe_run, [run_id])

  defp dispatch(function, args) do
    case current_impl() do
      nil ->
        :ok

      mod ->
        case apply(mod, function, args) do
          :ok -> :ok
          other -> {:error, {:unexpected_answer, other}}
        end
    end
  rescue
    exception ->
      Logger.error(
        "EventBridge #{function}/#{length(args)} raised: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, exception}
  catch
    :exit, reason ->
      Logger.warning("EventBridge #{function}/#{length(args)} unavailable: #{inspect(reason)}")
      {:error, :unavailable}
  end

  defp validate(mod) do
    case Contract.validate(mod, @fanout) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_implementation, reason}}
    end
  end

  defp put(mod) do
    Application.put_env(:lemon_core, @impl_key, %{impl: mod})
    :ok
  end

  defp clear do
    Application.delete_env(:lemon_core, @impl_key)
    :ok
  end

  defp current_impl do
    case Application.get_env(:lemon_core, @impl_key) do
      %{impl: mod} when is_atom(mod) and not is_nil(mod) -> mod
      _ -> nil
    end
  end
end
