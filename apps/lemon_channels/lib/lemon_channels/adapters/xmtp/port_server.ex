defmodule LemonChannels.Adapters.Xmtp.PortServer do
  @moduledoc false

  alias LemonChannels.PortBridge

  @bridge_spec %{
    label: "xmtp",
    event_tag: :xmtp_bridge_event,
    script_filename: "xmtp_bridge.mjs",
    adapter_dir: __DIR__
  }

  @type state :: %{
          port: port() | nil,
          buffer: String.t(),
          notify_pid: pid() | nil,
          unavailable_reason: term() | nil,
          script_path: String.t(),
          connect_command: map() | nil
        }

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    PortBridge.start_link(@bridge_spec, opts)
  end

  @spec command(pid(), map()) :: :ok
  def command(server, command) when is_pid(server) and is_map(command) do
    PortBridge.command(server, command)
  end

  @doc false
  def init(opts), do: PortBridge.init({@bridge_spec, opts})

  @doc false
  def handle_cast(message, state), do: PortBridge.handle_cast(message, state)

  @doc false
  def handle_info(message, state), do: PortBridge.handle_info(message, state)
end
