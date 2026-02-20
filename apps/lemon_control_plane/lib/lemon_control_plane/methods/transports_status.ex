defmodule LemonControlPlane.Methods.TransportsStatus do
  @moduledoc """
  Handler for the `transports.status` method.

  Returns configured gateway transports and enabled/disabled state.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "transports.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    registry_running? = transport_registry_running?()
    configured = configured_transports(registry_running?)
    enabled_ids = enabled_transport_ids(registry_running?)

    transports =
      configured
      |> Enum.map(fn {id, mod} ->
        enabled? = MapSet.member?(enabled_ids, id)

        %{
          "transportId" => id,
          "module" => module_name(mod),
          "enabled" => enabled?,
          "status" => if(enabled?, do: "enabled", else: "disabled")
        }
      end)
      |> Enum.sort_by(& &1["transportId"])

    enabled_count = Enum.count(transports, &(&1["enabled"] == true))

    {:ok,
     %{
       "registryRunning" => registry_running?,
       "transports" => transports,
       "total" => length(transports),
       "enabled" => enabled_count
     }}
  end

  defp transport_registry_running? do
    Code.ensure_loaded?(LemonGateway.TransportRegistry) and
      is_pid(Process.whereis(LemonGateway.TransportRegistry))
  end

  defp configured_transports(false), do: []

  defp configured_transports(true) do
    LemonGateway.TransportRegistry.list_transports()
    |> Enum.map(fn id -> {id, safe_get_transport(id)} end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp enabled_transport_ids(false), do: MapSet.new()

  defp enabled_transport_ids(true) do
    LemonGateway.TransportRegistry.enabled_transports()
    |> Enum.map(fn {id, _mod} -> id end)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp safe_get_transport(id) do
    LemonGateway.TransportRegistry.get_transport(id)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp module_name(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp module_name(_), do: nil
end
