defmodule LemonGateway.ThreadWorkerTest do
  use ExUnit.Case, async: false

  alias LemonGateway.ExecutionRequest
  alias LemonGateway.ThreadWorker
  alias LemonCore.ResumeToken

  defmodule SelectiveFailingRunSupervisor do
    alias LemonGateway.ExecutionRequest

    def start_run(%{execution_request: %ExecutionRequest{prompt: "malformed"} = request}) do
      if pid = :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        send(pid, {:run_start_attempt, request.run_id})
      end

      {:error, :malformed_request}
    end

    def start_run(args), do: LemonGateway.RunSupervisor.start_run(args)
  end

  defmodule ThreadWorkerSlowExecutor do
    @behaviour LemonGateway.Executor

    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: unique_id()}
      delay_ms = Map.get(request.meta || %{}, :delay_ms, 50)

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          Process.sleep(delay_ms)

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{
               engine: "lemon",
               resume: resume,
               ok: true,
               answer: "Slow: #{request.prompt}"
             })}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_context), do: :ok

    @impl true
    def steer(_context, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_context, _text), do: {:error, :unsupported}

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, ThreadWorkerSlowExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      _ = Application.stop(:lemon_gateway)
    end)

    :ok
  end

  test "processes execution requests in FIFO order for one conversation" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})

    requests =
      Enum.map(["first", "second", "third"], fn prompt ->
        request(session_key, prompt, self())
      end)

    Enum.each(requests, fn request ->
      GenServer.cast(worker, {:enqueue, request})
    end)

    Enum.each(requests, &assert_completed_request/1)
  end

  test "stops after the queue drains" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    worker = start_supervised!({ThreadWorker, thread_key: {:session, session_key}})

    request = request(session_key, "done", self())
    GenServer.cast(worker, {:enqueue, request})

    assert_completed_request(request)

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "bounds total start attempts, terminalizes once, and advances FIFO queue" do
    session_key = "thread-worker:#{System.unique_integer([:positive])}"
    thread_key = {:session, session_key}

    :persistent_term.put({SelectiveFailingRunSupervisor, :notify_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({SelectiveFailingRunSupervisor, :notify_pid})
    end)

    worker =
      start_supervised!(
        {ThreadWorker, thread_key: thread_key, run_supervisor: SelectiveFailingRunSupervisor}
      )

    failed = request(session_key, "malformed", self())
    succeeding = request(session_key, "after", self())
    LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(failed.run_id))

    GenServer.cast(worker, {:enqueue, failed})
    GenServer.cast(worker, {:enqueue, succeeding})

    for _ <- 1..3 do
      assert_receive {:run_start_attempt, run_id}, 1_000
      assert run_id == failed.run_id
    end

    refute_receive {:run_start_attempt, _}, 100

    assert_receive {:lemon_gateway_run_completed, ^failed,
                    %{
                      __event__: :completed,
                      ok: false,
                      error: %{
                        type: :run_start_failed,
                        reason: :malformed_request,
                        attempts: 3
                      }
                    }},
                   1_000

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{
                       run_id: failed_run_id,
                       synthetic: true,
                       failure_stage: :run_start
                     }
                   },
                   1_000

    assert failed_run_id == failed.run_id
    refute_receive {:lemon_gateway_run_completed, ^failed, _}, 100
    assert_completed_request(succeeding)
  end

  defp request(session_key, prompt, notify_pid) do
    %ExecutionRequest{
      run_id: "run_#{System.unique_integer([:positive])}",
      session_key: session_key,
      prompt: prompt,
      conversation_key: {:session, session_key},
      meta: %{notify_pid: notify_pid, delay_ms: 25}
    }
  end

  defp assert_completed_request(%ExecutionRequest{} = request) do
    assert_receive {:lemon_gateway_run_completed, ^request, completed}, 2_000

    assert completed.answer == "Slow: #{request.prompt}"
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
