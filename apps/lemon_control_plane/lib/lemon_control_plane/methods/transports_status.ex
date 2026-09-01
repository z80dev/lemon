defmodule LemonControlPlane.Methods.TransportsStatus do
  @moduledoc """
  Handler for the `transports.status` method.

  Returns configured gateway transports and enabled/disabled state, read
  through the `:transport_registry` capability of `LemonCore.EngineInfoBridge`.
  The execution runtime registers its registry there at boot; without one, or
  with its process stopped, the snapshot is empty and `summary.status` says
  `registry_stopped`.
  """

  @behaviour LemonControlPlane.Method

  alias LemonCore.EngineInfoBridge

  @impl true
  def name, do: "transports.status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    registry_running? = EngineInfoBridge.running?(:transport_registry)
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
    disabled_count = length(transports) - enabled_count

    {:ok,
     %{
       "registryRunning" => registry_running?,
       "registryModule" => module_name(EngineInfoBridge.impl(:transport_registry)),
       "registryLoaded" => EngineInfoBridge.available?(:transport_registry),
       "transports" => transports,
       "total" => length(transports),
       "enabled" => enabled_count,
       "disabled" => disabled_count,
       "summary" => %{
         "status" => summary_status(registry_running?, transports),
         "configuredCount" => length(transports),
         "enabledCount" => enabled_count,
         "disabledCount" => disabled_count,
         "moduleLoadedCount" => Enum.count(transports, &is_binary(&1["module"])),
         "moduleMissingCount" => Enum.count(transports, &is_nil(&1["module"])),
         "cleanup" => %{
           "includesCredentialValues" => false,
           "includesRawConfig" => false,
           "includesSecretNames" => false
         }
       }
     }}
  end

  defp summary_status(false, _transports), do: "registry_stopped"
  defp summary_status(true, []), do: "empty"

  defp summary_status(true, transports) do
    if Enum.any?(transports, &(&1["enabled"] == true)), do: "enabled", else: "disabled"
  end

  defp configured_transports(false), do: []

  defp configured_transports(true) do
    case EngineInfoBridge.list_transports() do
      {:ok, ids} -> Enum.map(ids, fn id -> {id, transport_module(id)} end)
      {:error, :unavailable} -> []
    end
  end

  defp enabled_transport_ids(false), do: MapSet.new()

  defp enabled_transport_ids(true) do
    case EngineInfoBridge.enabled_transports() do
      {:ok, transports} -> MapSet.new(transports, fn {id, _mod} -> id end)
      {:error, :unavailable} -> MapSet.new()
    end
  end

  # A lookup the registry cannot answer (it raised, or stopped mid-call) is
  # logged by the bridge; here the transport is simply reported without a
  # module, which `summary.moduleMissingCount` counts.
  defp transport_module(id) do
    case EngineInfoBridge.get_transport(id) do
      {:ok, mod} -> mod
      {:error, :unavailable} -> nil
    end
  end

  defp module_name(nil), do: nil
  defp module_name(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp module_name(_), do: nil
end
