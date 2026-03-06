defmodule LemonGateway.ThreadWorkerTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.ThreadWorker
  alias LemonGateway.Types.Job
  alias LemonCore.ResumeToken

  defmodule ThreadWorkerSlowEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Event
    alias LemonGateway.Types.Job
    alias LemonCore.ResumeToken

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
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}
      delay_ms = (job.meta || %{})[:delay_ms] || 50

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
          Process.sleep(delay_ms)

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{engine: id(), resume: resume, ok: true, answer: "Slow: #{job.prompt}"})}
          )
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
      max_concurrent_runs: 1,
      default_engine: "slow",
      enable_telegram: false,
      require_engine_lock: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      ThreadWorkerSlowEngine,
      LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      _ = Application.stop(:lemon_gateway)
    end)

    :ok
  end

  test "processes execution requests in FIFO order for one conversation" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})

    Enum.each(["first", "second", "third"], fn prompt ->
      GenServer.cast(worker, {:enqueue, request(session_key, prompt, self())})
    end)

    assert_completed_prompt("first")
    assert_completed_prompt("second")
    assert_completed_prompt("third")
  end

  test "stops after the queue drains" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})

    GenServer.cast(worker, {:enqueue, request(session_key, "done", self())})

    assert_completed_prompt("done")

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  defp request(session_key, prompt, notify_pid) do
    %ExecutionRequest{
      run_id: "run_#{System.unique_integer([:positive])}",
      session_key: session_key,
      prompt: prompt,
      conversation_key: {:session, session_key},
      engine_id: "slow",
      meta: %{notify_pid: notify_pid, delay_ms: 25}
    }
  end

  defp assert_completed_prompt(expected_prompt) do
    assert_receive {:lemon_gateway_run_completed, %Job{prompt: ^expected_prompt}, completed}, 2_000
    assert completed.answer == "Slow: #{expected_prompt}"
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
