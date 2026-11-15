defmodule LemonControlPlane.NodeGateway do
  @moduledoc """
  Optional node-only listener. A disabled or occupied port does not prevent the
  local controller from starting. `status/0` exposes availability for enrollment.
  Availability is read directly from ETS owned by this supervised listener.
  """
  use GenServer
  require Logger

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def status do
    case :ets.lookup(@table, :status) do
      [{:status, %{pid: pid, port: port}}] when is_pid(pid) ->
        if Process.alive?(pid), do: %{available: true, port: port}, else: unavailable()

      _ ->
        unavailable()
    end
  rescue
    ArgumentError -> unavailable()
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
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
          :ets.insert(@table, {:status, %{pid: pid, port: port}})
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
    :ets.delete(@table, :status)
    if Process.alive?(pid), do: Supervisor.stop(pid)
  end

  defp unavailable, do: %{available: false, port: nil}
  defp address_in_use?(:eaddrinuse), do: true

  defp address_in_use?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&address_in_use?/1)

  defp address_in_use?(reason) when is_list(reason), do: Enum.any?(reason, &address_in_use?/1)
  defp address_in_use?(_reason), do: false
end
