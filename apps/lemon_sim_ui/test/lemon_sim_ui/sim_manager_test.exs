defmodule LemonSimUi.SimManagerTest do
  use ExUnit.Case, async: true

  alias LemonSim.Kernel.{Event, State}
  alias LemonSimUi.SimManager

  test "parse_model_spec resolves hyphenated provider names" do
    assert SimManager.parse_model_spec("openai-codex:gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec resolves aliased provider names" do
    assert SimManager.parse_model_spec("openai_codex:gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec resolves world-snapshot provider/model strings" do
    # attach_model_assignments stores "provider/model_id"; resume reads it back.
    assert SimManager.parse_model_spec("kimi/k2p5") == {:kimi, "k2p5"}

    assert SimManager.parse_model_spec("openai-codex/gpt-5.3-codex-spark") ==
             {:"openai-codex", "gpt-5.3-codex-spark"}
  end

  test "parse_model_spec treats unknown-prefix slashes as a bare model id" do
    assert SimManager.parse_model_spec("not-a-provider/some-model") ==
             {:anthropic, "not-a-provider/some-model"}
  end

  test "parse_model_spec defaults bare ids to anthropic" do
    assert SimManager.parse_model_spec("claude-haiku-4-5") ==
             {:anthropic, "claude-haiku-4-5"}
  end

  test "werewolf rejects partial and oversized model lineups" do
    for model_specs <- [
          ["anthropic:claude-sonnet-4-20250514"],
          List.duplicate("anthropic:claude-sonnet-4-20250514", 6)
        ] do
      sim_id = "ww_model_count_#{System.unique_integer([:positive])}"

      assert {:error, message} =
               SimManager.start_sim(:werewolf,
                 sim_id: sim_id,
                 player_count: 5,
                 model_specs: model_specs
               )

      assert message == "Werewolf model_specs must contain exactly 5 entries"
    end
  end

  test "decision traces describe rejection without leaking the attempted payload" do
    before =
      State.new(
        sim_id: "ww_rejected_trace",
        world: %{phase: "day_discussion", day_number: 2, active_actor_id: "Alice"}
      )

    rejection =
      Event.new("action_rejected", %{
        "kind" => "make_statement",
        "player_id" => "Alice",
        "reason" => "not the active actor"
      })

    after_rejection = State.append_event(before, rejection)

    traced =
      SimManager.append_decision_trace(after_rejection, before, 3, %{
        decision: %{
          thought: "private forged thought",
          executed_calls: [%{tool_name: "make_statement", arguments: %{statement: "forged"}}]
        },
        events: [Event.new("make_statement", %{"statement" => "forged"})]
      })

    trace = List.last(traced.plan_history)
    assert trace.summary == "Alice action rejected"
    assert trace.rationale == "not the active actor"
    assert trace.meta.events == ["action_rejected"]
    refute inspect(trace) =~ "private forged thought"
    refute inspect(trace) =~ "statement: \"forged\""
  end
end
