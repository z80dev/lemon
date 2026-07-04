defmodule LemonSim.Bench.Suite.RunAdapter.Registry do
  @moduledoc false

  alias LemonSim.Bench.Suite.RunAdapter.Adapters.{TcgShop, VendingBench, VendingBenchArena}

  @adapters %{
    "tcg_shop" => TcgShop,
    "vending_bench" => VendingBench,
    "vending_bench_arena" => VendingBenchArena
  }

  def all, do: @adapters

  def fetch(scenario_id) when is_binary(scenario_id) do
    case Map.fetch(@adapters, scenario_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:no_suite_adapter, scenario_id}}
    end
  end

  def preset_opts(_scenario_id, nil), do: {:ok, []}

  def preset_opts(scenario_id, preset) when is_binary(scenario_id) and is_binary(preset) do
    with {:ok, adapter} <- fetch(scenario_id) do
      if preset in adapter.supported_presets() do
        {:ok, adapter.preset_opts(preset)}
      else
        {:error, {:unknown_suite_preset, scenario_id, preset}}
      end
    end
  end

  def supports_mode?(adapter, mode), do: mode in adapter.supported_modes()
end
