defmodule LemonSim.Bench.Suite.RunAdapter.Adapters.TcgShop do
  @moduledoc false

  @behaviour LemonSim.Bench.Suite.RunAdapter

  alias LemonSim.Examples.TcgShop
  alias LemonSim.Examples.TcgShop.Artifacts

  @impl true
  def supported_modes, do: [:offline, :live]

  @impl true
  def supported_presets, do: ["ci", "paper", "stress"]

  @impl true
  def preset_opts("ci"), do: [max_days: 5, driver_max_turns: 20, persist?: false]
  def preset_opts("paper"), do: [max_days: 90, driver_max_turns: 200]
  def preset_opts("stress"), do: [max_days: 14, driver_max_turns: 80, persist?: false]

  @impl true
  def run(:offline, strategy, _seed, opts) do
    strategy
    |> TcgShop.run_offline_strategy(opts)
    |> normalize_result(opts)
  end

  def run(:live, _model_id, _seed, opts) do
    with {:ok, state} <- TcgShop.run(opts),
         {:ok, _paths} <- Artifacts.write_run_artifacts(state, [], [], opts) do
      {:ok, Keyword.fetch!(opts, :artifact_dir)}
    end
  end

  defp normalize_result({:ok, _result}, opts), do: {:ok, Keyword.fetch!(opts, :artifact_dir)}
  defp normalize_result({:error, reason}, _opts), do: {:error, reason}
end
