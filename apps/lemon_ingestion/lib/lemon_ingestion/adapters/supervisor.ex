defmodule LemonIngestion.Adapters.Supervisor do
  @moduledoc """
  Supervisor for all ingestion adapters.

  Manages the lifecycle of pollers and streamers for each data source.
  Each adapter runs as a child process under this supervisor.
  """

  use Supervisor

  @doc """
  Start the adapter supervisor.
  """
  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    children = adapter_children()

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp adapter_children do
    [
      # Polymarket adapter (polls for large trades, market changes)
      LemonIngestion.Adapters.Polymarket,

      # Future adapters (disabled by default):
      # LemonIngestion.Adapters.Twitter,
      # LemonIngestion.Adapters.PriceFeed,
      # LemonIngestion.Adapters.News
    ]
    |> Enum.filter(&adapter_enabled?/1)
  end

  defp adapter_enabled?(mod) do
    Application.get_env(:lemon_ingestion, :adapters, [])
    |> Keyword.get(mod |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom(), true)
  end

  @doc """
  Get status of all adapters.
  """
  @spec status() :: map()
  def status do
    children = Supervisor.which_children(__MODULE__)

    Map.new(children, fn {mod, pid, _type, _modules} ->
      state = if Process.alive?(pid), do: :running, else: :down
      {mod, %{pid: pid, state: state}}
    end)
  end
end
