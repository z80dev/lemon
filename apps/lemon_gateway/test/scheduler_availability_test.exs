defmodule LemonGateway.SchedulerAvailabilityTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{ExecutionRequest, Scheduler}

  defmodule GatedExecutor do
    @behaviour LemonGateway.Executor
    def start_run(request, _opts, sink) do
      send(request.meta.notify_pid, {:executor_started, request.run_id, sink})
      {:ok, make_ref(), %{}}
    end

    def cancel(_context), do: :ok
    def steer(_context, _text), do: {:error, :unsupported}
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  defmodule WedgedWorker do
    use GenServer

    def start_link({key, observer}) do
      GenServer.start_link(__MODULE__, observer,
        name: {:via, Registry, {LemonGateway.ThreadRegistry, key}}
      )
    end

    def init(observer), do: {:ok, observer}

    def handle_call({:enqueue, _request}, _from, observer) do
      send(observer, {:enqueue_wedged, self()})

      receive do
        :unwedge -> {:reply, :ok, observer}
      end
    end

    def handle_cast({:cancel_queued, id, reason}, observer) do
      send(observer, {:cancel_delivered, id, reason})
      {:noreply, observer}
    end
  end

  setup do
    running? =
      Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :lemon_gateway end)

    previous =
      for key <- [LemonGateway.Config, :executor],
          do: {key, Application.fetch_env(:lemon_gateway, key)}

    Application.stop(:lemon_gateway)
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{max_concurrent_runs: 1})
    Application.put_env(:lemon_gateway, :executor, GatedExecutor)
    {:ok, started} = Application.ensure_all_started(:lemon_gateway)

    on_exit(fn ->
      Enum.each(Enum.reverse(started), &Application.stop/1)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:lemon_gateway, key, value)
        {key, :error} -> Application.delete_env(:lemon_gateway, key)
      end)

      if running?, do: Application.ensure_all_started(:lemon_gateway)
    end)

    :ok
  end

  test "the slot allocator contains no synchronous child calls or linked tasks" do
    source = File.read!(Path.expand("../lib/lemon_gateway/scheduler.ex", __DIR__))
    refute source =~ "GenServer.call("
    refute source =~ "Task.async("
  end

  test "wedged enqueue does not block release, cancellation, another conversation or healthz" do
    scheduler = Process.whereis(Scheduler)
    key = {:wedged, make_ref()}
    worker = start_supervised!({WedgedWorker, {key, self()}})
    request = request(key)
    submitter = Task.async(fn -> Scheduler.submit_execution(request) end)
    assert_receive {:enqueue_wedged, ^worker}

    try do
      Scheduler.request_slot(self(), :held)
      assert_receive {:slot_granted, slot}
      Scheduler.request_slot(self(), :waiting)
      Scheduler.release_slot(slot)
      assert_receive {:slot_granted, next_slot}, 100
      Scheduler.release_slot(next_slot)
      Scheduler.cancel_execution(request.run_id, :test_cancel)
      Scheduler.cancel(self(), :test_cancel)
      assert_receive {:"$gen_cast", {:cancel, :test_cancel}}, 100

      other = request({:other, make_ref()})
      task = Task.async(fn -> Scheduler.submit_execution(other) end)
      assert Task.await(task, 100) == :ok
      assert_receive {:executor_started, id, _run}, 100
      assert id == other.run_id

      health =
        Task.async(fn ->
          Plug.Test.conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])
        end)

      assert Task.await(health, 100).status == 200
      assert Process.whereis(Scheduler) == scheduler
    after
      send(worker, :unwedge)
    end

    assert Task.await(submitter, 1_000) == :ok
    assert_receive {:cancel_delivered, id, :test_cancel}
    assert id == request.run_id
  end

  test "failed child startup leaves the scheduler available" do
    scheduler = Process.whereis(Scheduler)

    assert {:error, _} =
             DynamicSupervisor.start_child(
               LemonGateway.ThreadWorkerSupervisor,
               %{id: :failed_worker, start: {LemonGateway.ThreadWorker, :start_link, [[]]}}
             )

    assert Process.whereis(Scheduler) == scheduler
    Scheduler.request_slot(self(), :after_failure)
    assert_receive {:slot_granted, slot}, 100
    Scheduler.release_slot(slot)
  end

  test "healthz reads counters even when the scheduler mailbox is suspended" do
    scheduler = Process.whereis(Scheduler)
    :sys.suspend(scheduler)

    try do
      task =
        Task.async(fn ->
          Plug.Test.conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])
        end)

      conn = Task.await(task, 100)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["ok"]
    after
      :sys.resume(scheduler)
    end
  end

  defp request(key) do
    %ExecutionRequest{
      run_id: "availability-#{System.unique_integer([:positive])}",
      session_key: "availability",
      conversation_key: key,
      prompt: "test",
      meta: %{notify_pid: self()}
    }
  end
end
