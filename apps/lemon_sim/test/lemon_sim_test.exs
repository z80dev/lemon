defmodule LemonSimTest do
  use ExUnit.Case

  alias LemonSim.DecisionAdapters.ToolResultEvents
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

  test "event convenience builders normalize payload and meta" do
    event = Event.new("move_applied", [row: 1, col: 2], source: :updater)

    assert event.kind == "move_applied"
    assert event.payload == %{row: 1, col: 2}
    assert event.meta == %{source: :updater}
  end

  test "state convenience helpers append multiple events and update world" do
    state = State.new(sim_id: "sim-helpers", world: %{board: [], status: "in_progress"})

    next_state =
      state
      |> State.put_world(status: "won", winner: "X")
      |> State.append_event("move_applied", %{player: "X", row: 0, col: 1})
      |> State.append_events([
        Event.new("game_over", %{status: "won", winner: "X"}),
        %{kind: "summary", payload: %{message: "done"}}
      ])

    assert next_state.world.status == "won"
    assert next_state.world.winner == "X"

    assert Enum.map(next_state.recent_events, & &1.kind) == [
             "move_applied",
             "game_over",
             "summary"
           ]
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

  test "runner step uses default tool-result event adapter" do
    state = State.new(sim_id: "sim-step-1", world: %{"hp" => 100})

    assert {:ok, result} =
             Runner.step(
               state,
               %{
                 action_space: __MODULE__.ActionSpaceStub,
                 projector: __MODULE__.ProjectorStub,
                 decider: __MODULE__.StepDeciderStub,
                 updater: __MODULE__.UpdaterStub
               },
               []
             )

    assert result.decision["type"] == "tool_call"
    assert [%Event{kind: "enemy_visible"}] = result.events
    assert {:decide, "enemy spotted"} = result.signal
    assert [%Event{kind: "enemy_visible"}] = result.state.recent_events
  end

  test "runner step returns adapter error" do
    state = State.new(sim_id: "sim-step-2", world: %{"hp" => 100})

    assert {:error, :forced_error} =
             Runner.step(
               state,
               %{
                 action_space: __MODULE__.ActionSpaceStub,
                 projector: __MODULE__.ProjectorStub,
                 decider: __MODULE__.StepDeciderStub,
                 updater: __MODULE__.UpdaterStub,
                 decision_adapter: __MODULE__.DecisionAdapterErrorStub
               },
               []
             )
  end

  test "runner step allows empty event adaptation" do
    state = State.new(sim_id: "sim-step-3", world: %{"hp" => 100})

    assert {:ok, result} =
             Runner.step(
               state,
               %{
                 action_space: __MODULE__.ActionSpaceStub,
                 projector: __MODULE__.ProjectorStub,
                 decider: __MODULE__.StepDeciderStub,
                 updater: __MODULE__.UpdaterStub,
                 decision_adapter: __MODULE__.DecisionAdapterEmptyStub
               },
               []
             )

    assert result.events == []
    assert result.signal == :skip
    assert result.state == state
  end

  test "runner runs until terminal state" do
    state = State.new(sim_id: "sim-run", world: %{"turns" => 0})

    assert {:ok, final_state} =
             Runner.run_until_terminal(
               state,
               %{
                 action_space: __MODULE__.ActionSpaceStub,
                 projector: __MODULE__.ProjectorStub,
                 decider: __MODULE__.CounterDeciderStub,
                 updater: __MODULE__.CounterUpdaterStub
               },
               max_turns: 5,
               terminal?: fn state -> state.world["turns"] >= 3 end
             )

    assert final_state.world["turns"] == 3
  end

  test "default tool-result adapter supports multiple events" do
    state = State.new(sim_id: "sim-adapter", world: %{})

    assert {:ok, [%Event{kind: "a"}, %Event{kind: "b"}]} =
             ToolResultEvents.to_events(
               %{
                 "type" => "tool_call",
                 "result_details" => %{"events" => [%{"kind" => "a"}, %{"kind" => "b"}]}
               },
               state,
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

  defmodule StepDeciderStub do
    @behaviour LemonSim.Decider

    @impl true
    def decide(_context, _tools, _opts) do
      {:ok,
       %{
         "type" => "tool_call",
         "result_details" => %{"event" => %{"kind" => "enemy_visible"}}
       }}
    end
  end

  defmodule DecisionAdapterStub do
    @behaviour LemonSim.DecisionAdapter

    @impl true
    def to_events(%{"result_details" => %{"event" => event}}, _state, _opts), do: {:ok, [event]}
    def to_events(_decision, _state, _opts), do: {:error, :missing_event}
  end

  defmodule DecisionAdapterErrorStub do
    @behaviour LemonSim.DecisionAdapter

    @impl true
    def to_events(_decision, _state, _opts), do: {:error, :forced_error}
  end

  defmodule DecisionAdapterEmptyStub do
    @behaviour LemonSim.DecisionAdapter

    @impl true
    def to_events(_decision, _state, _opts), do: {:ok, []}
  end

  defmodule CounterDeciderStub do
    @behaviour LemonSim.Decider

    @impl true
    def decide(_context, _tools, _opts) do
      {:ok, %{"type" => "tool_call", "result_details" => %{"event" => %{"kind" => "tick"}}}}
    end
  end

  defmodule CounterUpdaterStub do
    @behaviour LemonSim.Updater

    @impl true
    def apply_event(state, event, _opts) do
      event = Event.new(event)
      next_state = State.append_event(state, event)

      turns =
        next_state.world
        |> Map.get("turns", 0)
        |> Kernel.+(1)

      {:ok, State.put_world(next_state, %{"turns" => turns}), :skip}
    end
  end

  test "decision signal helper detects decide states" do
    assert DecisionSignal.decide?(:decide)
    assert DecisionSignal.decide?({:decide, "reason"})
    refute DecisionSignal.decide?(:skip)
  end
end
