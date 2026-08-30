defmodule LemonChannels.Adapters.WhatsApp.PortServer do
  @moduledoc false

  @behaviour GenServer

  alias LemonChannels.PortBridge

  require Logger

  @bridge_spec %{
    label: "whatsapp",
    event_tag: :whatsapp_bridge_event,
    script_filename: "whatsapp_bridge.mjs",
    adapter_dir: __DIR__,
    log_module: __MODULE__
  }

  @type state :: %{
          port: port() | nil,
          buffer: String.t(),
          notify_pid: pid() | nil,
          unavailable_reason: term() | nil,
          script_path: String.t(),
          connect_command: map() | nil,
          bridge: PortBridge.bridge_spec()
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec command(pid(), map()) :: :ok
  def command(server, command) when is_pid(server) and is_map(command) do
    PortBridge.command(server, command)
  end

  @doc false
  @impl true
  def init(opts), do: PortBridge.init({@bridge_spec, opts})

  @doc false
  @impl true
  def handle_cast(message, state), do: PortBridge.handle_cast(message, state)

  @doc false
  @impl true
  def handle_info(message, state), do: PortBridge.handle_info(message, state)

  @doc false
  def log_warning(message) when is_binary(message), do: Logger.warning(message)
end
