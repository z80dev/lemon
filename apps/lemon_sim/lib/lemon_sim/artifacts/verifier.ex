defmodule LemonSim.Artifacts.Verifier do
  @moduledoc false

  defdelegate verify_run(artifact_dir), to: LemonSim.Bench.Artifacts.Verifier
end
