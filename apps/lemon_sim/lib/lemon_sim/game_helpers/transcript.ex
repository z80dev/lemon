defmodule LemonSim.GameHelpers.Transcript do
  @moduledoc false

  defdelegate start(path, world, model_assignments, opts \\ []),
    to: LemonSim.LLM.GameHelpers.Transcript

  defdelegate log_step(log, turn, world, model_assignments),
    to: LemonSim.LLM.GameHelpers.Transcript

  defdelegate log_entry(log, entry), to: LemonSim.LLM.GameHelpers.Transcript
  def log_result(log, turn, world) do
    LemonSim.LLM.GameHelpers.Transcript.log_result(log, turn, world, fn _ -> %{} end)
  end

  defdelegate log_result(log, turn, world, detail_fn), to: LemonSim.LLM.GameHelpers.Transcript

  defdelegate log_game_over(log, world, model_assignments, opts \\ []),
    to: LemonSim.LLM.GameHelpers.Transcript

  defdelegate sanitize_for_json(value, max_depth \\ 5), to: LemonSim.LLM.GameHelpers.Transcript
end
