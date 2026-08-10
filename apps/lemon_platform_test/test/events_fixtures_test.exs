defmodule LemonPlatformTest.EventsFixturesTest do
  use ExUnit.Case, async: true

  alias LemonCore.Events
  alias LemonPlatformTest.EventsFixtures

  # Every builder, paired with the event type it must be a valid payload for.
  @builders [
    {:run_started, &EventsFixtures.run_started/0},
    {:delta, &EventsFixtures.delta/0},
    {:run_completed, &EventsFixtures.run_completed/0},
    {:run_failed, &EventsFixtures.run_failed/0},
    {:approval_requested, &EventsFixtures.approval_requested/0},
    {:approval_resolved, &EventsFixtures.approval_resolved/0},
    {:cron_tick, &EventsFixtures.cron_tick/0},
    {:cron_run_started, &EventsFixtures.cron_run_started/0},
    {:cron_run_completed, &EventsFixtures.cron_run_completed/0},
    {:cron_job_created, &EventsFixtures.cron_job_changed/0}
  ]

  describe "defaults" do
    test "every builder produces its registered payload struct" do
      for {type, builder} <- @builders do
        payload = builder.()
        expected = Events.payload_module(type)

        assert is_struct(payload, expected),
               "#{type} fixture built #{inspect(payload.__struct__)}, expected #{inspect(expected)}"
      end
    end

    test "defaults satisfy the typed contract (cast round-trips the struct)" do
      for {type, builder} <- @builders do
        payload = builder.()
        assert {:ok, ^payload} = Events.cast(type, payload)
      end
    end

    test "defaults are JSON-encodable, as the JSONL backend requires" do
      for {_type, builder} <- @builders do
        assert {:ok, _json} = Jason.encode(builder.())
      end
    end

    test "delta carries its enforced run_id in the payload, unlike a raw map" do
      # The bug the fixture exists to prevent: a raw %{seq:, text:} map omits the
      # run_id the typed Delta enforces.
      assert %Events.Delta{run_id: "run_test"} = EventsFixtures.delta()
    end
  end

  describe "overrides" do
    test "top-level fields are overridable" do
      assert %Events.Delta{seq: 5, text: "hi", run_id: "run_9"} =
               EventsFixtures.delta(seq: 5, text: "hi", run_id: "run_9")
    end

    test "unknown keys raise, catching a fixture typo at the fixture" do
      assert_raise ArgumentError, fn -> EventsFixtures.delta(bogus: true) end
    end

    test "accepts a map as well as a keyword list" do
      assert EventsFixtures.run_started(%{run_id: "r"}) ==
               EventsFixtures.run_started(run_id: "r")
    end
  end

  describe "nested payloads" do
    test "run_completed lifts Completion shorthand into the nested struct" do
      assert %Events.RunCompleted{
               completed: %Events.Completion{ok: false, answer: "done", error: :boom},
               duration_ms: 30
             } =
               EventsFixtures.run_completed(
                 ok: false,
                 answer: "done",
                 error: :boom,
                 duration_ms: 30
               )
    end

    test "an explicit :completed wins over shorthand" do
      completion = EventsFixtures.completion(answer: "explicit")

      assert %Events.RunCompleted{completed: ^completion} =
               EventsFixtures.run_completed(completed: completion, answer: "ignored")
    end

    test "approval events coerce a :pending map into the nested struct" do
      assert %Events.ApprovalResolved{pending: %Events.ApprovalPending{tool: "read"}} =
               EventsFixtures.approval_resolved(pending: %{tool: "read"})

      assert %Events.ApprovalRequested{pending: %Events.ApprovalPending{tool: "read"}} =
               EventsFixtures.approval_requested(pending: %{tool: "read"})
    end
  end
end
