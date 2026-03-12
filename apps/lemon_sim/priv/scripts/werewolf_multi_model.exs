# Werewolf 8-player multi-model game
# Mixed Gemini CLI, Codex, and Kimi seats with independent role shuffling

alias LemonSim.GameHelpers.Config, as: SimConfig

config = LemonCore.Config.Modular.load(project_dir: File.cwd!())

model_specs = [
  {:google_gemini_cli, "gemini-3-flash-preview"},
  {:google_gemini_cli, "gemini-3-pro-preview"},
  {:google_gemini_cli, "gemini-2.5-flash"},
  {:google_gemini_cli, "gemini-2.5-pro"},
  {:"openai-codex", "gpt-5.1-codex-mini"},
  {:"openai-codex", "gpt-5.3-codex-spark"},
  {:"openai-codex", "gpt-5.3-codex"},
  {:kimi, "k2p5"}
]

resolve_model! = fn provider, model_id ->
  case Ai.Models.get_model(provider, model_id) do
    %Ai.Types.Model{} = model ->
      SimConfig.apply_provider_base_url(model, config)

    nil ->
      raise "Could not resolve model #{provider}/#{model_id}"
  end
end

resolve_assignment = fn {provider, model_id} ->
  model = resolve_model!.(provider, model_id)
  api_key = SimConfig.resolve_provider_api_key!(provider, config, "werewolf")
  {model, api_key}
end

resolved_assignments = Enum.map(model_specs, resolve_assignment)

IO.puts("Models resolved:")

Enum.each(resolved_assignments, fn {model, _api_key} ->
  IO.puts("  #{model.provider}/#{model.id}")
end)

player_ids = Enum.map(1..8, &"player_#{&1}")

model_assignments =
  player_ids
  |> Enum.zip(Enum.shuffle(resolved_assignments))
  |> Map.new()

timestamp = System.system_time(:second)
transcript_path = "apps/lemon_sim/priv/game_logs/werewolf_multi_#{timestamp}.jsonl"

IO.puts("\nLaunching 8-player Werewolf (Gemini CLI + Codex + Kimi)")
IO.puts("Model seats are shuffled each run. Roles are shuffled independently.")
IO.puts("Transcript: #{transcript_path}\n")

case LemonSim.Examples.Werewolf.run_multi_model(
       player_count: 8,
       model_assignments: model_assignments,
       transcript_path: transcript_path,
       persist?: false,
       driver_max_turns: 200
     ) do
  {:ok, state} ->
    IO.puts("\nDONE: winner=#{inspect(state.world[:winner] || state.world["winner"])}")

  {:error, reason} ->
    IO.puts("\nERROR: #{inspect(reason)}")
end
