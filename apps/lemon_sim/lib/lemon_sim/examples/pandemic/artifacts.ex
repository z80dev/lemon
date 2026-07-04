defmodule LemonSim.Examples.Pandemic.Artifacts do
  @moduledoc false

  alias LemonSim.Bench.Artifacts.Bundle

  @default_artifact_root "apps/lemon_sim/priv/game_logs/pandemic"
  @sim_version "1.0.0"

  def write_run_artifacts(state, events, actions, opts) do
    artifact_dir =
      Keyword.get(opts, :artifact_dir) || Path.join(@default_artifact_root, state.sim_id)

    Bundle.write_scorecard_bundle(
      state,
      events,
      actions,
      Keyword.merge(opts,
        artifact_dir: artifact_dir,
        scenario_id: "pandemic",
        version: @sim_version,
        ruleset_hash: ruleset_hash()
      )
    )
  end

  defp ruleset_hash do
    [
      "apps/lemon_sim/lib/lemon_sim/examples/pandemic.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/pandemic/action_space.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/pandemic/disease_model.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/pandemic/performance.ex",
      "apps/lemon_sim/lib/lemon_sim/examples/pandemic/updater.ex"
    ]
    |> Enum.map(fn path -> File.read!(path) end)
    |> Enum.join("\n")
    |> Bundle.sha256()
  rescue
    _ -> nil
  end
end
