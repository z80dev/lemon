defmodule LemonGateway.TransportSupervisor do
  @moduledoc """
  Supervisor that starts all enabled transport modules registered in `TransportRegistry`.
  """
  use Supervisor

  alias LemonGateway.TransportRegistry

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    # Get enabled transports from registry
    enabled = TransportRegistry.enabled_transports()

    # Build children list - each transport gets a single child spec
    children =
      enabled
      |> Enum.flat_map(fn {_id, mod} -> [{mod, []}] end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
