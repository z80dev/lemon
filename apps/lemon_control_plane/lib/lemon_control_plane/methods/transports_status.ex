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
    registry = transport_registry_module()

    Code.ensure_loaded?(registry) and is_pid(Process.whereis(registry))
  end

  defp configured_transports(false), do: []

  defp configured_transports(true) do
    case registry_call(:list_transports, []) do
      {:ok, ids} when is_list(ids) ->
        Enum.map(ids, fn id -> {id, safe_get_transport(id)} end)

      _ ->
        []
    end
  end

  defp enabled_transport_ids(false), do: MapSet.new()

  defp enabled_transport_ids(true) do
    case registry_call(:enabled_transports, []) do
      {:ok, transports} when is_list(transports) ->
        transports
        |> Enum.map(fn {id, _mod} -> id end)
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  defp safe_get_transport(id) do
    case registry_call(:get_transport, [id]) do
      {:ok, mod} -> mod
      _ -> nil
    end
  end

  defp module_name(nil), do: nil
  defp module_name(mod) when is_atom(mod), do: Atom.to_string(mod)
  defp module_name(_), do: nil

  defp registry_call(function, args) when is_atom(function) and is_list(args) do
    registry = transport_registry_module()
    arity = length(args)

    cond do
      not Code.ensure_loaded?(registry) ->
        {:error, :module_not_loaded}

      not function_exported?(registry, function, arity) ->
        {:error, {:missing_function, function, arity}}

      true ->
        {:ok, apply(registry, function, args)}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp transport_registry_module do
    Application.get_env(
      :lemon_control_plane,
      :transport_registry_module,
      :"Elixir.LemonGateway.TransportRegistry"
    )
  end
end
