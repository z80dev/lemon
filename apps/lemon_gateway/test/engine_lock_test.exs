defmodule LemonGateway.EngineLockTest do
  use ExUnit.Case

  alias LemonGateway.Event.Completed
  alias LemonGateway.Types.{ChatScope, Job, ResumeToken}

  defmodule SlowEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "slow"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "slow resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "slow-session"}
      delay = job.meta[:delay_ms] || 100

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.sleep(delay)
        send(sink_pid, {:engine_event, run_ref, %Event.Completed{engine: id(), ok: true, answer: "slow done"}})
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule CrashEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

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
        # Kill the Run process to simulate a crash
        Process.exit(sink_pid, :kill)
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: true,
      engine_lock_timeout_ms: 60_000
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "lock is acquired and released during normal run" do
    scope = %ChatScope{transport: :test, chat_id: 100, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "test",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)
    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 1_000

    # Wait a bit for lock release to propagate (cast is async)
    Process.sleep(50)

    # Lock should be released - another job for same scope should proceed immediately
    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "test2",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job2)
    assert_receive {:lemon_gateway_run_completed, ^job2, %Completed{ok: true}}, 1_000
  end

  test "concurrent runs for same scope are serialized by lock" do
    scope = %ChatScope{transport: :test, chat_id: 101, topic_id: nil}

    job1 = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "first",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "second",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 50}
    }

    # Submit both concurrently
    Task.async(fn -> LemonGateway.submit(job1) end)
    Process.sleep(10)
    Task.async(fn -> LemonGateway.submit(job2) end)

    # Jobs should complete in order due to locking
    completions = collect_completions(2, 2_000)

    assert length(completions) == 2
    # First job submitted should complete first due to lock serialization
    [{first_job, _}, {second_job, _}] = completions
    assert first_job.text == "first"
    assert second_job.text == "second"
  end

  test "concurrent runs for different scopes proceed in parallel" do
    scope1 = %ChatScope{transport: :test, chat_id: 102, topic_id: nil}
    scope2 = %ChatScope{transport: :test, chat_id: 103, topic_id: nil}

    job1 = %Job{
      scope: scope1,
      user_msg_id: 1,
      text: "scope1",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope2,
      user_msg_id: 2,
      text: "scope2",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Both should complete in roughly parallel time (not serialized)
    # If serialized, would take ~200ms+; parallel should be ~100ms
    elapsed = t_end - t_start
    assert elapsed < 180, "Expected parallel execution, got #{elapsed}ms"
  end

  test "lock uses resume token value as key when present" do
    scope1 = %ChatScope{transport: :test, chat_id: 104, topic_id: nil}
    scope2 = %ChatScope{transport: :test, chat_id: 105, topic_id: nil}
    resume = %ResumeToken{engine: "slow", value: "shared-session-123"}

    # Two jobs with different scopes but same resume token should be serialized
    job1 = %Job{
      scope: scope1,
      user_msg_id: 1,
      text: "resume1",
      resume: resume,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope2,
      user_msg_id: 2,
      text: "resume2",
      resume: resume,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 50}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Process.sleep(10)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Should be serialized despite different scopes
    elapsed = t_end - t_start
    assert elapsed >= 140, "Expected serialized execution due to shared resume token, got #{elapsed}ms"
  end

  test "lock is released when run process crashes" do
    # Restart app with crash engine included
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: true,
      engine_lock_timeout_ms: 60_000
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine,
      CrashEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 106, topic_id: nil}

    crash_job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "crash",
      resume: nil,
      engine_hint: "crash",
      meta: %{notify_pid: self()}
    }

    ok_job = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "ok",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    # Submit crash job first, then ok job
    LemonGateway.submit(crash_job)
    Process.sleep(50)
    LemonGateway.submit(ok_job)

    # The ok_job should complete even after crash_job's process dies
    # because EngineLock monitors the process and releases on :DOWN
    assert_receive {:lemon_gateway_run_completed, ^ok_job, %Completed{ok: true}}, 2_000
  end

  test "lock can be disabled via config" do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      default_engine: "echo",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      SlowEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 107, topic_id: nil}

    # With locking disabled, two jobs for same scope should run in parallel
    job1 = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "no-lock-1",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 2,
      text: "no-lock-2",
      resume: nil,
      engine_hint: "slow",
      meta: %{notify_pid: self(), delay_ms: 100}
    }

    t_start = System.monotonic_time(:millisecond)

    Task.async(fn -> LemonGateway.submit(job1) end)
    Task.async(fn -> LemonGateway.submit(job2) end)

    completions = collect_completions(2, 2_000)
    t_end = System.monotonic_time(:millisecond)

    assert length(completions) == 2
    # Without locking, should be parallel (allow some overhead for test/CI)
    elapsed = t_end - t_start
    assert elapsed < 250, "Expected parallel execution without locking, got #{elapsed}ms"
  end

  defp collect_completions(count, timeout) do
    collect_completions(count, timeout, [])
  end

  defp collect_completions(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect_completions(count, timeout, acc) do
    receive do
      {:lemon_gateway_run_completed, job, completed} ->
        collect_completions(count - 1, timeout, [{job, completed} | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
