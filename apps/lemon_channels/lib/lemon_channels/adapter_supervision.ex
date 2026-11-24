defmodule LemonChannels.AdapterSupervision do
  @moduledoc """
  Owns `LemonChannels.AdapterSupervisor` and the configured-adapter starter.

  The strategy is `:rest_for_one`: whenever the `AdapterSupervisor` restarts,
  the starter restarts after it and starts every adapter from
  `config :lemon_channels, :adapters` again, so a restart never leaves the
  supervisor empty. Each adapter runs behind a `LemonChannels.AdapterKeeper`,
  which absorbs that adapter's crash loop with backoff.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: LemonChannels.AdapterSupervisor},
      LemonChannels.AdapterSupervision.Starter
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defmodule Starter do
    @moduledoc false
    # Starts the configured adapters each time it (re)starts. It holds no
    # state; restarting it is how configured adapters come back.
    use GenServer

    require Logger

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      Application.get_env(:lemon_channels, :adapters, [])
      |> Enum.each(&start_configured/1)

      {:ok, :started}
    end

    defp start_configured({adapter_module, opts})
         when is_atom(adapter_module) and is_list(opts) do
      log_start(
        adapter_module,
        LemonChannels.Application.register_and_start_adapter(adapter_module, opts)
      )
    end

    defp start_configured(adapter_module) when is_atom(adapter_module) do
      log_start(
        adapter_module,
        LemonChannels.Application.register_and_start_adapter(adapter_module)
      )
    end

    defp start_configured(_other) do
      Logger.warning("Ignoring invalid lemon_channels adapter config entry")
    end

    defp log_start(adapter_module, :ok),
      do: Logger.info("#{inspect(adapter_module)} adapter registered and started")

    defp log_start(adapter_module, {:error, reason}),
      do: Logger.warning("Failed to start #{inspect(adapter_module)} adapter: #{inspect(reason)}")
  end
end
