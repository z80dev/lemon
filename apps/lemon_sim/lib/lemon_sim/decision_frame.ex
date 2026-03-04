defmodule LemonSim.DecisionFrame do
  @moduledoc """
  Snapshot passed into the projector for a single decision.
  """

  alias LemonSim.State

  @enforce_keys [:sim_id, :world]
  defstruct sim_id: "",
            world: %{},
            recent_events: [],
            intent: nil,
            plan_history: [],
            memory_index_path: "index.md",
            meta: %{}

  @type t :: %__MODULE__{
          sim_id: String.t(),
          world: map(),
          recent_events: [LemonSim.Event.t()],
          intent: map() | nil,
          plan_history: [LemonSim.PlanStep.t() | map()],
          memory_index_path: String.t(),
          meta: map()
        }

  @doc """
  Creates a decision frame from persisted state.
  """
  @spec from_state(State.t(), keyword()) :: t()
  def from_state(%State{} = state, opts \\ []) do
    %__MODULE__{
      sim_id: state.sim_id,
      world: state.world,
      recent_events: state.recent_events,
      intent: state.intent,
      plan_history: state.plan_history,
      memory_index_path: state.memory_index_path,
      meta: Map.merge(state.meta, Keyword.get(opts, :meta, %{}))
    }
  end
end
