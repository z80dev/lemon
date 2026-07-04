defmodule LemonSim.Bench.Suite.RunAdapter.Adapters.VendingBench do
  @moduledoc false

  @behaviour LemonSim.Bench.Suite.RunAdapter

  alias LemonSim.Examples.VendingBench

  @impl true
  def supported_modes, do: [:offline, :live]

  @impl true
  def supported_presets, do: ["ci", "paper", "v2"]

  @impl true
  def preset_opts("ci"), do: [max_days: 7, driver_max_turns: 25, persist?: false]
  def preset_opts("paper"), do: [max_days: 365, driver_max_turns: 2_000]
  def preset_opts("v2"), do: [max_days: 365, driver_max_turns: 4_000]

  @impl true
  def run(:offline, strategy, _seed, opts) do
    strategy
    |> VendingBench.run_offline_strategy(opts)
    |> normalize_result(opts)
  end

  def run(:live, _model_id, _seed, opts) do
    opts
    |> VendingBench.run()
    |> normalize_result(opts)
  end

  defp normalize_result({:ok, _result}, opts), do: {:ok, Keyword.fetch!(opts, :artifact_dir)}
  defp normalize_result({:error, reason}, _opts), do: {:error, reason}
end
