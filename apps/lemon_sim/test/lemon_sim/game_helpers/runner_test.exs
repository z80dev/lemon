defmodule LemonSim.LLM.GameHelpers.RunnerTest do
  use ExUnit.Case, async: true

  alias LemonSim.Kernel.{DecisionFrame, Event, State}
  alias LemonSim.LLM.GameHelpers.Runner, as: GameRunner

  @modules %{
    action_space: __MODULE__.GhActionSpaceStub,
    projector: __MODULE__.GhProjectorStub,
    decider: __MODULE__.GhCounterDeciderStub,
    updater: __MODULE__.GhFlakyUpdaterStub
  }

  defp default_opts_fn, do: fn _overrides -> [] end
  defp run_callbacks, do: [print_setup: fn _state -> :ok end, print_result: fn _world -> :ok end]

  defp multi_model_callbacks do
    [
      print_setup: fn _state -> :ok end,
      print_result: fn _world -> :ok end,
      announce_turn: fn _turn, _state -> :ok end
    ]
  end

  defp model_assignments do
    model = Ai.Models.get_model(:anthropic, "claude-haiku-4-5")
    %{"seat" => {model, "test-key"}}
  end

  describe "run/5" do
    test "an on_after_step returning {:ok, new_state} feeds forward across turns, same as run_until_terminal/3" do
      state = State.new(sim_id: "sim-run-transform", world: %{"turns" => 0})

      on_after_step = fn _turn, result ->
        marked = Map.get(result.state.world, "marked", 0) + 1
        {:ok, State.put_world(result.state, %{"marked" => marked})}
      end

      opts = [
        terminal?: fn s -> s.world["turns"] >= 3 end,
        driver_max_turns: 5,
        on_after_step: on_after_step,
        persist?: false
      ]

      assert {:ok, final_state} =
               GameRunner.run(state, @modules, default_opts_fn(), opts, run_callbacks())

      assert final_state.world["turns"] == 3
      assert final_state.world["marked"] == 3
    end

    test "resumable?: true surfaces {:error, reason, state} instead of {:error, reason}" do
      state = State.new(sim_id: "sim-run-resumable", world: %{"turns" => 0})

      opts = [
        terminal?: fn _s -> false end,
        driver_max_turns: 5,
        fail_at_turn: 2,
        resumable?: true,
        persist?: false
      ]

      assert {:error, {:step_failed, :boom}, resume_state} =
               GameRunner.run(state, @modules, default_opts_fn(), opts, run_callbacks())

      assert resume_state.world["turns"] == 1
    end

    test "without resumable?, the original 2-tuple error shape is preserved" do
      state = State.new(sim_id: "sim-run-default-error", world: %{"turns" => 0})

      opts = [
        terminal?: fn _s -> false end,
        driver_max_turns: 5,
        fail_at_turn: 2,
        persist?: false
      ]

      assert {:error, {:step_failed, :boom}} =
               GameRunner.run(state, @modules, default_opts_fn(), opts, run_callbacks())
    end
  end

  describe "run_multi_model/5" do
    test "print_step's return value is forwarded as the on_after_step transform" do
      state = State.new(sim_id: "sim-multi-transform", world: %{"turns" => 0})

      print_step = fn _turn, result ->
        marked = Map.get(result.state.world, "marked", 0) + 1
        {:ok, State.put_world(result.state, %{"marked" => marked})}
      end

      opts = [
        terminal?: fn s -> s.world["turns"] >= 3 end,
        driver_max_turns: 5,
        model_assignments: model_assignments(),
        persist?: false
      ]

      callbacks = multi_model_callbacks() ++ [print_step: print_step]

      assert {:ok, final_state} =
               GameRunner.run_multi_model(state, @modules, default_opts_fn(), opts, callbacks)

      assert final_state.world["turns"] == 3
      assert final_state.world["marked"] == 3
    end

    test "resumable?: true surfaces {:error, reason, state}" do
      state = State.new(sim_id: "sim-multi-resumable", world: %{"turns" => 0})

      opts = [
        terminal?: fn _s -> false end,
        driver_max_turns: 5,
        fail_at_turn: 2,
        resumable?: true,
        model_assignments: model_assignments(),
        persist?: false
      ]

      callbacks = multi_model_callbacks() ++ [print_step: fn _turn, _result -> :ok end]

      assert {:error, {:step_failed, :boom}, resume_state} =
               GameRunner.run_multi_model(state, @modules, default_opts_fn(), opts, callbacks)

      assert resume_state.world["turns"] == 1
    end
  end

  defmodule GhActionSpaceStub do
    @behaviour LemonSim.Kernel.ActionSpace

    @impl true
    def tools(_state, _opts) do
      {:ok,
       [
         %AgentCore.Types.AgentTool{
           name: "tick",
           description: "Advance one turn",
           parameters: %{"type" => "object", "properties" => %{}},
           label: "Tick",
           execute: fn _id, _params, _signal, _on_update ->
             %AgentCore.Types.AgentToolResult{}
           end
         }
       ]}
    end
  end

  defmodule GhProjectorStub do
    @behaviour LemonSim.Kernel.Projector

    @impl true
    def project(%DecisionFrame{} = frame, _tools, _opts) do
      context =
        Ai.Types.Context.new(system_prompt: "test")
        |> Ai.Types.Context.add_user_message("world=#{inspect(frame.world)}")

      {:ok, context}
    end
  end

  defmodule GhCounterDeciderStub do
    @behaviour LemonSim.Kernel.Decider

    @impl true
    def decide(_context, _tools, _opts) do
      {:ok, %{"type" => "tool_call", "result_details" => %{"event" => %{"kind" => "tick"}}}}
    end
  end

  # Fails the update the turn `state.world["turns"]` is about to become
  # `opts[:fail_at_turn]`; succeeds (and increments "turns") otherwise.
  defmodule GhFlakyUpdaterStub do
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
