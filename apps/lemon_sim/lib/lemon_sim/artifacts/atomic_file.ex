defmodule LemonSim.Artifacts.AtomicFile do
  @moduledoc false

  defdelegate write!(path, contents), to: LemonSim.Bench.Artifacts.AtomicFile
end
