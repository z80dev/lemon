defmodule LemonSim.Kernel.RunnerTest do
  use ExUnit.Case, async: true

  alias LemonSim.Kernel.{DecisionFrame, Event, Runner, State}

  @modules %{
    action_space: __MODULE__.KernelActionSpaceStub,
    projector: __MODULE__.KernelProjectorStub,
    decider: __MODULE__.KernelCounterDeciderStub,
    updater: __MODULE__.KernelFlakyUpdaterStub
  }

  describe "on_after_step transform" do
    test "a callback returning {:ok, new_state} feeds the transformed state into later turns" do
      state = State.new(sim_id: "sim-transform", world: %{"turns" => 0})

      on_after_step = fn _turn, result ->
        marked = Map.get(result.state.world, "marked", 0) + 1
        {:ok, State.put_world(result.state, %{"marked" => marked})}
      end

      assert {:ok, final_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn s -> s.world["turns"] >= 3 end,
                 on_after_step: on_after_step
               )

      # If the transform fed forward correctly, "marked" accumulates once per
      # turn (3 turns => 3); if it were dropped (raw result.state used
      # instead), it would never exceed 1.
      assert final_state.world["turns"] == 3
      assert final_state.world["marked"] == 3
    end

    test "a callback returning :ok (or anything else) is notify-only, exactly as before" do
      state = State.new(sim_id: "sim-notify-only", world: %{"turns" => 0})
      test_pid = self()

      on_after_step = fn turn, result ->
        send(test_pid, {:notified, turn, result.state.world["turns"]})
        :ok
      end

      assert {:ok, final_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn s -> s.world["turns"] >= 3 end,
                 on_after_step: on_after_step
               )

      assert final_state.world["turns"] == 3
      refute Map.has_key?(final_state.world, "marked")
      assert_received {:notified, 1, 1}
      assert_received {:notified, 2, 2}
      assert_received {:notified, 3, 3}
    end

    test "omitting on_after_step behaves exactly as before" do
      state = State.new(sim_id: "sim-no-hook", world: %{"turns" => 0})

      assert {:ok, final_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn s -> s.world["turns"] >= 2 end
               )

      assert final_state.world["turns"] == 2
    end
  end

  describe "resumable?" do
    test "defaults to the original 2-tuple error shape on step failure" do
      state = State.new(sim_id: "sim-fail-default", world: %{"turns" => 0})

      assert {:error, {:step_failed, :boom}} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn _s -> false end,
                 fail_at_turn: 2
               )
    end

    test "resumable?: true carries the last successfully-completed state on step failure" do
      state = State.new(sim_id: "sim-fail-resumable", world: %{"turns" => 0})

      assert {:error, {:step_failed, :boom}, resume_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn _s -> false end,
                 fail_at_turn: 2,
                 resumable?: true
               )

      assert %State{} = resume_state
      assert resume_state.world["turns"] == 1
    end

    test "resumable?: true composes with on_after_step: the carried state includes the transform" do
      state = State.new(sim_id: "sim-fail-resumable-transform", world: %{"turns" => 0})

      on_after_step = fn _turn, result ->
        {:ok, State.put_world(result.state, %{"marked" => true})}
      end

      assert {:error, {:step_failed, :boom}, resume_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 5,
                 terminal?: fn _s -> false end,
                 fail_at_turn: 2,
                 resumable?: true,
                 on_after_step: on_after_step
               )

      assert resume_state.world["turns"] == 1
      assert resume_state.world["marked"] == true
    end

    test "resuming from the carried state and retrying reaches the same terminal state as an uninterrupted run" do
      state = State.new(sim_id: "sim-retry", world: %{"turns" => 0})

      opts = [driver_max_turns: 5, terminal?: fn s -> s.world["turns"] >= 3 end]

      assert {:error, {:step_failed, :boom}, resume_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 opts ++ [fail_at_turn: 2, resumable?: true]
               )

      # Retry from the resume point without the fault: same terminal outcome
      # a caller's own retry-with-backoff loop would produce.
      assert {:ok, final_state} = Runner.run_until_terminal(resume_state, @modules, opts)
      assert final_state.world["turns"] == 3
    end

    test "defaults to the original 2-tuple error shape when the turn budget is exhausted" do
      state = State.new(sim_id: "sim-budget-default", world: %{"turns" => 0})

      assert {:error, {:turn_limit_exceeded, 2}} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 2,
                 terminal?: fn _s -> false end
               )
    end

    test "resumable?: true carries state when the turn budget is exhausted" do
      state = State.new(sim_id: "sim-budget-resumable", world: %{"turns" => 0})

      assert {:error, {:turn_limit_exceeded, 2}, resume_state} =
               Runner.run_until_terminal(
                 state,
                 @modules,
                 driver_max_turns: 2,
                 terminal?: fn _s -> false end,
                 resumable?: true
               )

      assert resume_state.world["turns"] == 2
    end
  end

  defmodule KernelActionSpaceStub do
    @behaviour LemonSim.Kernel.ActionSpace

    @impl true
    def tools(_state, _opts) do
      {:ok,
       [
         %LemonAgent.Types.AgentTool{
           name: "tick",
           description: "Advance one turn",
           parameters: %{"type" => "object", "properties" => %{}},
           label: "Tick",
           execute: fn _id, _params, _signal, _on_update ->
             %LemonAgent.Types.AgentToolResult{}
           end
         }
       ]}
    end
  end

  defmodule KernelProjectorStub do
    @behaviour LemonSim.Kernel.Projector

    @impl true
    def project(%DecisionFrame{} = frame, _tools, _opts) do
      context =
        LemonAi.Types.Context.new(system_prompt: "test")
        |> LemonAi.Types.Context.add_user_message("world=#{inspect(frame.world)}")

      {:ok, context}
    end
  end

  defmodule KernelCounterDeciderStub do
    @behaviour LemonSim.Kernel.Decider

    @impl true
    def decide(_context, _tools, _opts) do
      {:ok, %{"type" => "tool_call", "result_details" => %{"event" => %{"kind" => "tick"}}}}
    end
  end

  # Fails the update (and therefore the whole step) the turn `state.world["turns"]`
  # is about to become `opts[:fail_at_turn]`; succeeds (and increments "turns")
  # on every other call, so the game log-progress before the fault is
  # deterministic and reproducible.
  defmodule KernelFlakyUpdaterStub do
    @behaviour LemonSim.Kernel.Updater

    @impl true
    def apply_event(state, event, opts) do
      turns = Map.get(state.world, "turns", 0)
      fail_at = Keyword.get(opts, :fail_at_turn)

      if fail_at && turns + 1 == fail_at do
        {:error, :boom}
      else
        event = Event.new(event)
        next = State.append_event(state, event)
        {:ok, State.put_world(next, %{"turns" => turns + 1}), :skip}
      end
    end
  end
end
