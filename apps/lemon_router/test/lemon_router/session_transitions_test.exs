defmodule LemonRouter.SessionTransitionsTest do
  use ExUnit.Case, async: true

  alias LemonCore.ExecutionCommand
  alias LemonRouter.{SessionState, SessionTransitions, Submission}

  test "idle submit queues work and requests start" do
    state = SessionState.new(conversation_key: {:session, "s1"})
    submission = submission("run1", "s1", :collect, "one")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, submission, 100)

    assert next_state.active == nil
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1"]
    assert effects == [:maybe_start_next]
  end

  test "busy submit preserves active and queues the next run" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.submit(state, submission("run2", "s1", :collect, "two"), 100)

    assert next_state.active.run_id == "run1"
    assert Enum.map(next_state.queue, & &1.run_id) == ["run2"]
    assert effects == []
  end

  test "replaying a retained run id is a no-op in every coordinator phase" do
    duplicate = submission("stable", "s1", :collect, "duplicate")

    states = [
      %SessionState{
        conversation_key: {:session, "s1"},
        active: %{run_id: "stable", session_key: "s1"}
      },
      %SessionState{
        conversation_key: {:session, "s1"},
        queue: [submission("stable", "s1", :collect, "queued")]
      },
      %SessionState{
        conversation_key: {:session, "s1"},
        pending_steers: %{
          "active" => [{submission("stable", "s1", :followup, "pending"), :followup}]
        }
      }
    ]

    for state <- states do
      assert {:ok, ^state, [:noop]} = SessionTransitions.submit(state, duplicate, 100)
    end
  end

  test "backlog bounds count pending steers and preserve full-queue replay" do
    queued = for n <- 1..127, do: submission("queued-#{n}", "s1", :collect, "queued")
    steer = submission("pending-steer", "s1", :steer, "correction")

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "active", session_key: "s1"},
      queue: queued,
      pending_steers: %{"active" => [{steer, :followup}]}
    }

    assert {:error, :session_queue_full} =
             SessionTransitions.submit(
               state,
               submission("overflow", "s1", :interrupt, "new"),
               100
             )

    assert {:ok, ^state, [:noop]} =
             SessionTransitions.submit(state, List.first(queued), 100)

    assert {:ok, released, _} = SessionTransitions.abort_run(state, steer.run_id, :user_requested)

    assert {:ok, _accepted, []} =
             SessionTransitions.submit(released, submission("new", "s1", :collect, "new"), 100)
  end

  test "debounce cannot grow a merged prompt past the byte bound" do
    previous = submission("previous", "s1", :followup, String.duplicate("a", 1_048_570))

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "active", session_key: "s1"},
      queue: [previous],
      last_followup_at_ms: 100
    }

    assert {:error, :session_queue_full} =
             SessionTransitions.submit(
               state,
               submission("overflow", "s1", :followup, "123456"),
               200
             )

    assert state.queue == [previous]
  end

  test "encoded image budget counts typed and map data across queued and pending steers" do
    chunk = :binary.copy("a", 4_194_304)

    queued =
      submission("queued-image", "s1", :collect, "",
        images: [%LemonAi.Types.ImageContent{data: chunk <> chunk}]
      )

    pending =
      submission("pending-image", "s1", :steer, "",
        images: [%{data: chunk}, %{"data" => nil}, %{data: 123}, nil]
      )

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "active", session_key: "s1"},
      queue: [queued],
      pending_steers: %{"active" => [{pending, :followup}]}
    }

    boundary =
      submission("boundary-image", "s1", :steer, "", images: [%{"data" => chunk}])

    assert {:ok, saturated, []} = SessionTransitions.submit(state, boundary, 100)

    assert List.last(saturated.queue).execution_request.images ==
             boundary.execution_request.images

    assert saturated.pending_steers == state.pending_steers
    assert length(saturated.queue) == 2

    for mode <- [:collect, :followup, :steer, :steer_backlog, :redirect, :interrupt] do
      overflow =
        submission("overflow-#{mode}", "s1", mode, "",
          images: [%LemonAi.Types.ImageContent{data: "a"}]
        )

      assert {:error, :session_queue_full} = SessionTransitions.submit(saturated, overflow, 200)
    end

    # Fixed-ID replay is an acknowledgement lookup even if its new payload alone
    # would exceed the image budget.
    oversized_replay =
      submission("boundary-image", "s1", :interrupt, "",
        images: [%{"data" => :binary.copy("a", 16_777_217)}]
      )

    assert {:ok, ^saturated, [:noop]} =
             SessionTransitions.submit(saturated, oversized_replay, 200)

    assert {:ok, released, [:noop]} =
             SessionTransitions.steer_accepted(saturated, "pending-image")

    assert {:ok, accepted, []} =
             SessionTransitions.submit(
               released,
               submission("after-release", "s1", :collect, "",
                 images: [%LemonAi.Types.ImageContent{data: "a"}]
               ),
               300
             )

    assert length(accepted.queue) == 3
  end

  test "a single over-budget image is rejected before idle start or active interruption" do
    overflow =
      submission("oversized", "s1", :interrupt, "",
        images: [%LemonAi.Types.ImageContent{data: :binary.copy("a", 16_777_217)}]
      )

    for active <- [nil, %{run_id: "active", session_key: "s1"}] do
      state = %SessionState{conversation_key: {:session, "s1"}, active: active}
      assert {:error, :session_queue_full} = SessionTransitions.submit(state, overflow, 100)
      assert state.queue == []
      assert state.pending_steers == %{}
    end
  end

  test "image followups never debounce away prompt association, attachments or fixed ids" do
    image = %LemonAi.Types.ImageContent{
      data:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="
    }

    images = List.duplicate(image, 5)

    for {previous_images, current_images} <- [{images, []}, {[], images}, {images, images}] do
      previous = submission("previous", "s1", :followup, "first", images: previous_images)
      current = submission("current", "s1", :followup, "second", images: current_images)

      state = %SessionState{
        conversation_key: {:session, "s1"},
        active: %{run_id: "active", session_key: "s1"},
        queue: [previous],
        last_followup_at_ms: 100
      }

      assert {:ok, next_state, []} = SessionTransitions.submit(state, current, 200)
      assert [retained_previous, retained_current] = next_state.queue
      assert retained_previous.run_id == previous.run_id
      assert retained_previous.execution_request == previous.execution_request
      assert retained_current.run_id == current.run_id
      assert retained_current.execution_request.run_id == current.run_id
      assert retained_current.execution_request.prompt == "second"
      assert retained_current.execution_request.images == current_images

      for retained <- [previous, current] do
        assert {:ok, ^next_state, [:noop]} = SessionTransitions.submit(next_state, retained, 250)
      end
    end
  end

  test "image steering modes queue intact fallback runs and retain requested mode receipts" do
    images = [%LemonAi.Types.ImageContent{data: "iVBORw0KGgo="}]

    for {mode, fallback} <- [steer: :followup, steer_backlog: :collect, redirect: :followup],
        active <- [nil, %{run_id: "active", session_key: "s1"}] do
      meta = %{async_followups: [%{source: :task, task_id: "task", delivery: mode}]}

      input =
        submission("image-run", "s1", mode, "look",
          images: images,
          meta: meta,
          request_meta: meta
        )

      state = %SessionState{conversation_key: {:session, "s1"}, active: active}

      assert {:ok, next_state, effects} = SessionTransitions.submit(state, input, 100)
      assert effects == if(is_nil(active), do: [:maybe_start_next], else: [])
      assert next_state.pending_steers == %{}
      assert [queued] = next_state.queue
      assert queued.queue_mode == fallback
      assert queued.run_id == input.run_id
      assert queued.execution_request.run_id == input.run_id
      assert queued.execution_request.prompt == input.execution_request.prompt
      assert queued.execution_request.images == images

      assert [
               %{
                 delivery_receipt: %{
                   requested_mode: ^mode,
                   actual_mode: ^fallback,
                   status: :queued
                 }
               }
             ] =
               queued.meta["async_followups"]

      assert queued.execution_request.meta["async_followups"] == queued.meta["async_followups"]
      assert {:ok, ^next_state, [:noop]} = SessionTransitions.submit(next_state, input, 200)
    end
  end

  test "image auto followups remain queued instead of promotion to text-only steering" do
    images = [%LemonAi.Types.ImageContent{data: "iVBORw0KGgo="}]

    for flag <- [:task_auto_followup, :delegated_auto_followup] do
      meta = %{flag => true}
      input = submission("image-followup", "s1", :followup, "", images: images, meta: meta)

      state = %SessionState{
        conversation_key: {:session, "s1"},
        active: %{run_id: "active", session_key: "s1"}
      }

      assert {:ok, next_state, []} = SessionTransitions.submit(state, input, 100)
      assert next_state.pending_steers == %{}
      assert [queued] = next_state.queue
      assert queued.queue_mode == :followup
      assert queued.run_id == input.run_id
      assert queued.execution_request.images == images
      assert queued.execution_request.prompt == ""

      assert [%{delivery_receipt: %{requested_mode: :followup, actual_mode: :followup}}] =
               queued.meta["async_followups"]
    end
  end

  test "cancel clears queue and pending steers and emits cancel effect when active exists" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :followup, "three"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.cancel(state, :user_requested)

    assert next_state.queue == []
    assert next_state.pending_steers == %{}
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "cancel_session only cancels matching active session and preserves queued work" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "session-a"},
      queue: [
        submission("run2", "session-a", :collect, "two"),
        submission("run3", "session-b", :collect, "three")
      ],
      last_followup_at_ms: nil,
      pending_steers: %{
        "run1" => [
          {submission("run4", "session-a", :followup, "four"), :followup},
          {submission("run5", "session-b", :collect, "five"), :collect}
        ]
      }
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.cancel_session(state, "session-a", :user_requested)

    assert next_state == state
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "abort_session drops queued work and pending steers only for the matching session" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "session-a"},
      queue: [
        submission("run2", "session-a", :collect, "two"),
        submission("run3", "session-b", :collect, "three")
      ],
      last_followup_at_ms: nil,
      pending_steers: %{
        "run1" => [
          {submission("run4", "session-a", :followup, "four"), :followup},
          {submission("run5", "session-b", :collect, "five"), :collect}
        ]
      }
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.abort_session(state, "session-a", :user_requested)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run3"]

    assert next_state.pending_steers == %{
             "run1" => [{submission("run5", "session-b", :collect, "five"), :collect}]
           }

    assert effects == [{:cancel_active, :user_requested}]
  end

  test "active_down clears active, flushes pending steers, and requests next start" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1", pid: self(), mon_ref: make_ref()},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :collect, "three"), :collect}]}
    }

    %{active: %{pid: pid, mon_ref: mon_ref}} = state

    assert {:ok, next_state, effects} = SessionTransitions.active_down(state, pid, mon_ref)

    assert next_state.active == nil
    assert Enum.map(next_state.queue, & &1.run_id) == ["run2", "run3"]
    assert Enum.at(next_state.queue, 1).meta[:suppress_router_phase_events] == true
    assert effects == [:maybe_start_next]
  end

  test "interrupt prepends and emits interrupted cancellation when active exists" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [submission("run2", "s1", :collect, "two")],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    interrupt = submission("run3", "s1", :interrupt, "urgent")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, interrupt, 100)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run3", "run2"]
    assert effects == [{:cancel_active, :interrupted}]
  end

  test "steer against an active run emits a typed dispatch_steer effect" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    steer = submission("run2", "s1", :steer, "two")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, steer, 100)

    assert next_state.pending_steers == %{"run1" => [{steer, :followup}]}
    assert effects == [{:dispatch_steer, "run1", :steer, steer, :followup}]
  end

  test "steer_backlog against an active run emits collect fallback dispatch" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    steer_backlog = submission("run2", "s1", :steer_backlog, "two")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, steer_backlog, 100)

    assert next_state.pending_steers == %{"run1" => [{steer_backlog, :collect}]}

    assert effects == [
             {:dispatch_steer, "run1", :steer_backlog, steer_backlog, :collect}
           ]
  end

  test "redirect against an active run emits a redirect dispatch with followup fallback" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    redirect = submission("run2", "s1", :redirect, "two")

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, redirect, 100)

    assert next_state.pending_steers == %{"run1" => [{redirect, :followup}]}
    assert effects == [{:dispatch_steer, "run1", :redirect, redirect, :followup}]
    assert next_state.queue == []
  end

  test "redirect without an active run degrades to a queued followup" do
    state = SessionState.new(conversation_key: {:session, "s1"})

    assert {:ok, next_state, effects} =
             SessionTransitions.submit(state, submission("run1", "s1", :redirect, "one"), 100)

    assert [queued] = next_state.queue
    assert queued.run_id == "run1"
    assert queued.queue_mode == :followup
    assert next_state.pending_steers == %{}
    assert effects == [:maybe_start_next]
  end

  test "rejected redirect requeues as a followup with router phase events suppressed" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.steer_rejected(state, "run2", 100)

    assert [queued] = next_state.queue
    assert queued.run_id == "run2"
    assert queued.queue_mode == :followup
    assert queued.meta[:suppress_router_phase_events] == true
    assert next_state.pending_steers == %{}
    assert effects == [:maybe_start_next]
  end

  test "failed redirect dispatch requeues as a followup" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.dispatch_steer_failed(state, "run2", 100)

    assert [queued] = next_state.queue
    assert queued.queue_mode == :followup
    assert next_state.pending_steers == %{}
    assert effects == []
  end

  test "accepted redirect clears the pending entry without requeueing" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.steer_accepted(state, "run2")

    assert next_state.queue == []
    assert next_state.pending_steers == %{}
    assert effects == [:noop]
  end

  test "cancel drops pending redirect submissions" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.cancel(state, :user_requested)

    assert next_state.pending_steers == %{}
    assert next_state.queue == []
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "abort_run drops the pending redirect submission it names" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.abort_run(state, "run2", :user_requested)

    assert next_state.pending_steers == %{}
    assert next_state.queue == []
    assert effects == []
  end

  test "abort_session drops pending redirect submissions for the aborted session" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "session-a"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{
        "run1" => [{submission("run2", "session-a", :redirect, "two"), :followup}]
      }
    }

    assert {:ok, next_state, effects} =
             SessionTransitions.abort_session(state, "session-a", :user_requested)

    assert next_state.pending_steers == %{}
    assert effects == [{:cancel_active, :user_requested}]
  end

  test "active_down flushes a pending redirect back into the queue as a followup" do
    pid = self()
    mon_ref = make_ref()

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1", pid: pid, mon_ref: mon_ref},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :redirect, "two"), :followup}]}
    }

    assert {:ok, next_state, effects} = SessionTransitions.active_down(state, pid, mon_ref, 100)

    assert next_state.active == nil
    assert [queued] = next_state.queue
    assert queued.run_id == "run2"
    assert queued.queue_mode == :followup
    assert effects == [:maybe_start_next]
  end

  test "unknown queue modes still coerce to collect while redirect is preserved" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    assert {:ok, redirect_state, [{:dispatch_steer, "run1", :redirect, _, :followup}]} =
             SessionTransitions.submit(state, submission("run2", "s1", :redirect, "two"), 100)

    assert redirect_state.queue == []

    assert {:ok, unknown_state, []} =
             SessionTransitions.submit(state, submission("run3", "s1", :nonsense, "three"), 100)

    assert [queued] = unknown_state.queue
    assert queued.queue_mode == :collect
    assert unknown_state.pending_steers == %{}
  end

  test "active task auto followups are promoted to steer with followup fallback" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    followup =
      submission("run2", "s1", :followup, "task done",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, followup, 100)

    assert [
             {:dispatch_steer, "run1", :steer, dispatched, :followup}
           ] = effects

    assert dispatched.queue_mode == :steer
    assert next_state.pending_steers == %{"run1" => [{dispatched, :followup}]}

    assert [
             %{
               source: :task,
               task_id: "task-a",
               run_id: "run-a",
               delivery: :steer,
               delivery_receipt: %{
                 requested_mode: :followup,
                 actual_mode: :steer,
                 status: :dispatched_to_active,
                 fallback_mode: :followup,
                 active_run_id: "run1",
                 decided_at_ms: decided_at_ms
               }
             }
           ] = dispatched.meta["async_followups"]

    assert is_integer(decided_at_ms)
  end

  test "queued async followups stamp requested and actual delivery receipt" do
    state = SessionState.new(conversation_key: {:session, "s1"})

    followup =
      submission("run1", "s1", :followup, "task done",
        meta: %{
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :followup}
          ]
        },
        request_meta: %{
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :followup}
          ]
        }
      )

    assert {:ok, next_state, [:maybe_start_next]} =
             SessionTransitions.submit(state, followup, 100)

    assert [queued] = next_state.queue

    assert [
             %{
               delivery: :followup,
               delivery_receipt: %{
                 requested_mode: :followup,
                 actual_mode: :followup,
                 status: :queued,
                 decided_at_ms: decided_at_ms
               }
             }
           ] = queued.meta["async_followups"]

    assert is_integer(decided_at_ms)
    refute Map.has_key?(hd(queued.meta["async_followups"]).delivery_receipt, :mode)
    assert queued.execution_request.meta["async_followups"] == queued.meta["async_followups"]
  end

  test "rejected steer fallback requeues and only requests start when resulting state is idle" do
    idle_state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run2", "s1", :steer, "two"), :followup}]}
    }

    assert {:ok, idle_next_state, idle_effects} =
             SessionTransitions.dispatch_steer_failed(idle_state, "run2", 100)

    assert Enum.map(idle_next_state.queue, & &1.run_id) == ["run2"]
    assert hd(idle_next_state.queue).meta[:suppress_router_phase_events] == true
    assert idle_next_state.pending_steers == %{}
    assert idle_effects == [:maybe_start_next]

    busy_state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "run1", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{"run1" => [{submission("run3", "s1", :steer, "three"), :followup}]}
    }

    assert {:ok, busy_next_state, busy_effects} =
             SessionTransitions.dispatch_steer_failed(busy_state, "run3", 100)

    assert Enum.map(busy_next_state.queue, & &1.run_id) == ["run3"]
    assert busy_effects == []
  end

  test "regular followups keep scalar metadata merge behavior" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_id: "first", run_id: "run1", source: "left", keep: "left"},
        request_meta: %{task_id: "first", run_id: "run1", source: "left", keep: "left"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_id: "second", source: "right", extra: "right"},
        request_meta: %{task_id: "second", source: "right", extra: "right"}
      )

    merged = merge_followups(previous, current)

    assert merged.execution_request.prompt == "part1\npart2"

    assert merged.meta == %{
             task_id: "second",
             run_id: "run1",
             source: "right",
             keep: "left",
             extra: "right"
           }

    assert merged.execution_request.meta == %{
             task_id: "second",
             run_id: "run1",
             source: "right",
             keep: "left",
             extra: "right"
           }
  end

  test "two async followups stay separate within the debounce window" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.task_id == "task-a"
    assert Enum.at(next_state.queue, 1).meta.task_id == "task-b"
  end

  test "async task followups do not merge within the debounce window" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [previous],
      last_followup_at_ms: 100,
      pending_steers: %{}
    }

    assert {:ok, next_state, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
  end

  test "async delegated followups do not merge with regular followups" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a",
          left: "value"
        },
        request_meta: %{
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a",
          left: "value"
        }
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{kind: "regular", right: "value"},
        request_meta: %{kind: "regular", right: "value"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.left == "value"
    assert Enum.at(next_state.queue, 1).meta.kind == "regular"
    assert Enum.at(next_state.queue, 1).meta.right == "value"
  end

  test "async followups with duplicate task ids and nil values still stay separate" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: nil},
        request_meta: %{}
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-b"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]
    assert Enum.at(next_state.queue, 0).meta.run_id == nil
    assert Enum.at(next_state.queue, 1).meta.run_id == "run-b"
  end

  test "third async followup appends as a third queued followup" do
    first =
      submission("run1", "s1", :followup, "part1",
        meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"},
        request_meta: %{task_auto_followup: true, task_id: "task-a", run_id: "run-a"}
      )

    second =
      submission("run2", "s1", :followup, "part2",
        meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"},
        request_meta: %{task_auto_followup: true, task_id: "task-b", run_id: "run-b"}
      )

    first_state = submit_followups(first, second)

    third =
      submission("run3", "s1", :followup, "part3",
        meta: %{task_auto_followup: true, task_id: "task-c", run_id: "run-c"},
        request_meta: %{task_auto_followup: true, task_id: "task-c", run_id: "run-c"}
      )

    assert {:ok, next_state, [:maybe_start_next]} =
             SessionTransitions.submit(first_state, third, 300)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2", "run3"]
  end

  test "explicit async_followups metadata also prevents merge with later regular followups" do
    previous =
      submission("run1", "s1", :followup, "part1",
        meta: %{
          "async_followups" => [
            %{
              source: :agent,
              task_id: "task-a",
              run_id: "run-a",
              agent_id: "agent-a",
              session_key: "session-a",
              delivery: :router
            }
          ],
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a"
        },
        request_meta: %{
          "async_followups" => [
            %{
              source: :agent,
              task_id: "task-a",
              run_id: "run-a",
              agent_id: "agent-a",
              session_key: "session-a",
              delivery: :router
            }
          ],
          delegated_auto_followup: true,
          delegated_task_id: "task-a",
          delegated_run_id: "run-a",
          delegated_agent_id: "agent-a",
          delegated_session_key: "session-a"
        }
      )

    current =
      submission("run2", "s1", :followup, "part2",
        meta: %{kind: "regular"},
        request_meta: %{kind: "regular"}
      )

    next_state = submit_followups(previous, current)

    assert Enum.map(next_state.queue, & &1.run_id) == ["run1", "run2"]

    assert Enum.at(next_state.queue, 0).meta["async_followups"] == [
             %{
               source: :agent,
               task_id: "task-a",
               run_id: "run-a",
               agent_id: "agent-a",
               session_key: "session-a",
               delivery: :router
             }
           ]
  end

  test "async followup delivery receipt reflects active-run steer promotion" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "active-run", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    followup =
      submission("run2", "s1", :followup, "task done",
        meta: %{
          :task_auto_followup => true,
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :followup}
          ]
        },
        request_meta: %{
          :task_auto_followup => true,
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :followup}
          ]
        }
      )

    assert {:ok, next_state, effects} = SessionTransitions.submit(state, followup, 100)

    assert [
             {:dispatch_steer, "active-run", :steer, dispatched, :followup}
           ] = effects

    assert next_state.pending_steers == %{"active-run" => [{dispatched, :followup}]}

    assert [
             %{
               delivery: :steer,
               delivery_receipt: %{
                 requested_mode: :followup,
                 actual_mode: :steer,
                 status: :dispatched_to_active,
                 fallback_mode: :followup,
                 active_run_id: "active-run",
                 decided_at_ms: decided_at_ms
               }
             }
           ] = dispatched.meta["async_followups"]

    assert is_integer(decided_at_ms)

    assert dispatched.execution_request.meta["async_followups"] ==
             dispatched.meta["async_followups"]
  end

  test "fallback queued async followups preserve requested delivery and stamp fallback status" do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: %{run_id: "active-run", session_key: "s1"},
      queue: [],
      last_followup_at_ms: nil,
      pending_steers: %{}
    }

    steer =
      submission("run2", "s1", :steer, "task done",
        meta: %{
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :steer}
          ]
        },
        request_meta: %{
          "async_followups" => [
            %{source: :task, task_id: "task-a", run_id: "child-run", delivery: :steer}
          ]
        }
      )

    assert {:ok, pending_state, _effects} = SessionTransitions.submit(state, steer, 100)

    assert {:ok, next_state, []} =
             SessionTransitions.dispatch_steer_failed(pending_state, "run2", 200)

    assert [queued] = next_state.queue

    assert [
             %{
               delivery: :followup,
               delivery_receipt: %{
                 requested_mode: :steer,
                 actual_mode: :followup,
                 status: :fallback_queued,
                 fallback_mode: :followup,
                 active_run_id: "active-run",
                 decided_at_ms: decided_at_ms
               }
             }
           ] = queued.meta["async_followups"]

    assert is_integer(decided_at_ms)
    assert queued.execution_request.meta["async_followups"] == queued.meta["async_followups"]
  end

  test "different active contexts collect every control without steering or cancellation" do
    contexts = [
      {%{invocation_context_key: "a"}, %{invocation_context_key: "b"}, nil, nil},
      {%{}, %{invocation_context_key: "b"}, nil, nil},
      {%{invocation_context_key: "a"}, %{}, nil, nil},
      {%{invocation_context_key: "same", memory_context_key: "private"},
       %{invocation_context_key: "same", memory_context_key: "shared"}, nil, nil},
      {%{memory_context_key: "private"}, %{}, nil, nil},
      {%{invocation_context_key: "same", memory_context_key: "room", memory_context_verified: true},
       %{invocation_context_key: "same", memory_context_key: "room"}, nil, nil},
      {%{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: true},
       %{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: false}, nil, nil},
      {%{}, %{}, %{deny: ["bash"]}, %{deny: ["read"]}},
      {%{invocation_context_key: "a"}, %{invocation_context_key: "a"}, %{}, %{deny: ["bash"]}},
      {%{mcp_servers: [%{url: "https://mcp.invalid", secret_ref: "a"}]},
       %{mcp_servers: []}, nil, nil},
      {%{}, %{mcp_servers: []}, nil, nil}
    ]

    for {active_meta, incoming_meta, active_policy, incoming_policy} <- contexts,
        mode <- [:followup, :steer, :steer_backlog, :redirect, :interrupt] do
      active = context_submission("active", :collect, active_meta, active_policy)
      queued = context_submission("queued", :collect, active_meta, active_policy)
      incoming = context_submission("own", mode, incoming_meta, incoming_policy)
      state = %SessionState{active: %{run_id: "active", submission: active}, queue: [queued]}

      assert {:ok, next, []} = SessionTransitions.submit(state, incoming, 100)
      assert next.active == state.active
      assert next.pending_steers == %{}
      assert next.merged_run_ids == %{}
      assert [^queued, own] = next.queue
      assert own.queue_mode == :collect
      assert own.execution_request == incoming.execution_request
    end
  end

  test "same keyed and legacy contexts preserve active control and followup semantics" do
    for meta <- [%{}, %{invocation_context_key: "same", mcp_servers: []}] do
      active = context_submission("active", :collect, meta, %{deny: ["bash"]})
      state = %SessionState{active: %{run_id: "active", submission: active}}

      for {mode, fallback} <- [steer: :followup, steer_backlog: :collect, redirect: :followup] do
        input = context_submission("control", mode, meta, %{deny: ["bash"]})
        assert {:ok, next, [{:dispatch_steer, "active", ^mode, _, ^fallback}]} =
                 SessionTransitions.submit(state, input, 100)
        assert next.queue == []
      end

      input = context_submission("interrupt", :interrupt, meta, %{deny: ["bash"]})
      assert {:ok, next, [{:cancel_active, :interrupted}]} =
               SessionTransitions.submit(state, input, 100)
      assert [^input] = next.queue

      first = context_submission("first", :followup, meta, %{deny: ["bash"]})
      second = context_submission("second", :followup, meta, %{deny: ["bash"]})
      assert {:ok, next, []} = SessionTransitions.submit(state, first, 100)
      assert {:ok, merged, []} = SessionTransitions.submit(next, second, 200)
      assert [owner] = merged.queue
      assert owner.run_id == "second"
      assert owner.execution_request.prompt == "first\nsecond"
    end
  end

  test "debounce and rejected-steer fallback never merge different execution contexts" do
    for {left, right, left_policy, right_policy} <- [
          {%{invocation_context_key: "a"}, %{invocation_context_key: "b"}, nil, nil},
          {%{}, %{invocation_context_key: "b"}, nil, nil},
          {%{invocation_context_key: "a"}, %{}, nil, nil},
          {%{invocation_context_key: "same", memory_context_key: "private"},
           %{invocation_context_key: "same", memory_context_key: "shared"}, nil, nil},
          {%{memory_context_key: "private"}, %{}, nil, nil},
          {%{invocation_context_key: "same", memory_context_key: "room", memory_context_verified: true},
           %{invocation_context_key: "same", memory_context_key: "room"}, nil, nil},
          {%{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: true},
           %{invocation_context_key: "same", memory_context_key: "room", shared_memory_grant: false}, nil, nil},
          {%{}, %{}, %{deny: ["bash"]}, %{}},
          {%{mcp_servers: [%{secret_ref: "a"}]}, %{mcp_servers: [%{secret_ref: "b"}]},
           nil, nil},
          {%{}, %{mcp_servers: []}, nil, nil}
        ] do
      previous = context_submission("first", :followup, left, left_policy)
      current = context_submission("second", :followup, right, right_policy)
      state = %SessionState{queue: [previous], last_followup_at_ms: 100}

      assert {:ok, next, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
      assert Enum.map(next.queue, & &1.run_id) == ["first", "second"]
      assert Enum.map(next.queue, & &1.execution_request.prompt) == ["first", "second"]
      assert next.merged_run_ids == %{}

      pending = %SessionState{
        state
        | active: %{run_id: "active"},
          pending_steers: %{"active" => [{%{current | queue_mode: :steer}, :followup}]}
      }

      assert {:ok, fallback, []} = SessionTransitions.steer_rejected(pending, "second", 200)
      assert Enum.map(fallback.queue, & &1.run_id) == ["first", "second"]
      assert Enum.map(fallback.queue, & &1.execution_request.prompt) == ["first", "second"]
      assert fallback.merged_run_ids == %{}
    end
  end

  test "automatic followups and recovered unknown active pointers cannot bypass context isolation" do
    for active <- [
          %{run_id: "active"},
          %{run_id: "active", submission: context_submission("active", :collect, %{}, nil)}
        ],
        flag <- [:task_auto_followup, :delegated_auto_followup] do
      input =
        context_submission("own", :followup, %{flag => true, :invocation_context_key => "new"}, nil)
      state = %SessionState{active: active}
      assert {:ok, next, []} = SessionTransitions.submit(state, input, 100)
      assert next.pending_steers == %{}
      assert [own] = next.queue
      assert own.run_id == "own"
      assert own.queue_mode == :collect
    end
  end

  defp context_submission(id, mode, meta, policy) do
    input = submission(id, "s1", mode, id, meta: meta, request_meta: meta)
    %{input | execution_request: %{input.execution_request | tool_policy: policy}}
  end

  defp merge_followups(previous, current) do
    next_state = submit_followups(previous, current)
    assert [merged] = next_state.queue
    merged
  end

  defp submit_followups(previous, current) do
    state = %SessionState{
      conversation_key: {:session, "s1"},
      active: nil,
      queue: [previous],
      last_followup_at_ms: 100,
      pending_steers: %{}
    }

    assert {:ok, next_state, [:maybe_start_next]} = SessionTransitions.submit(state, current, 200)
    next_state
  end

  defp submission(run_id, session_key, queue_mode, prompt, opts \\ []) do
    request = %ExecutionCommand{
      run_id: run_id,
      session_key: session_key,
      prompt: prompt,
      images: Keyword.get(opts, :images, []),
      conversation_key: {:session, session_key},
      meta: Keyword.get(opts, :request_meta, %{})
    }

    Submission.new!(%{
      run_id: run_id,
      session_key: session_key,
      conversation_key: {:session, session_key},
      queue_mode: queue_mode,
      execution_request: request,
      run_process_opts: %{},
      meta: Keyword.get(opts, :meta, %{})
    })
  end
end
