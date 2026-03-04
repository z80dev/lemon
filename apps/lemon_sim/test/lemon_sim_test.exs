defmodule LemonSimTest do
  use ExUnit.Case

  alias LemonSim.{DecisionFrame, DecisionSignal, Event, PlanStep, Runner, State}

  test "state builds from string-key maps and appends bounded history" do
    state =
      State.new(%{
        "sim_id" => "sim-1",
        "world" => %{"position" => [0, 0]},
        "recent_events" => [%{"kind" => "spawn"}]
      })

    assert state.sim_id == "sim-1"
    assert state.world["position"] == [0, 0]
    assert [%Event{kind: "spawn"}] = state.recent_events

    next =
      state
      |> State.append_event(%{kind: :moved, payload: %{"to" => [1, 0]}}, 1)
      |> State.append_plan_step(PlanStep.new("flank left"), 5)

    assert length(next.recent_events) == 1
    assert [%Event{kind: :moved}] = next.recent_events
    assert [%PlanStep{summary: "flank left"}] = next.plan_history
  end

  test "runner stops when updater requests a decision" do
    state = State.new(sim_id: "sim-2", world: %{"hp" => 100})
    events = [%{kind: "tick"}, %{kind: "enemy_visible"}]

    assert {:ok, _next_state, {:decide, reason}} =
             Runner.ingest_events(state, events, __MODULE__.UpdaterStub)

    assert reason == "enemy spotted"
  end

  test "runner decides once using action space/projector/decider modules" do
    state = State.new(sim_id: "sim-3", world: %{"cooldown" => 0})

    assert {:ok, %{"tool" => "attack"}, ^state} =
             Runner.decide_once(
               state,
               %{
                 action_space: __MODULE__.ActionSpaceStub,
                 projector: __MODULE__.ProjectorStub,
                 decider: __MODULE__.DeciderStub
               },
               []
             )
  end

  defmodule UpdaterStub do
    @behaviour LemonSim.Updater

    @impl true
    def apply_event(state, event, _opts) do
      event = Event.new(event)
      next = State.append_event(state, event)

      case event.kind do
        "enemy_visible" -> {:ok, next, {:decide, "enemy spotted"}}
        _ -> {:ok, next, :skip}
      end
    end
  end

  defmodule ActionSpaceStub do
    @behaviour LemonSim.ActionSpace

    @impl true
    def tools(_state, _opts) do
      {:ok,
       [
         %AgentCore.Types.AgentTool{
           name: "attack",
           description: "Attack target",
           parameters: %{"type" => "object", "properties" => %{}},
           label: "Attack",
           execute: fn _id, _params, _signal, _on_update ->
             %AgentCore.Types.AgentToolResult{}
           end
         }
       ]}
    end
  end

  defmodule ProjectorStub do
    @behaviour LemonSim.Projector

    @impl true
    def project(%DecisionFrame{} = frame, _tools, _opts) do
      context =
        Ai.Types.Context.new(system_prompt: "test")
        |> Ai.Types.Context.add_user_message("world=#{inspect(frame.world)}")

      {:ok, context}
    end
  end

  defmodule DeciderStub do
    @behaviour LemonSim.Decider

    @impl true
    def decide(_context, tools, _opts) do
      first_tool = tools |> List.first() |> Map.fetch!(:name)
      {:ok, %{"tool" => first_tool}}
    end
  end

  test "decision signal helper detects decide states" do
    assert DecisionSignal.decide?(:decide)
    assert DecisionSignal.decide?({:decide, "reason"})
    refute DecisionSignal.decide?(:skip)
  end
end
