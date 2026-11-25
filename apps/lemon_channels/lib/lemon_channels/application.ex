defmodule LemonChannels.Application do
  @moduledoc """
  OTP application and adapter lifecycle for `LemonChannels`.

  Starts the plugin registry, outbox and dispatcher, then any adapters declared
  in config. Adapters can also be started, restarted and stopped at runtime with
  `register_and_start_adapter/2`, `start_adapter/2` and `stop_adapter/1` — the
  entrypoints a `LemonChannels.Plugin` author uses to bring an adapter online.
  """

  use Application

  alias LemonChannels.Telegram.KnownTargetStore

  @doc false
  @impl true
  def start(_type, _args) do
    children = [
      # Plugin registry
      LemonChannels.Registry,
      # Channels-owned delivery presentation state (message ids / send-vs-edit)
      LemonChannels.PresentationState,
      LemonCore.TaskSupervisor.child_spec(name: LemonChannels.VoiceReplyTaskSupervisor),
      LemonChannels.VoiceReplyDelivery,
      # Best-effort chat-originated run activity
      LemonChannels.TypingIndicator,
      # Rate limiter
      {LemonCore.RateLimiter, name: LemonChannels.Outbox.RateLimiter},
      # Dedupe
      LemonChannels.Outbox.Dedupe,
      # Outbox worker supervisor (tasks)
      LemonCore.TaskSupervisor.child_spec(LemonChannels.Outbox.worker_supervisor_options()),
      # Outbox
      LemonChannels.Outbox,
      # Durable supervision notices use Outbox admission and delivery receipts
      LemonChannels.Supervision,
      LemonChannels.UserPromptSurface,
      LemonChannels.ApprovalPromptTracker,
      LemonChannels.Pairing,
      # Optional inbound HTTP listener; binds a port only when configured
      LemonChannels.InboundHttp,
      # AdapterSupervisor plus the starter that (re)starts configured adapters
      # whenever the AdapterSupervisor restarts. Last: adapters start once the
      # rest of the channels runtime is up.
      LemonChannels.AdapterSupervision
    ]

    opts = [strategy: :one_for_one, name: LemonChannels.Supervisor]

    # Channels own their store tables: the store does not know Telegram
    # exists, so we ask it to mirror our hot index into its read cache.
    LemonCore.Store.register_cached_table(KnownTargetStore.table())

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # After the router (50): the outbox flush must follow run suspension.
        :ok = LemonCore.Drain.register(:channels, LemonChannels.Drain, order: 90)
        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Register and start a channel adapter.

  This function:
  1. Registers the adapter plugin with the Registry
  2. Starts the adapter's child_spec under the AdapterSupervisor
  """
  @spec register_and_start_adapter(module(), keyword()) :: :ok | {:error, term()}
  def register_and_start_adapter(adapter_module, opts \\ []) do
    # Register the plugin
    case LemonChannels.Registry.register(adapter_module) do
      :ok ->
        start_adapter(adapter_module, opts)

      {:error, :already_registered} ->
        # Already registered, just try to start
        start_adapter(adapter_module, opts)

      error ->
        error
    end
  end

  @doc """
  Start an adapter under the AdapterSupervisor.

  The adapter runs behind a `LemonChannels.AdapterKeeper`, which restarts it
  with backoff so its crash loop cannot exhaust the shared supervisor.
  """
  @spec start_adapter(module(), keyword()) :: :ok | {:error, term()}
  def start_adapter(adapter_module, opts \\ []) do
    adapter_spec = Supervisor.child_spec(adapter_module.child_spec(opts), [])

    if adapter_module.id() in ["telegram", "xmtp"] do
      LemonChannels.Registry.record_status(adapter_module.id(), :configured)
    end

    backoff = Application.get_env(:lemon_channels, :adapter_restart_backoff, [])
    keeper_spec = LemonChannels.AdapterKeeper.child_spec({adapter_module, adapter_spec, backoff})

    case DynamicSupervisor.start_child(LemonChannels.AdapterSupervisor, keeper_spec) do
      {:ok, _pid} ->
        :ok

      {:ok, _pid, _info} ->
        :ok

      :ignore ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        LemonChannels.Registry.record_status(adapter_module.id(), {:error, reason})
        {:error, reason}
    end
  end

  @doc """
  Stop an adapter.
  """
  @spec stop_adapter(module()) :: :ok | {:error, term()}
  def stop_adapter(adapter_module) do
    case find_adapter_pid(adapter_module) do
      nil ->
        {:error, :not_running}

      pid ->
        DynamicSupervisor.terminate_child(LemonChannels.AdapterSupervisor, pid)
    end
  end

  defp find_adapter_pid(adapter_module) when is_atom(adapter_module) do
    expected_child_module =
      case adapter_module.child_spec([]) do
        %{start: {module, _func, _args}} when is_atom(module) -> module
        _ -> nil
      end

    # Search for the adapter in the supervisor children
    children = DynamicSupervisor.which_children(LemonChannels.AdapterSupervisor)

    Enum.find_value(children, fn
      {_id, pid, _type, modules} when is_pid(pid) and is_list(modules) ->
        if Enum.member?(modules, adapter_module) or
             (not is_nil(expected_child_module) and Enum.member?(modules, expected_child_module)) do
          pid
        else
          nil
        end

      _ ->
        nil
    end)
  end
end
