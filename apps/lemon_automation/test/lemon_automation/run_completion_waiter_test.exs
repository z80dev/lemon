defmodule LemonAutomation.RunCompletionWaiterTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.RunCompletionWaiter

  defmodule TestBus do
    @moduledoc false

    def subscribe(topic) do
      if pid = Process.get(:run_completion_waiter_test_pid) do
        send(pid, {:bus_subscribed, topic})
      end

      :ok
    end

    def unsubscribe(topic) do
      if pid = Process.get(:run_completion_waiter_test_pid) do
        send(pid, {:bus_unsubscribed, topic})
      end

      :ok
    end
  end

  defmodule InlineCompletionRouter do
    @moduledoc false

    def submit(params) do
      send(
        self(),
        LemonCore.Event.new(:run_completed, %{
          completed: %{ok: true, answer: "completed during submit"}
        })
      )

      {:ok, params.run_id}
    end
  end

  defmodule ClaimAwareRouter do
    @moduledoc false

    def submit(params) do
      send(params.test_pid, {:router_submit_started, params.run_id})

      send(
        self(),
        LemonCore.Event.new(:run_completed, %{
          completed: %{ok: true, answer: "claimed and completed"}
        })
      )

      {:ok, params.run_id}
    end
  end

  defmodule WaiterAmbiguousRouter do
    @moduledoc false

    def submit(params) do
      send(params.test_pid, {:ambiguous_submit, params.run_id})
      {:error, :outcome_unknown}
    end
  end

  defmodule AcceptedWithoutCompletionRouter do
    @moduledoc false
    def submit(params), do: {:ok, params.run_id}
  end

  defmodule CrashingWaiter do
    @moduledoc false

    def wait_already_subscribed(_run_id, _timeout_ms, opts) do
      case opts[:failure] do
        :raise -> raise "waiter crashed"
        :exit -> exit(:waiter_crashed)
      end
    end
  end

  defmodule MutateThenRaiseRouter do
    @moduledoc false

    def submit(params) do
      send(params.test_pid, {:submit_side_effect, params.run_id})
      raise "ack lost"
    end
  end

  test "submit_and_wait/2 observes synchronous completion and removes its subscription" do
    Process.put(:run_completion_waiter_test_pid, self())

    assert {:ok, "run_sync", "completed during submit"} =
             RunCompletionWaiter.submit_and_wait(%{run_id: "run_sync", prompt: "now"},
               router_mod: InlineCompletionRouter,
               bus_mod: TestBus,
               timeout_ms: 10
             )

    assert_received {:bus_subscribed, "run:run_sync"}
    assert_received {:bus_unsubscribed, "run:run_sync"}
    refute_received %LemonCore.Event{type: :run_completed}
  end

  test "submission ownership is claimed before the router can accept the fixed run id" do
    Process.put(:run_completion_waiter_test_pid, self())
    test_pid = self()

    assert {:ok, "run_claimed", "claimed and completed"} =
             RunCompletionWaiter.submit_and_wait(
               %{run_id: "run_claimed", prompt: "now", test_pid: test_pid},
               router_mod: ClaimAwareRouter,
               bus_mod: TestBus,
               timeout_ms: 10,
               on_submitting: fn run_id ->
                 send(test_pid, {:submission_claimed, run_id})
                 :ok
               end
             )

    assert_received {:submission_claimed, "run_claimed"}
    assert_received {:router_submit_started, "run_claimed"}
  end

  test "a rejected ownership claim prevents router submission" do
    Process.put(:run_completion_waiter_test_pid, self())

    assert {:error, {:submit_failed, {:submission_claim_rejected, :stopped}}} =
             RunCompletionWaiter.submit_and_wait(
               %{run_id: "run_rejected_claim", prompt: "never submit", test_pid: self()},
               router_mod: ClaimAwareRouter,
               bus_mod: TestBus,
               on_submitting: fn _run_id -> {:error, :stopped} end
             )

    refute_received {:router_submit_started, "run_rejected_claim"}
    assert_received {:bus_unsubscribed, "run:run_rejected_claim"}
  end

  test "an ambiguous submission waits on the fixed id and retains an unknown outcome on timeout" do
    Process.put(:run_completion_waiter_test_pid, self())

    assert {:error, {:submission_outcome_unknown, "run_ambiguous"}} =
             RunCompletionWaiter.submit_and_wait(
               %{run_id: "run_ambiguous", prompt: "maybe accepted", test_pid: self()},
               router_mod: WaiterAmbiguousRouter,
               bus_mod: TestBus,
               timeout_ms: 10
             )

    assert_received {:ambiguous_submit, "run_ambiguous"}
    assert_received {:bus_subscribed, "run:run_ambiguous"}
    assert_received {:bus_unsubscribed, "run:run_ambiguous"}
  end

  test "a submit exception is ambiguous and retains the fixed run ownership" do
    assert {:error, {:submission_outcome_unknown, "run_raise"}} =
             RunCompletionWaiter.submit_and_wait(
               %{run_id: "run_raise", prompt: "maybe accepted", test_pid: self()},
               router_mod: MutateThenRaiseRouter,
               timeout_ms: 1
             )

    assert_received {:submit_side_effect, "run_raise"}
  end

  test "an accepted run timeout retains ownership and does not announce terminal" do
    assert {:error, {:completion_outcome_unknown, "run_still_live"}} =
             RunCompletionWaiter.submit_and_wait(
               %{run_id: "run_still_live", prompt: "still running"},
               router_mod: AcceptedWithoutCompletionRouter,
               timeout_ms: 1,
               on_terminal: fn run_id -> send(self(), {:terminal, run_id}) end
             )

    refute_received {:terminal, "run_still_live"}
  end

  test "a waiter exception after acceptance retains ownership and does not announce terminal" do
    test_pid = self()

    for failure <- [:raise, :exit] do
      run_id = "run_waiter_#{failure}"

      assert {:error, {:completion_outcome_unknown, ^run_id}} =
               RunCompletionWaiter.submit_and_wait(
                 %{run_id: run_id, prompt: "accepted before waiter crash"},
                 router_mod: AcceptedWithoutCompletionRouter,
                 waiter_mod: CrashingWaiter,
                 wait_opts: [failure: failure],
                 on_terminal: fn terminal_run_id ->
                   send(test_pid, {:terminal, terminal_run_id})
                 end
               )

      refute_received {:terminal, ^run_id}
    end
  end

  test "wait/3 subscribes, extracts completion output, and unsubscribes" do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:run_completion_waiter_test_pid, parent)
        RunCompletionWaiter.wait("run_waiter_ok", 1_000, bus_mod: TestBus)
      end)

    assert_receive {:bus_subscribed, "run:run_waiter_ok"}, 500

    send(
      task.pid,
      LemonCore.Event.new(:run_completed, %{completed: %{ok: true, answer: "Hello from waiter"}})
    )

    assert {:ok, "Hello from waiter"} = Task.await(task, 2_000)
    assert_receive {:bus_unsubscribed, "run:run_waiter_ok"}, 500
  end

  test "wait/3 returns :timeout and unsubscribes when no completion is received" do
    parent = self()

    task =
      Task.async(fn ->
        Process.put(:run_completion_waiter_test_pid, parent)
        RunCompletionWaiter.wait("run_waiter_timeout", 20, bus_mod: TestBus)
      end)

    assert_receive {:bus_subscribed, "run:run_waiter_timeout"}, 500
    assert :timeout = Task.await(task, 1_000)
    assert_receive {:bus_unsubscribed, "run:run_waiter_timeout"}, 500
  end

  test "extract_output_from_completion/1 truncates oversized output" do
    long_text = String.duplicate("a", 1_200)

    assert {:ok, output} =
             RunCompletionWaiter.extract_output_from_completion(%{answer: long_text})

    assert byte_size(output) == 1_000
  end
end
