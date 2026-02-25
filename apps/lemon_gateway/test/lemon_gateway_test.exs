defmodule LemonGatewayTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case

  alias Elixir.LemonGateway.Event.Completed
  alias Elixir.LemonGateway.Types.Job

  setup do
    # Isolate Telegram poller file locks from any locally running gateway process (and from other tests).
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    on_exit(fn ->
      System.delete_env("LEMON_LOCK_DIR")
      _ = File.rm_rf(lock_dir)
    end)

    :ok
  end

  defmodule LemonGatewayTest.CrashEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias LemonCore.ResumeToken
    alias LemonGateway.Types.Job
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "crash"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "crash resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "crash"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.exit(sink_pid, :kill)
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule ErrorEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias LemonCore.ResumeToken
    alias LemonGateway.Types.Job
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "error"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "error resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid) do
      {:error, :boom}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule ActionEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias LemonCore.ResumeToken
    alias LemonGateway.Types.Job
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "action"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "action resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "action"}
      action = %Event.Action{id: "step-1", kind: "work", title: "Step 1"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action, phase: :started}}
        )

        send(
          sink_pid,
          {:engine_event, run_ref, %Event.Completed{engine: id(), ok: true, answer: "result"}}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule LemonGatewayTest.StreamingEngine do
    @moduledoc "Test engine that emits multiple action events to test streaming edits"
    @behaviour Elixir.LemonGateway.Engine

    alias LemonCore.ResumeToken
    alias LemonGateway.Types.Job
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "streaming"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "streaming resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "streaming"}
      action1 = %Event.Action{id: "step-1", kind: "work", title: "Step 1"}
      action2 = %Event.Action{id: "step-2", kind: "work", title: "Step 2"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action1, phase: :started}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action1, phase: :completed}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action2, phase: :started}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action2, phase: :completed}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.Completed{engine: id(), ok: true, answer: "done streaming"}}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      Elixir.LemonGateway.Engines.Echo,
      LemonGatewayTest.CrashEngine,
      ErrorEngine,
      ActionEngine,
      LemonGatewayTest.StreamingEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "submits a job and receives completion" do
    session_key = "test:1"

    job = %Job{
      session_key: session_key,
      prompt: "hello",
      resume: nil,
      engine_id: nil,
      meta: %{notify_pid: self(), user_msg_id: 1}
    }

    Elixir.LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job,
                    %Completed{ok: true, answer: "Echo: hello"}},
                   1_000
  end

  test "scheduler releases slot after worker death" do
    parent = self()

    _worker_a =
      spawn(fn ->
        Elixir.LemonGateway.Scheduler.request_slot(self(), :thread_a)

        receive do
          {:slot_granted, _slot_ref} ->
            send(parent, :worker_a_granted)
            Process.exit(self(), :kill)
        end
      end)

    worker_b =
      spawn(fn ->
        Elixir.LemonGateway.Scheduler.request_slot(self(), :thread_b)

        receive do
          {:slot_granted, _slot_ref} ->
            send(parent, :worker_b_granted)
        end
      end)

    assert_receive :worker_a_granted, 1_000
    assert_receive :worker_b_granted, 1_000

    Process.exit(worker_b, :kill)
  end

  test "thread worker frees slot when run crashes" do
    session_key = "test:2"

    crash_job = %Job{
      session_key: session_key,
      prompt: "boom",
      resume: nil,
      engine_id: "crash",
      meta: %{notify_pid: self(), user_msg_id: 10}
    }

    ok_job = %Job{
      session_key: session_key,
      prompt: "ok",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 11}
    }

    Elixir.LemonGateway.submit(crash_job)
    Elixir.LemonGateway.submit(ok_job)

    assert_receive {:lemon_gateway_run_completed, ^ok_job,
                    %Completed{ok: true, answer: "Echo: ok"}},
                   2_000
  end

  test "scheduler handles back-to-back submits for same thread" do
    session_key = "test:3"

    job1 = %Job{
      session_key: session_key,
      prompt: "first",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 20}
    }

    job2 = %Job{
      session_key: session_key,
      prompt: "second",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 21}
    }

    Task.async(fn -> Elixir.LemonGateway.submit(job1) end)
    Task.async(fn -> Elixir.LemonGateway.submit(job2) end)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %Completed{ok: true, answer: "Echo: first"}},
                   2_000

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %Completed{ok: true, answer: "Echo: second"}},
                   2_000
  end

  test "scheduler re-creates worker after idle stop" do
    session_key = "test:4"

    job1 = %Job{
      session_key: session_key,
      prompt: "one",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 30}
    }

    job2 = %Job{
      session_key: session_key,
      prompt: "two",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 31}
    }

    Elixir.LemonGateway.submit(job1)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %Completed{ok: true, answer: "Echo: one"}},
                   2_000

    # Allow worker to stop when idle.
    Process.sleep(50)

    Elixir.LemonGateway.submit(job2)

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %Completed{ok: true, answer: "Echo: two"}},
                   2_000
  end

  test "engine start error still notifies completion" do
    session_key = "test:5"

    job = %Job{
      session_key: session_key,
      prompt: "fail",
      resume: nil,
      engine_id: "error",
      meta: %{notify_pid: self(), user_msg_id: 40}
    }

    Elixir.LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: false}}, 1_000
  end

end
