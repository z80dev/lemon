defmodule LemonCore.EventTest do
  use ExUnit.Case, async: true

  alias LemonCore.Event
  alias LemonCore.Events.Action
  alias LemonCore.Events.EngineAction

  describe "now_ms/0" do
    test "returns current time in milliseconds" do
      before = System.system_time(:millisecond)
      result = Event.now_ms()
      after_time = System.system_time(:millisecond)

      assert result >= before
      assert result <= after_time
    end
  end

  describe "validated run event constructors" do
    test "creates engine action events" do
      event =
        Event.engine_action(
          %{
            engine: "codex",
            phase: :updated,
            action: %{id: "a1", kind: "reasoning", title: "checking", detail: %{}}
          },
          %{run_id: "run-1"}
        )

      assert event.type == :engine_action
      assert event.payload.action.kind == "reasoning"
    end

    test "rejects malformed engine action events" do
      assert_raise ArgumentError, fn ->
        Event.engine_action(%{action: %{id: "", kind: "tool", title: "bad"}}, %{})
      end
    end

    test "creates canonical reasoning engine action events" do
      event =
        Event.engine_reasoning(%{
          run_id: "run-1",
          session_key: "agent:default:web:default:dm:1",
          text: "checking",
          source: "runner_note",
          phase: "updated",
          visibility: :operator
        })

      assert event.type == :engine_action
      assert event.meta.run_id == "run-1"
      assert event.meta.session_key == "agent:default:web:default:dm:1"
      assert event.meta.visibility == :operator
      assert event.payload.action.kind == "reasoning"
      assert event.payload.action.title == "checking"

      assert event.payload.action.detail.reasoning == %{
               text: "checking",
               source: "runner_note",
               phase: "updated"
             }
    end

    test "rejects malformed reasoning engine action events" do
      assert_raise ArgumentError, fn ->
        Event.engine_reasoning(%{
          run_id: "run-1",
          session_key: "agent:default:web:default:dm:1",
          text: ""
        })
      end
    end
  end

  test "approval and compaction semantics survive typed engine action JSON projection" do
    for {kind, detail} <- [
          {:approval, %{"approval_id" => "approval-1", "decision" => "pending"}},
          {:compaction, %{"compaction" => %{"tokens_before" => 10_000, "tokens_after" => 2_000}}}
        ],
        wire_kind <- [kind, Atom.to_string(kind)] do
      payload =
        EngineAction.from_map(%{
          "engine" => "lemon",
          "phase" => "updated",
          "action" => %{
            "id" => "semantic-action",
            "kind" => wire_kind,
            "title" => "Session activity",
            "detail" => detail
          }
        })

      assert payload.action.kind == kind
      assert payload.action.detail == detail
      assert Action.valid_kind?(wire_kind)

      projected = payload |> Jason.encode!() |> Jason.decode!()
      assert projected["action"]["kind"] == Atom.to_string(kind)
      assert projected["action"]["detail"] == detail
    end
  end
end
