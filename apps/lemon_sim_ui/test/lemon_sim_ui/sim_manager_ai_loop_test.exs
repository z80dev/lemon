defmodule LemonSimUi.SimManagerAiLoopTest do
  @moduledoc """
  End-to-end coverage for `SimManager.run_ai_only/3`'s delegated loop
  (task #37): drives a real game through the real, already-running
  `LemonSimUi.SimManager` GenServer with a scripted `complete_fn`
  (no network calls) — the behavior no other test in this app exercises;
  `SimManager.start_sim/2` doesn't otherwise appear in any test here.
  """

  use ExUnit.Case, async: false

  alias Ai.Types.{AssistantMessage, Model, ToolCall}
  alias LemonCore.MapHelpers
  alias LemonSim.Kernel.Store
  alias LemonSimUi.SimManager

  test "the delegated loop persists+broadcasts every turn, accumulates plan_history, and cleans up on natural completion" do
    sim_id = "auc_delegation_#{System.unique_integer([:positive])}"

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
  end

  test "a single transient step crash is retried from the last good state and the game keeps going" do
    sim_id = "auc_retry_#{System.unique_integer([:positive])}"

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
      cost: %Ai.Types.ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 128_000,
      max_tokens: 4_096,
      headers: %{},
      compat: nil
    }
  end
end
