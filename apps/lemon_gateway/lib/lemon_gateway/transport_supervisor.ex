defmodule LemonGateway.TransportSupervisor do
  @moduledoc false
  use Supervisor

  alias LemonGateway.TransportRegistry

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Get enabled transports from registry
    enabled = TransportRegistry.enabled_transports()

    # Build children list - each transport may have supporting processes
    children =
      enabled
      |> Enum.flat_map(fn {id, mod} -> transport_children(id, mod) end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Telegram requires an Outbox process alongside the Transport
  defp transport_children("telegram", mod) do
    [
      {LemonGateway.Telegram.Outbox, []},
      {mod, []}
    ]
  end

  # Generic transports just need the module started
  defp transport_children(_id, mod) do
    [{mod, []}]
  end
end
