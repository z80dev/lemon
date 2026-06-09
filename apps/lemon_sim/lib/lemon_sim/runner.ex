defmodule LemonSim.Runner do
  @moduledoc false

  defdelegate ingest_events(state, events, updater, opts \\ []), to: LemonSim.Kernel.Runner
  defdelegate decide_once(state, modules, opts), to: LemonSim.Kernel.Runner
  defdelegate step(state, modules, opts \\ []), to: LemonSim.Kernel.Runner
  defdelegate run_until_terminal(state, modules, opts \\ []), to: LemonSim.Kernel.Runner
end
