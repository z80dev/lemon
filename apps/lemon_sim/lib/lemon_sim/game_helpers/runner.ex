defmodule LemonSim.GameHelpers.Runner do
  @moduledoc false

  defdelegate build_default_opts(projector_opts, overrides, game_opts),
    to: LemonSim.LLM.GameHelpers.Runner

  defdelegate run(state, modules, default_opts_fn, opts, callbacks),
    to: LemonSim.LLM.GameHelpers.Runner

  defdelegate run_multi_model(state, modules, default_opts_fn, opts, callbacks),
    to: LemonSim.LLM.GameHelpers.Runner

  defdelegate print_model_assignments(model_assignments), to: LemonSim.LLM.GameHelpers.Runner
end
