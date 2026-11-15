defmodule LemonControlPlane.WS.MethodCapacityTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonControlPlane.Methods.Registry
  alias LemonControlPlane.WS.Connection

  defmodule BlockingHandler do
    @behaviour LemonControlPlane.Method
    def name, do: "capacity.test.blocking"
    def scopes, do: []
    def dispatch_mode, do: :async

    def handle(_params, ctx) do
      send(ctx.auth.test_pid, {:capacity_started, self()})

      receive do
        :finish -> {:ok, %{finished: true}}
      end
    end
  end

  defmodule CrashingHandler do
    @behaviour LemonControlPlane.Method
    def name, do: "capacity.test.crashing"
    def scopes, do: []
    def dispatch_mode, do: :async
    def handle(_params, _ctx), do: raise(ArgumentError, "private-exception-marker")
  end

  setup do
    unless Process.whereis(Registry), do: start_supervised!(Registry)

    unless Process.whereis(LemonControlPlane.MethodTaskSupervisor) do
      start_supervised!(
        {Task.Supervisor,
         name: LemonControlPlane.MethodTaskSupervisor,
         max_children: Connection.global_method_limit()}
      )
    end

    for handler <- [BlockingHandler, CrashingHandler], do: Registry.register(handler)

    on_exit(fn ->
      for handler <- [BlockingHandler, CrashingHandler], do: Registry.unregister(handler.name())
    end)

    state = %Connection{
      conn_id: "capacity-test",
      connected: true,
      auth: %{role: :operator, scopes: [:admin], test_pid: self()},
      state_version: %{},
      event_seq: 0
    }

    %{state: state}
  end

  test "per-connection cap rejects before starting work and completion releases a slot", %{
    state: state
  } do
    {state, workers} =
      Enum.reduce(1..Connection.per_connection_method_limit(), {state, []}, fn n,
                                                                               {state, workers} ->
        assert {:ok, state} = request(state, Integer.to_string(n), BlockingHandler)
        assert_receive {:capacity_started, worker}
        {state, [worker | workers]}
      end)

    on_exit(fn ->
      Enum.each(
        workers,
        &Task.Supervisor.terminate_child(LemonControlPlane.MethodTaskSupervisor, &1)
      )
    end)

    assert map_size(state.method_tasks) == Connection.per_connection_method_limit()
    assert {:push, {:text, frame}, ^state} = request(state, "over-limit", BlockingHandler)
    assert Jason.decode!(frame)["error"]["code"] == "UNAVAILABLE"
    refute_received {:capacity_started, _}

    [worker | rest] = workers
    send(worker, :finish)
    assert_receive {:method_result, _token, {:ok, _}} = result
    assert {:push, _, state} = Connection.handle_info(result, state)
    assert {:ok, state} = request(state, "replacement", BlockingHandler)
    assert_receive {:capacity_started, replacement}
    send(replacement, :finish)
    Enum.each(rest, &send(&1, :finish))

    state =
      Enum.reduce(1..Connection.per_connection_method_limit(), state, fn _, state ->
        assert_receive {:method_result, _token, {:ok, _}} = result
        assert {:push, _, state} = Connection.handle_info(result, state)
        state
      end)

    assert state.method_tasks == %{}
  end

  test "worker death returns an internal error and releases its connection slot", %{state: state} do
    assert {:ok, state} = request(state, "killed-worker", BlockingHandler)
    assert_receive {:capacity_started, worker}
    Process.exit(worker, :kill)
    assert_receive {:DOWN, _ref, :process, ^worker, :killed} = down

    capture_log(fn ->
      assert {:push, {:text, frame}, state} = Connection.handle_info(down, state)
      assert Jason.decode!(frame)["error"]["code"] == "INTERNAL_ERROR"
      assert state.method_tasks == %{}
    end)
  end

  test "unused connection supervisor and unique registry are not supervised" do
    children = Supervisor.which_children(LemonControlPlane.Supervisor)
    refute List.keymember?(children, LemonControlPlane.ConnectionSupervisor, 0)
    refute List.keymember?(children, LemonControlPlane.ConnectionRegistry, 0)
    assert List.keymember?(children, LemonControlPlane.Connections, 0)
    assert List.keymember?(children, LemonControlPlane.MethodTaskSupervisor, 0)
  end

  test "global supervisor cap rejects an otherwise idle connection", %{state: state} do
    workers =
      for _ <- 1..Connection.global_method_limit() do
        {:ok, pid} =
          Task.Supervisor.start_child(LemonControlPlane.MethodTaskSupervisor, fn ->
            receive do
              :finish -> :ok
            end
          end)

        pid
      end

    try do
      assert {:push, {:text, frame}, ^state} = request(state, "global-limit", BlockingHandler)
      assert Jason.decode!(frame)["error"]["code"] == "UNAVAILABLE"
      refute_received {:capacity_started, _}
      assert state.method_tasks == %{}
    after
      for pid <- workers,
          do: Task.Supervisor.terminate_child(LemonControlPlane.MethodTaskSupervisor, pid)
    end
  end

  test "crashing async method returns internal error with redacted class/method telemetry", %{
    state: state
  } do
    parent = self()
    event = [:lemon, :control_plane, :method, :exception]
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, _ ->
          send(parent, {:method_telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        assert {:ok, state} = request(state, "crash", CrashingHandler)

        assert_receive {:method_result, _token,
                        {:error, {:internal_error, "Method execution failed"}}} = result

        assert {:push, {:text, frame}, state} = Connection.handle_info(result, state)
        assert Jason.decode!(frame)["error"]["code"] == "INTERNAL_ERROR"
        assert state.method_tasks == %{}
        assert_receive {:method_telemetry, ^event, %{count: 1}, metadata}
        assert metadata == %{class: ArgumentError, method: CrashingHandler.name()}
      end)

    assert log =~ "class=ArgumentError"
    assert log =~ "method=capacity.test.crashing"
    refute log =~ "private-exception-marker"
    refute log =~ "private-param-marker"
  end

  defp request(state, id, handler) do
    frame =
      Jason.encode!(%{
        type: "req",
        id: id,
        method: handler.name(),
        params: %{secret: "private-param-marker"}
      })

    Connection.handle_in({frame, [opcode: :text]}, state)
  end
end
