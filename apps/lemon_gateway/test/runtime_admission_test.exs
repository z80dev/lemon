defmodule LemonGateway.RuntimeAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonGateway.{Event, ExecutionRequest, Runtime, Slots}
  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  defmodule GatedExecutor do
    @behaviour LemonGateway.Executor
    def start_run(request, _opts, sink) do
      ref = make_ref()
      send(request.meta.notify_pid, {:executor_started, request.run_id, sink, ref})

      if node = request.meta[:node] do
        send(request.meta.notify_pid, {:executor_node, request.run_id, node})
      end

      {:ok, ref, %{}}
    end

    def cancel(_context), do: :ok
    def steer(_context, _text), do: {:error, :unsupported}
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([LemonGateway.Config, :executor])
    Application.put_env(:lemon_gateway, LemonGateway.Config, %{max_concurrent_runs: 2})
    Application.put_env(:lemon_gateway, :executor, GatedExecutor)
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    :ok
  end

  test "two permits cap execution and waiting runs start FIFO across conversations" do
    a = request()
    b = request()
    c = request()
    d = request()
    {a_pid, a_ref} = start(a)
    {b_pid, b_ref} = start(b)
    assert :ok = submit(c)
    assert_eventually(fn -> match?({:ok, %{waitq: 1}}, Slots.stats()) end)
    assert :ok = submit(d)
    assert_eventually(fn -> match?({:ok, %{in_flight: 2, waitq: 2}}, Slots.stats()) end)
    refute_receive {:executor_started, _, _, _}, 20
    complete(a_pid, a_ref)
    c_id = c.run_id
    assert_receive {:executor_started, ^c_id, c_pid, c_ref}, 1_000
    refute_receive {:executor_started, _, _, _}, 20
    complete(b_pid, b_ref)
    d_id = d.run_id
    assert_receive {:executor_started, ^d_id, d_pid, d_ref}, 1_000
    complete(c_pid, c_ref)
    complete(d_pid, d_ref)
    assert_eventually(fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats()) end)
  end

  test "exact waiting cancellation never starts the executor and publishes one terminal" do
    a = request()
    b = request()
    waiting = request()
    {a_pid, a_ref} = start(a)
    {b_pid, b_ref} = start(b)
    id = waiting.run_id
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(id))
    assert :ok = submit(waiting)
    assert_eventually(fn -> match?({:ok, %{waitq: 1}}, Slots.stats()) end)
    assert :ok = Runtime.cancel_by_run_id(id, :user_requested)

    assert_receive %LemonCore.Event{
                     type: :run_completed,
                     meta: %{run_id: ^id},
                     payload: %{completed: %{ok: false, error: :user_requested}}
                   },
                   1_000

    assert_receive {:lemon_gateway_run_completed, ^waiting, %{ok: false}}, 1_000
    assert_eventually(fn -> Runtime.run_pid(id) == nil end)
    complete(a_pid, a_ref)
    complete(b_pid, b_ref)
    assert_eventually(fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats()) end)
    refute_receive {:executor_started, ^id, _, _}, 50
    refute_receive %LemonCore.Event{type: :run_completed, meta: %{run_id: ^id}}, 50
    refute_receive {:lemon_gateway_run_completed, ^waiting, _}, 50
    assert %{summary: %{completed: %{ok: false}}} = LemonCore.RunStore.get(id)
  end

  test "duplicate live run id starts one Run and one executor invocation" do
    request = request()
    {pid, ref} = start(request)
    assert :ok = submit(request)
    assert Runtime.run_pid(request.run_id) == pid
    assert {:ok, %{in_flight: 1, waitq: 0}} = Slots.stats()
    id = request.run_id
    refute_receive {:executor_started, ^id, _, _}, 50
    complete(pid, ref)
    assert_receive {:lemon_gateway_run_completed, ^request, _}, 1_000
    assert_eventually(fn -> Runtime.run_pid(id) == nil end)
    assert :ok = submit(request)
    assert_eventually(fn -> Runtime.run_pid(id) == nil end)
    assert {:ok, late_pid} = LemonGateway.Run.start_link(%{execution_request: request})
    monitor = Process.monitor(late_pid)
    assert_receive {:DOWN, ^monitor, :process, ^late_pid, reason}, 1_000
    assert reason in [:normal, :noproc]
    assert {:ok, %{in_flight: 0, waitq: 0}} = Slots.stats()
    refute_receive {:executor_started, ^id, _, _}, 50
    refute_receive {:lemon_gateway_run_completed, ^request, _}, 50
  end

  test "shared resume refusal occurs before permit acquisition" do
    resume = %LemonCore.ResumeToken{engine: "lemon", value: "claim-#{make_ref() |> inspect()}"}
    owner = %{request() | resume: resume}
    refused = %{request() | resume: resume}
    {pid, ref} = start(owner)
    slots = Process.whereis(Slots)
    :sys.suspend(slots)

    try do
      # Refused synchronously, before the (suspended) permit authority is asked.
      assert {:error, :session_in_use} = submit(refused)
      assert Runtime.run_pid(refused.run_id) == nil
      assert {:ok, nil} = LemonCore.RunStore.fetch(refused.run_id)
      refute_received {:lemon_gateway_run_completed, ^refused, _}

      assert {:ok, %{in_flight: 1, waitq: 0}} = Slots.stats()
      id = refused.run_id
      refute_receive {:executor_started, ^id, _, _}, 20
    after
      :sys.resume(slots)
    end

    complete(pid, ref)
  end

  test "named-node metadata crosses the executor boundary with exactly one permit" do
    request = request()
    request = %{request | meta: Map.put(request.meta, :node, "worker-east")}
    {pid, ref} = start(request)
    assert Runtime.run_pid(request.run_id) == pid
    assert :sys.get_state(pid).execution_request.meta.node == "worker-east"
    id = request.run_id
    assert_receive {:executor_node, ^id, "worker-east"}, 1_000
    assert {:ok, %{in_flight: 1, waitq: 0}} = Slots.stats()
    complete(pid, ref)
    assert_receive {:lemon_gateway_run_completed, ^request, _}, 1_000
    assert_eventually(fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats()) end)
  end

  test "a crashed Run releases its permit and engine session claim" do
    request = request()
    {pid, _ref} = start(request)
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000
    key = {:engine_session, {:session, request.session_key}}
    assert_eventually(fn -> Registry.lookup(LemonGateway.RunRegistry, key) == [] end)
    assert_eventually(fn -> match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats()) end)
    replacement = %{request | run_id: "replacement-#{request.run_id}"}
    {next_pid, next_ref} = start(replacement)
    complete(next_pid, next_ref)
  end

  test "permit authority loss stops active and waiting Runs before fresh admission" do
    {active, _} = start(request())
    {_other, _} = start(request())
    waiting = request()
    assert :ok = submit(waiting)
    assert_eventually(fn -> match?({:ok, %{in_flight: 2, waitq: 1}}, Slots.stats()) end)
    waiter = Runtime.run_pid(waiting.run_id)
    assert is_pid(waiter)
    active_monitor = Process.monitor(active)
    waiting_monitor = Process.monitor(waiter)
    old_slots = Process.whereis(Slots)
    Process.exit(old_slots, :kill)
    assert_receive {:DOWN, ^active_monitor, :process, ^active, _}, 1_000
    assert_receive {:DOWN, ^waiting_monitor, :process, ^waiter, _}, 1_000

    assert_eventually(fn ->
      pid = Process.whereis(Slots)

      is_pid(pid) and pid != old_slots and
        match?({:ok, %{in_flight: 0, waitq: 0}}, Slots.stats())
    end)

    id = waiting.run_id
    refute_receive {:executor_started, ^id, _, _}, 20
    {pid, ref} = start(request())
    complete(pid, ref)
  end

  test "health and counters do not call a suspended permit authority" do
    slots = Process.whereis(Slots)
    :sys.suspend(slots)

    try do
      task =
        Task.async(fn ->
          stats = Slots.stats()
          conn = Plug.Test.conn(:get, "/healthz") |> LemonGateway.Health.Router.call([])
          status = LemonGateway.Health.status()
          assert status.ok
          assert Enum.any?(status.checks, &(&1.name == "slots" and &1.ok))
          {stats, conn}
        end)

      assert {{:ok, %{max: 2, in_flight: 0}}, conn} = Task.await(task, 500)
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["ok"]
    after
      :sys.resume(slots)
    end
  end

  defp request do
    id = "admission-#{System.unique_integer([:positive])}"

    %ExecutionRequest{
      run_id: id,
      session_key: id,
      conversation_key: {:session, id},
      prompt: "test",
      meta: %{notify_pid: self()}
    }
  end

  defp submit(request), do: Runtime.submit_execution(ExecutionRequest.to_command(request))

  defp start(request) do
    assert :ok = submit(request)
    id = request.run_id
    assert_receive {:executor_started, ^id, pid, ref}, 1_000
    {pid, ref}
  end

  defp complete(pid, ref) do
    send(pid, {:engine_event, ref, Event.completed(%{engine: "lemon", ok: true, answer: "done"})})
  end
end
