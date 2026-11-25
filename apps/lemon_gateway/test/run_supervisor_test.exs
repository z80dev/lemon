defmodule LemonGateway.RunSupervisorTest do
  use ExUnit.Case, async: false

  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  alias LemonGateway.{ExecutionRequest, Run, RunSupervisor, Slots}

  defmodule FixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.{Event, ExecutionRequest}

    @impl true
    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: request.run_id}
      controller = (request.meta || %{})[:controller_pid]

      {:ok, task_pid} =
        Task.start(fn ->
          monitor = Process.monitor(sink_pid)

          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          if controller,
            do: send(controller, {:executor_started, request.run_id, request.prompt, self()})

          receive do
            {:complete, answer} ->
              send(
                sink_pid,
                {:engine_event, run_ref,
                 Event.completed(%{engine: "lemon", resume: resume, ok: true, answer: answer})}
              )

            {:DOWN, ^monitor, :process, ^sink_pid, _reason} ->
              :ok
          end
        end)

      {:ok, run_ref, %{runner_pid: task_pid}}
    end

    @impl true
    def cancel(%{runner_pid: task_pid}) do
      Process.exit(task_pid, :kill)
      :ok
    end

    @impl true
    def steer(_context, _text), do: :ok

    @impl true
    def redirect(_context, _text), do: :ok
  end

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([LemonGateway.Config, :executor])

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 10,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, FixtureExecutor)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  defp request(opts \\ []) do
    id = Integer.to_string(System.unique_integer([:positive]))
    session_key = Keyword.get(opts, :session_key, "test:#{id}")
    resume = Keyword.get(opts, :resume)

    %ExecutionRequest{
      run_id: "run_supervisor_#{id}",
      session_key: session_key,
      conversation_key:
        if(resume, do: {:resume, resume.engine, resume.value}, else: {:session, session_key}),
      prompt: Keyword.get(opts, :prompt, "test message"),
      resume: resume,
      meta: Keyword.get(opts, :meta, %{notify_pid: self(), controller_pid: self()})
    }
  end

  defp start(request) do
    assert {:ok, pid} = RunSupervisor.start_run(%{execution_request: request})
    monitor = Process.monitor(pid)
    run_id = request.run_id
    prompt = request.prompt
    assert_receive {:executor_started, ^run_id, ^prompt, task_pid}, 2000
    {pid, monitor, task_pid}
  end

  defp complete(request, {pid, monitor, task_pid}, answer \\ "done") do
    send(task_pid, {:complete, answer})

    assert_receive {:lemon_gateway_run_completed, ^request,
                    %{__event__: :completed, ok: true, answer: ^answer}},
                   2000

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
  end

  defp child_pids do
    RunSupervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> pid end)
  end

  test "supervisor is registered and starts Run children" do
    assert is_pid(Process.whereis(RunSupervisor))
    request = request()
    {pid, _, _} = run = start(request)
    assert pid in child_pids()
    assert [{_, ^pid, :worker, [Run]}] = DynamicSupervisor.which_children(RunSupervisor)
    assert %{active: 1, workers: 1} = DynamicSupervisor.count_children(RunSupervisor)
    complete(request, run)
    assert_eventually(fn -> child_pids() == [] end)
  end

  test "concurrent runs complete independently and out of start order" do
    runs =
      for i <- 1..5 do
        request = request(prompt: "run #{i}")
        {request, start(request)}
      end

    assert length(child_pids()) == 5
    assert {:ok, %{in_flight: 5, waitq: 0, max: 10}} = Slots.stats()

    for {request, run} <- Enum.reverse(runs) do
      complete(request, run, request.prompt)
    end

    assert_eventually(fn -> child_pids() == [] end)

    assert_eventually(fn ->
      match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats())
    end)
  end

  test "executor death completes its run without restarting it or affecting its sibling" do
    request1 = request()
    request2 = request()
    {pid1, monitor1, task1} = start(request1)
    {pid2, _, _} = run2 = start(request2)
    Process.exit(task1, :kill)

    assert_receive {:lemon_gateway_run_completed, ^request1, %{__event__: :completed, ok: false}},
                   2000

    assert_receive {:DOWN, ^monitor1, :process, ^pid1, :normal}, 2000
    assert_eventually(fn -> child_pids() == [pid2] end)
    assert Process.alive?(pid2)
    complete(request2, run2)
  end

  test "a killed Run is not restarted and the supervisor accepts another child" do
    request1 = request()
    {pid1, monitor1, task1} = start(request1)
    task_monitor = Process.monitor(task1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^monitor1, :process, ^pid1, :killed}, 2000
    assert_receive {:DOWN, ^task_monitor, :process, ^task1, _reason}, 2000
    assert_eventually(fn -> child_pids() == [] end)
    assert Process.alive?(Process.whereis(RunSupervisor))

    # Reusing the session also verifies that ownership dies with the old Run.
    request2 = request(session_key: request1.session_key)
    complete(request2, start(request2))
  end

  test "terminating one child cancels its executor while a sibling continues" do
    request1 = request()
    request2 = request()
    {pid1, monitor1, task1} = start(request1)
    {pid2, _, _} = run2 = start(request2)
    task_monitor = Process.monitor(task1)

    assert :ok = DynamicSupervisor.terminate_child(RunSupervisor, pid1)
    assert_receive {:DOWN, ^monitor1, :process, ^pid1, :shutdown}, 2000
    assert_receive {:DOWN, ^task_monitor, :process, ^task1, _reason}, 2000
    assert_eventually(fn -> child_pids() == [pid2] end)
    complete(request2, run2)
  end

  test "supervisor shutdown terminates all children and their executors" do
    runs = for _ <- 1..3, do: start(request())
    task_monitors = for {_, _, task} <- runs, do: {Process.monitor(task), task}
    assert :ok = Application.stop(:lemon_gateway)

    for {pid, monitor, _} <- runs do
      assert_receive {:DOWN, ^monitor, :process, ^pid, :shutdown}, 2000
    end

    for {monitor, task} <- task_monitors do
      assert_receive {:DOWN, ^monitor, :process, ^task, _reason}, 2000
    end
  end

  test "concurrent callers receive completions at their configured notification target" do
    parent = self()

    tasks =
      for i <- 1..5 do
        Task.async(fn ->
          request =
            request(
              prompt: "concurrent #{i}",
              meta: %{notify_pid: parent, controller_pid: parent}
            )

          {:ok, pid} = RunSupervisor.start_run(%{execution_request: request})
          {request, pid}
        end)
      end

    runs =
      for {request, pid} <- Task.await_many(tasks, 5000) do
        monitor = Process.monitor(pid)
        run_id = request.run_id
        prompt = request.prompt
        assert_receive {:executor_started, ^run_id, ^prompt, task}, 2000
        {request, {pid, monitor, task}}
      end

    for {request, run} <- runs, do: complete(request, run, request.prompt)
  end

  test "distinct notification targets receive only their own request and completion" do
    parent = self()

    targets =
      for label <- [:first, :second] do
        target =
          spawn(fn ->
            receive do
              message -> send(parent, {label, message})
            end
          end)

        request = request(meta: %{notify_pid: target, controller_pid: parent})
        {pid, monitor, task} = start(request)
        {label, request, pid, monitor, task}
      end

    for {label, request, pid, monitor, task} <- targets do
      send(task, {:complete, request.run_id})
      answer = request.run_id

      assert_receive {^label,
                      {:lemon_gateway_run_completed, ^request,
                       %{__event__: :completed, ok: true, answer: ^answer}}},
                     2000

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
    end
  end

  test "completed runs release the session for rapid sequential starts" do
    session_key = request().session_key

    for i <- 1..20 do
      request = request(session_key: session_key, prompt: "sequential #{i}")
      complete(request, start(request), request.prompt)
    end

    assert_eventually(fn -> child_pids() == [] end)
  end

  test "empty, long and special-character prompts reach completion unchanged" do
    for prompt <- ["", String.duplicate("a", 10_000), "Special: \n\t\r unicode: \u{1F600}"] do
      request = request(prompt: prompt)
      complete(request, start(request), prompt)
    end
  end

  test "nil metadata needs no notification target" do
    request = request(meta: nil)
    assert {:ok, pid} = RunSupervisor.start_run(%{execution_request: request})
    monitor = Process.monitor(pid)

    # Synchronize on executor launch, not elapsed time: start_run returns before
    # admission and nil metadata intentionally has no notification recipient.
    assert_eventually(fn -> is_pid(:sys.get_state(pid).executor_pid) end)
    task = :sys.get_state(pid).executor_pid
    send(task, {:complete, "without notification"})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
  end

  test "a burst beyond slot capacity queues and completes every Run" do
    runs =
      for i <- 1..50 do
        request = request(prompt: "burst #{i}")
        assert {:ok, pid} = RunSupervisor.start_run(%{execution_request: request})
        {request, pid, Process.monitor(pid)}
      end

    # Ten explicit launch handshakes prove that capacity is occupied before any
    # completion is allowed; the remaining children stay supervised while queued.
    active =
      for _ <- 1..10 do
        assert_receive {:executor_started, run_id, _prompt, task}, 2000
        {run_id, task}
      end

    assert length(child_pids()) == 50

    assert_eventually(fn ->
      match?({:ok, %{in_flight: 10, waitq: 40}}, Slots.stats())
    end)

    for {run_id, task} <- active, do: send(task, {:complete, run_id})

    for _ <- 1..40 do
      assert_receive {:executor_started, run_id, _prompt, task}, 5000
      send(task, {:complete, run_id})
    end

    for {request, pid, monitor} <- runs do
      answer = request.run_id

      assert_receive {:lemon_gateway_run_completed, ^request,
                      %{__event__: :completed, ok: true, answer: ^answer}},
                     5000

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5000
    end

    assert_eventually(fn -> child_pids() == [] end)
    assert Process.alive?(Process.whereis(RunSupervisor))
  end

  test "start_run rejects input missing a valid execution request" do
    for args <- [%{}, %{request: request()}, %{execution_request: nil}] do
      assert {:error, :invalid_execution_request} = RunSupervisor.start_run(args)
    end
  end
end
