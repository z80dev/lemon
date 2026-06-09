defmodule LemonSim.State do
  @moduledoc false

  @type t :: LemonSim.Kernel.State.t()

  defdelegate new(attrs), to: LemonSim.Kernel.State
  defdelegate append_event(state, event), to: LemonSim.Kernel.State
  defdelegate append_event(state, event, max_events), to: LemonSim.Kernel.State
  defdelegate append_event(state, kind, payload, meta), to: LemonSim.Kernel.State
  defdelegate append_event(state, kind, payload, meta, max_events), to: LemonSim.Kernel.State
  defdelegate append_events(state, events), to: LemonSim.Kernel.State
  defdelegate append_events(state, events, max_events), to: LemonSim.Kernel.State
  defdelegate put_world(state, updates), to: LemonSim.Kernel.State
  defdelegate update_world(state, updater), to: LemonSim.Kernel.State
  defdelegate append_plan_step(state, step, max_steps \\ 50), to: LemonSim.Kernel.State
end
