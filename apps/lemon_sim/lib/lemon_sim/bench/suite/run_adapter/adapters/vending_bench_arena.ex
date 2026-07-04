defmodule LemonSim.Bench.Suite.RunAdapter.Adapters.VendingBenchArena do
  @moduledoc false

  @behaviour LemonSim.Bench.Suite.RunAdapter

  alias LemonSim.Examples.VendingBench

  @impl true
  def supported_modes, do: [:offline]

  @impl true
  def supported_presets, do: ["ci"]

  @impl true
  def preset_opts("ci"), do: [max_days: 7, driver_max_turns: 25, persist?: false]

  @impl true
  def run(:offline, strategy, _seed, opts) do
    strategy
    |> VendingBench.Arena.run_offline_strategy(opts)
    |> normalize_result(opts)
  end

  def run(mode, _competitor, _seed, _opts), do: {:error, {:unsupported_suite_mode, mode}}

  defp normalize_result({:ok, _result}, opts), do: {:ok, Keyword.fetch!(opts, :artifact_dir)}
  defp normalize_result({:error, reason}, _opts), do: {:error, reason}
end
