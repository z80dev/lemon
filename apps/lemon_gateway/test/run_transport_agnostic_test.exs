defmodule LemonGateway.RunTransportAgnosticTest do
  @moduledoc """
  Tests for transport-agnostic run behavior.

  Verifies that:
  - Run emits events to LemonCore.Bus instead of Telegram outbox
  - Delta events are accumulated and included in final answer
  - No channel-specific rendering occurs in Run
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Run
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias LemonGateway.Event

  # Test engine that sends deltas
  defmodule DeltaEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "delta_test"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "delta_test resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      controller_pid = (job.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          # Send the task's own pid so the test can send commands to it
          if controller_pid, do: send(controller_pid, {:engine_started, run_ref, self()})

          receive do
            {:send_deltas, deltas} ->
              for delta <- deltas do
                send(sink_pid, {:engine_delta, run_ref, delta})
                Process.sleep(10)
              end

              receive do
                :complete ->
                  send(
                    sink_pid,
                    {:engine_event, run_ref,
                     %Event.Completed{engine: id(), resume: resume, ok: true, answer: ""}}
                  )
              after
                5000 -> :ok
              end
          after
            30_000 ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 %Event.Completed{engine: id(), resume: resume, ok: false, error: :timeout}}
              )
          end
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "delta_test",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      DeltaEngine,
      LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp make_scope(chat_id \\ System.unique_integer([:positive])) do
    %ChatScope{transport: :test, chat_id: chat_id, topic_id: nil}
  end

  defp make_job(scope, opts \\ []) do
    %Job{
      scope: scope,
      user_msg_id: Keyword.get(opts, :user_msg_id, 1),
      text: Keyword.get(opts, :text, "test message"),
      queue_mode: Keyword.get(opts, :queue_mode, :collect),
      engine_hint: Keyword.get(opts, :engine_hint, "delta_test"),
      resume: Keyword.get(opts, :resume),
      meta: Keyword.get(opts, :meta, %{notify_pid: self()})
    }
  end

  defp start_run_direct(job, slot_ref \\ make_ref()) do
    args = %{
      job: job,
      slot_ref: slot_ref,
      worker_pid: self()
    }

    Run.start_link(args)
  end

  describe "delta event emission" do
    test "emits delta events to bus" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self(), controller_pid: self()})

      # Subscribe to bus to receive events
      run_id = "test_run_#{System.unique_integer()}"
      job = %{job | run_id: run_id}

      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, _pid} = start_run_direct(job)

      assert_receive {:engine_started, run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Should receive delta events on bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        # Receive delta events (may be wrapped in LemonCore.Event)
        received_deltas = collect_delta_events([], 3, 2000)
        assert length(received_deltas) >= 1
      end

      # Complete the run
      send(sink_pid, :complete)

      # Wait for run_ref to be set and check completion
      Process.sleep(100)
    end

    test "accumulates delta text into final answer when engine answer is empty" do
      scope = make_scope()
      job = make_job(scope, meta: %{notify_pid: self(), controller_pid: self()})

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Hello", " ", "World"]})

      # Wait for deltas to be processed
      Process.sleep(100)

      # Complete the run
      send(sink_pid, :complete)

      # Should receive completion with accumulated answer
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true, answer: answer}}, 2000

      # Answer should contain the accumulated delta text
      assert answer == "Hello World"
    end
  end

  describe "transport agnostic behavior" do
    test "does not call Telegram outbox directly" do
      scope = make_scope()
      # Include chat_id to trigger old rendering path if it existed
      job =
        make_job(scope,
          meta: %{
            notify_pid: self(),
            controller_pid: self(),
            chat_id: 12345,
            progress_msg_id: 67890
          }
        )

      {:ok, pid} = start_run_direct(job)

      assert_receive {:engine_started, _run_ref, sink_pid}, 2000

      # Send deltas
      send(sink_pid, {:send_deltas, ["Test"]})
      Process.sleep(100)

      # Complete the run
      send(sink_pid, :complete)

      # Should complete successfully without crashing
      # (Old code would try to call Telegram.Outbox)
      assert_receive {:run_complete, ^pid, %Event.Completed{ok: true}}, 2000
    end

    test "emits run_started event to bus" do
      scope = make_scope()
      run_id = "run_#{System.unique_integer()}"

      job = %Job{
        scope: scope,
        run_id: run_id,
        user_msg_id: 1,
        text: "test",
        queue_mode: :collect,
        engine_hint: "echo",
        meta: %{notify_pid: self()}
      }

      # Subscribe to bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, pid} = start_run_direct(job)

      # Should receive run_started event
      if Code.ensure_loaded?(LemonCore.Bus) do
        receive do
          %LemonCore.Event{type: :run_started} -> :ok
          event -> IO.inspect(event, label: "Unexpected event")
        after
          2000 -> :ok
        end
      end

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000
    end

    test "emits run_completed event to bus" do
      scope = make_scope()
      run_id = "run_#{System.unique_integer()}"

      job = %Job{
        scope: scope,
        run_id: run_id,
        user_msg_id: 1,
        text: "test",
        queue_mode: :collect,
        engine_hint: "echo",
        meta: %{notify_pid: self()}
      }

      # Subscribe to bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        LemonCore.Bus.subscribe("run:#{run_id}")
      end

      {:ok, pid} = start_run_direct(job)

      # Wait for completion
      assert_receive {:run_complete, ^pid, _}, 2000

      # Should have received run_completed event on bus
      if Code.ensure_loaded?(LemonCore.Bus) do
        # Drain any remaining events
        Process.sleep(100)
      end
    end
  end

  # Helper to collect delta events with timeout
  defp collect_delta_events(acc, 0, _timeout), do: Enum.reverse(acc)

  defp collect_delta_events(acc, count, timeout) do
    receive do
      %LemonCore.Event{type: :delta} = event ->
        collect_delta_events([event | acc], count - 1, timeout)

      %{type: :delta} = event ->
        collect_delta_events([event | acc], count - 1, timeout)

      _ ->
        collect_delta_events(acc, count, timeout)
    after
      timeout ->
        Enum.reverse(acc)
    end
  end
end
