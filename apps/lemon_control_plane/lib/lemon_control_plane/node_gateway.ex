defmodule LemonControlPlane.NodeGateway do
  @moduledoc """
  Optional node-only listener. A disabled or occupied port does not prevent the
  local controller from starting. `status/0` exposes availability for enrollment.
  """
  use GenServer
  require Logger

  @status_key {__MODULE__, :status}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status do
    case :persistent_term.get(@status_key, nil) do
      %{pid: pid, port: port} when is_pid(pid) ->
        if Process.alive?(pid), do: %{available: true, port: port}, else: unavailable()

      _ ->
        unavailable()
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :persistent_term.put(@status_key, unavailable())
    port = Keyword.get(opts, :port, 4044)

    if port == 0 do
      Logger.warning("Node gateway disabled (LEMON_CONTROL_PLANE_NODE_PORT=0)")
      :ignore
    else
      case Bandit.start_link(
             plug: LemonControlPlane.HTTP.NodeRouter,
             ip: Keyword.get(opts, :ip, {127, 0, 0, 1}),
             port: port,
             scheme: :http
           ) do
        {:ok, pid} ->
          :persistent_term.put(@status_key, %{pid: pid, port: port})
          {:ok, pid}

        {:error, reason} ->
          if address_in_use?(reason) do
            Logger.warning("Node gateway unavailable: port #{port} is already in use")
            :ignore
          else
            {:stop, reason}
          end
      end
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, pid), do: {:stop, reason, pid}

  @impl true
  def terminate(_reason, pid) do
    :persistent_term.put(@status_key, unavailable())
    if Process.alive?(pid), do: Supervisor.stop(pid)
  end

  defp unavailable, do: %{available: false, port: nil}
  defp address_in_use?(:eaddrinuse), do: true

  defp address_in_use?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&address_in_use?/1)

  defp address_in_use?(reason) when is_list(reason), do: Enum.any?(reason, &address_in_use?/1)
  defp address_in_use?(_reason), do: false
end
