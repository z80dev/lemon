config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

model = Ai.Models.get_model(:kimi, "k2p5")
model = LemonSim.GameHelpers.Config.apply_provider_base_url(model, config)
api_key = LemonSim.GameHelpers.Config.resolve_provider_api_key!(model.provider, config, "stock_market")

IO.puts("\n=== Stock Market Arena ===")
IO.puts("Model: #{model.provider}/#{model.id}")
IO.puts("Players: 4 traders, all Kimi K2.5\n")

# Use a single default entry — runner falls back to this for all players
model_assignments = %{"_default" => {model, api_key}}

LemonSim.Examples.StockMarket.run_multi_model(
  player_count: 4,
  model_assignments: model_assignments
)
