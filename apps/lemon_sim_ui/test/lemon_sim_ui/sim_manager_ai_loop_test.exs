defmodule LemonSimUi.SimManagerAiLoopTest do
  @moduledoc """
  End-to-end coverage for `SimManager.run_ai_only/3`'s delegated loop
  (task #37): drives a real game through the real, already-running
  `LemonSimUi.SimManager` GenServer with a scripted `complete_fn`
  (no network calls) — the behavior no other test in this app exercises;
  `SimManager.start_sim/2` doesn't otherwise appear in any test here.
  """

  use ExUnit.Case, async: false

  alias LemonAi.Types.{AssistantMessage, Model, ToolCall}
  alias LemonCore.MapHelpers
  alias LemonSim.Examples.SpaceStation
  alias LemonSim.Kernel.Store
  alias LemonSim.LLM.Usage, as: SimUsage
  alias LemonSimUi.SimManager

  # SimManager is a global singleton and Store persists sim state, so
  # anything created here leaks into other tests' listings (e.g.
  # SimDashboardLiveTest's "0 active" mount assertion) unless removed.
  defp cleanup_sim(sim_id) do
    on_exit(fn ->
      SimManager.stop_sim(sim_id)
      Store.delete_state(sim_id)
    end)
  end

  test "the delegated loop persists+broadcasts every turn, accumulates plan_history, and cleans up on natural completion" do
    sim_id = "auc_delegation_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok, tool_call("pass_auction", %{})}
    end

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:auction,
               sim_id: sim_id,
               player_count: 3,
               model: fake_model(),
               stream_options: %{},
               complete_fn: complete_fn
             )

    states = collect_states_until_game_over(sim_id)
    plan_history_lengths = Enum.map(states, &length(&1.plan_history))

    # Monotonically non-decreasing, one plan_history entry per completed turn
    # — the property that silently breaks if the transform hook's returned
    # state isn't fed forward into the next `Runner.step/3` call
    # (plan_history is a top-level State field, not part of `world`, and this
    # only survives if `append_decision_trace/4`'s output is what the loop
    # keeps recursing on).
    assert plan_history_lengths == Enum.sort(plan_history_lengths)
    assert Enum.max(plan_history_lengths) >= 5

    final = List.last(states)
    assert MapHelpers.get_key(final.world, :status) == "game_over"

    errors = MapHelpers.get_key(final.world, :runner_errors) || []
    refute Enum.any?(errors, fn e -> MapHelpers.get_key(e, :kind) == :turn_limit_exceeded end)

    # Natural completion: the runner exits on its own (no stop_sim call), and
    # SimManager's :DOWN handling / DynamicSupervisor cleanup both fire.
    wait_until(fn -> sim_id not in SimManager.list_running() end)

    stored = Store.get_state(sim_id)
    assert MapHelpers.get_key(stored.world, :status) == "game_over"
    assert length(stored.plan_history) == Enum.max(plan_history_lengths)
    assert stored.meta.run.status == "completed"
    refute stored.meta.run.resumable
    assert stored.meta.run.turns_completed >= 5
  end

  test "a single transient step crash is retried from the last good state and the game keeps going" do
    sim_id = "auc_retry_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    {:ok, call_count} = Agent.start_link(fn -> 0 end)

    complete_fn = fn _model, _context, _stream_opts ->
      n = Agent.get_and_update(call_count, fn n -> {n + 1, n + 1} end)

      if n == 2 do
        raise "boom (simulated transient failure)"
      else
        {:ok, tool_call("pass_auction", %{})}
      end
    end

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:auction,
               sim_id: sim_id,
               player_count: 3,
               model: fake_model(),
               stream_options: %{},
               complete_fn: complete_fn
             )

    states = collect_states_until_game_over(sim_id, 20_000)

    # Retried and recovered (not abandoned): the game still reaches game_over,
    # plan_history never goes backwards (a `:step_crash` retry resumes from
    # the checkpoint rather than skipping or duplicating a turn — it may
    # re-broadcast the same length once, alongside the recorded error, before
    # the retried turn completes and the length advances), and the crash is
    # on record without exhausting the retry budget.
    plan_history_lengths = Enum.map(states, &length(&1.plan_history))
    assert plan_history_lengths == Enum.sort(plan_history_lengths)

    final = List.last(states)
    assert MapHelpers.get_key(final.world, :status) == "game_over"

    errors = MapHelpers.get_key(final.world, :runner_errors) || []
    assert Enum.any?(errors, fn e -> MapHelpers.get_key(e, :kind) == :step_crash end)
    refute Enum.any?(errors, fn e -> MapHelpers.get_key(e, :kind) == :retry_limit_exceeded end)
  end

  test "turn budget exhaustion is durable and non-resumable" do
    sim_id = "auc_turn_limit_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    complete_fn = fn _model, _context, _stream_opts ->
      {:ok, tool_call("pass_auction", %{})}
    end

    LemonSim.Kernel.Bus.subscribe(sim_id)

    assert {:ok, ^sim_id} =
             SimManager.start_sim(:auction,
               sim_id: sim_id,
               player_count: 3,
               driver_max_turns: 1,
               model: fake_model(),
               stream_options: %{},
               complete_fn: complete_fn
             )

    assert_receive %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: ^sim_id}}, 5_000
    wait_until(fn -> sim_id not in SimManager.list_running() end)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "turn_limit_exceeded"
    assert stored.meta.run.turns_completed == 1
    assert stored.meta.run.rng_state != nil
    refute stored.meta.run.resumable
    assert {:error, {:not_resumable, "failed"}} = SimManager.resume_sim(sim_id)
  end

  test "persisted recovery attempts are capped and marked failed" do
    sim_id = "ww_recovery_limit_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "werewolf",
            status: "running",
            resumable: true,
            resume_count: 11,
            recovery_attempts: 5,
            max_turns: 50,
            turns_completed: 1
          }
        }
      )

    assert :ok = Store.put_state(state)

    assert {:error, {:not_resumable, "recovery_limit_exceeded"}} =
             SimManager.resume_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "recovery_limit_exceeded"
    refute stored.meta.run.resumable
  end

  test "recovery at an exhausted turn budget is durably marked failed" do
    sim_id = "spc_recovery_turn_budget_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "space_station",
            status: "running",
            resumable: true,
            recovery_attempts: 0,
            max_turns: 3,
            turns_completed: 3
          }
        }
      )

    assert :ok = Store.put_state(state)

    assert {:error, {:not_resumable, "turn_budget_exhausted"}} =
             SimManager.resume_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    assert stored.meta.run.failure_reason == "turn_budget_exhausted"
    refute stored.meta.run.resumable
  end

  test "transient recovery persistence failures retry and then durably terminalize" do
    sim_id = "spc_transient_recovery_#{System.unique_integer([:positive])}"
    on_exit(fn -> Store.delete_state(sim_id) end)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{
          run: %{
            domain: "space_station",
            status: "running",
            resumable: true,
            recovery_attempts: 0,
            max_turns: 50,
            turns_completed: 1
          }
        }
      )

    assert :ok = Store.put_state(state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{},
        recovery_queue: [],
        recovery_failures: %{},
        recovery_persist: fn candidate, _retries ->
          if candidate.meta.run.status == "failed" do
            Store.put_state(candidate)
          else
            {:error, :disk_unavailable}
          end
        end
      })

    assert {:noreply, manager_state} =
             SimManager.handle_info({:recover_runner, sim_id}, manager_state)

    assert manager_state.recovery_failures[sim_id] == 1
    original_capacity = manager_state.max_concurrent_runners

    assert {:noreply, capacity_state} =
             SimManager.handle_info(
               {:recover_runner, sim_id},
               %{manager_state | max_concurrent_runners: 0}
             )

    assert sim_id in capacity_state.recovery_queue
    assert capacity_state.recovery_failures[sim_id] == 1

    manager_state = %{
      capacity_state
      | max_concurrent_runners: original_capacity,
        recovery_queue: []
    }

    manager_state =
      Enum.reduce(2..4, manager_state, fn attempt, acc ->
        assert {:noreply, next} = SimManager.handle_info({:recover_runner, sim_id}, acc)
        assert next.recovery_failures[sim_id] == attempt
        assert Store.get_state(sim_id).meta.run.status == "running"
        next
      end)

    assert {:noreply, terminal_state} =
             SimManager.handle_info({:recover_runner, sim_id}, manager_state)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "failed"
    refute stored.meta.run.resumable
    assert stored.meta.run.failure_reason =~ "recovery_failed"
    assert terminal_state.recovery_failures == %{}
    refute Map.has_key?(terminal_state.runners, sim_id)
  end

  test "recovery queue continues after a non-resumable entry without wasting capacity" do
    suffix = System.unique_integer([:positive])
    exhausted_id = "spc_recovery_exhausted_#{suffix}"
    resumable_id = "spc_recovery_ready_#{suffix}"

    exhausted_state =
      SpaceStation.initial_state(sim_id: exhausted_id, player_count: 5)
      |> with_run_metadata(%{
        domain: "space_station",
        status: "running",
        resumable: true,
        recovery_attempts: 0,
        max_turns: 3,
        turns_completed: 3
      })

    resumable_state =
      SpaceStation.initial_state(sim_id: resumable_id, player_count: 5)
      |> with_run_metadata(%{
        domain: "space_station",
        status: "running",
        resumable: true,
        recovery_attempts: 0,
        max_turns: 50,
        turns_completed: 1
      })

    assert :ok = Store.put_state(exhausted_state)
    assert :ok = Store.put_state(resumable_state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{},
        recovery_queue: [exhausted_id, resumable_id],
        recovery_failures: %{},
        max_concurrent_runners: 1
      })

    assert {:noreply, recovered_state} =
             SimManager.handle_info({:recover_persisted, 0}, manager_state)

    assert Store.get_state(exhausted_id).meta.run.status == "failed"
    assert Map.has_key?(recovered_state.runners, resumable_id)
    refute resumable_id in recovered_state.recovery_queue

    %{ref: runner, usage_collector: collector} = recovered_state.runners[resumable_id]

    on_exit(fn ->
      if Process.alive?(runner) do
        DynamicSupervisor.terminate_child(LemonSimUi.SimRunnerSupervisor, runner)
      end

      if Process.alive?(collector), do: Agent.stop(collector)
      Store.delete_state(exhausted_id)
      Store.delete_state(resumable_id)
    end)
  end

  test "runner teardown persists final usage before the collector is stopped" do
    sim_id = "spc_final_usage_#{System.unique_integer([:positive])}"
    {:ok, collector} = SimUsage.start_link(sim_id)
    SimUsage.record_external_decision(collector, "captain", "test-model")

    terminal_state =
      SpaceStation.initial_state(sim_id: sim_id, player_count: 5)
      |> with_run_metadata(%{
        domain: "space_station",
        status: "completed",
        resumable: false,
        started_at_ms: System.system_time(:millisecond) - 1_000,
        finished_at_ms: System.system_time(:millisecond)
      })

    assert :ok = Store.put_state(terminal_state)

    manager_state =
      SimManager
      |> :sys.get_state()
      |> Map.merge(%{
        runners: %{
          sim_id => %{ref: self(), domain: :space_station, usage_collector: collector}
        },
        usage_artifacts: %{},
        recovery_queue: [],
        recovery_failures: %{}
      })

    assert {:noreply, stopped_state} =
             SimManager.handle_info({:DOWN, make_ref(), :process, self(), :normal}, manager_state)

    refute Process.alive?(collector)
    refute Map.has_key?(stopped_state.runners, sim_id)

    assert {:reply, usage, ^stopped_state} =
             SimManager.handle_call({:usage, sim_id}, self(), stopped_state)

    assert usage.totals.decisions == 1
    assert usage.actors["captain"].model_id == "test-model"
    assert Store.get_state(sim_id).meta.run.usage.totals.decisions == 1

    on_exit(fn -> Store.delete_state(sim_id) end)
  end

  test "operator stop terminalizes a persisted run without a live runner" do
    sim_id = "ww_orphan_stop_#{System.unique_integer([:positive])}"
    cleanup_sim(sim_id)

    state =
      LemonSim.Kernel.State.new(
        sim_id: sim_id,
        world: %{status: "in_progress", players: %{}},
        meta: %{run: %{domain: "werewolf", status: "running", resumable: true}}
      )

    assert :ok = Store.put_state(state)
    assert :ok = SimManager.stop_sim(sim_id)

    stored = Store.get_state(sim_id)
    assert stored.meta.run.status == "stopped"
    assert stored.meta.run.failure_reason == "operator_stop"
    refute stored.meta.run.resumable
  end

  test "terminal snapshot retention keeps the newest configured records" do
    suffix = System.unique_integer([:positive])
    old_id = "ww_retention_old_#{suffix}"
    newer_id = "ww_retention_newer_#{suffix}"
    target_id = "ww_retention_target_#{suffix}"
    original_manager_state = :sys.get_state(SimManager)

    on_exit(fn ->
      :sys.replace_state(SimManager, fn _ -> original_manager_state end)
      Enum.each([old_id, newer_id, target_id], &Store.delete_state/1)
    end)

    :sys.replace_state(SimManager, fn state -> %{state | max_stored_simulations: 1} end)

    for {sim_id, finished_at_ms} <- [{old_id, 1}, {newer_id, 2}] do
      assert :ok =
               Store.put_state(
                 LemonSim.Kernel.State.new(
                   sim_id: sim_id,
                   world: %{status: "game_over"},
                   meta: %{
                     run: %{
                       status: "completed",
                       resumable: false,
                       finished_at_ms: finished_at_ms
                     }
                   }
                 )
               )
    end

    assert :ok =
             Store.put_state(
               LemonSim.Kernel.State.new(
                 sim_id: target_id,
                 world: %{status: "in_progress"},
                 meta: %{run: %{status: "running", resumable: true}}
               )
             )

    assert :ok = SimManager.stop_sim(target_id)
    assert Store.get_state(target_id).meta.run.status == "stopped"
    assert Store.get_state(old_id) == nil
    assert Store.get_state(newer_id) == nil
  end

  defp collect_states_until_game_over(sim_id, timeout \\ 10_000) do
    collect_states_until_game_over(sim_id, timeout, [])
  end

  defp collect_states_until_game_over(sim_id, timeout, acc) do
    assert_receive %LemonCore.Event{type: :sim_world_updated, meta: %{sim_id: ^sim_id}} = event,
                   timeout

    state =
      case event.payload do
        %{state: state} -> state
        %{"state" => state} -> state
      end

    acc = acc ++ [state]

    if MapHelpers.get_key(state.world, :status) == "game_over" do
      acc
    else
      collect_states_until_game_over(sim_id, timeout, acc)
    end
  end

  defp wait_until(fun, attempts \\ 50)

  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp tool_call(name, arguments) do
    %AssistantMessage{
      role: :assistant,
      content: [
        %ToolCall{
          type: :tool_call,
          id: "call-#{System.unique_integer([:positive])}",
          name: name,
          arguments: arguments
        }
      ],
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp fake_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.invalid",
      reasoning: false,
      input: [:text],
      cost: %LemonAi.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end

  defp with_run_metadata(state, run) do
    %{state | meta: Map.put(state.meta || %{}, :run, run)}
  end
end
