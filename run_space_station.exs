config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

model = Ai.Models.get_model(:kimi, "k2p5")
model = LemonSim.GameHelpers.Config.apply_provider_base_url(model, config)
api_key = LemonSim.GameHelpers.Config.resolve_provider_api_key!(model.provider, config, "space_station")

IO.puts("\n=== Space Station Crisis ===")
IO.puts("Model: #{model.provider}/#{model.id}")
IO.puts("Players: 6 crew members (1 saboteur), all Kimi K2.5\n")

model_assignments = %{"_default" => {model, api_key}}

LemonSim.Examples.SpaceStation.run_multi_model(
  player_count: 6,
  model_assignments: model_assignments
)
