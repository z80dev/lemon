defmodule LemonGateway.RunLifecycleTest do
  @moduledoc """
  Run terminalization that an owner can observe: every exit path publishes one
  durable completion. The test owns the run registry and permit authority, so
  losing the authority is not raced by the execution supervisor's restart.
  """

  use ExUnit.Case, async: false

  alias LemonCore.{Bus, Event, RunStore}
  alias LemonGateway.{ExecutionRequest, Run, Runtime, Slots}
  import LemonCore.Testing.AsyncHelpers, only: [assert_eventually: 1]

  defmodule GatedExecutor do
    @moduledoc false
    # `meta.unresponsive` starts a runner process that ignores cancellation and
    # whose cancel request times out, like a session busy in a tool.
    def start_run(request, _opts, _sink) do
      send(request.meta.test_pid, {:executor_started, request.run_id})

      if request.meta[:unresponsive] do
        runner = spawn(fn -> receive(do: (:stop -> :ok)) end)
        {:ok, make_ref(), %{runner_pid: runner, unresponsive: true}}
      else
        {:ok, make_ref(), %{}}
      end
    end

    def cancel(%{unresponsive: true, runner_pid: runner}),
      do: exit({:timeout, {GenServer, :call, [runner, :cancel, 5_000]}})

    def cancel(_context), do: :ok
    def steer(_context, _text), do: {:error, :unsupported}
    def redirect(_context, _text), do: {:error, :unsupported}
  end

  setup do
    LemonGateway.Test.AppIsolation.isolate_gateway([:executor])
    Application.put_env(:lemon_gateway, :executor, GatedExecutor)

    start_supervised!({Registry, keys: :unique, name: LemonGateway.RunRegistry})
    slots = start_supervised!(Supervisor.child_spec({Slots, max: 1}, restart: :temporary))
    %{slots: slots}
  end

  test "losing the permit authority terminalizes waiting and running Runs once", %{slots: slots} do
    running = request()
    waiting = request()
    Enum.each([running, waiting], &Bus.subscribe(Bus.run_topic(&1.run_id)))

    running_pid = start(running)
    running_id = running.run_id
    assert_receive {:executor_started, ^running_id}

    waiting_pid = start(waiting)
    # Registered before start_link returns, so its owner can monitor it at once.
    assert Runtime.run_pid(waiting.run_id) == waiting_pid
    assert_eventually(fn -> match?({:ok, %{waitq: 1, in_flight: 1}}, Slots.stats()) end)

    monitors = Enum.map([running_pid, waiting_pid], &Process.monitor/1)
    Process.exit(slots, :kill)

    for {request, cancelled?} <- [{waiting, nil}, {running, true}] do
      id = request.run_id

      assert_receive %Event{
                       type: :run_completed,
                       meta: %{run_id: ^id},
                       payload: %{completed: %{ok: false, error: :runtime_unavailable} = done}
                     },
                     1_000

      assert done.meta[:cancelled] == cancelled?
      assert {:ok, %{summary: %{completed: %{error: :runtime_unavailable}}}} = RunStore.fetch(id)
    end

    for ref <- monitors, do: assert_receive({:DOWN, ^ref, :process, _, :normal}, 1_000)
    refute_receive %Event{type: :run_completed}, 100
    refute_received {:executor_started, _}
  end

  test "a busy engine session is refused at start without a permit or terminal record" do
    owner = request()
    refused = %{request() | session_key: owner.session_key}
    _owner_pid = start(owner)
    Process.flag(:trap_exit, true)

    assert {:error, :session_in_use} = Run.start_link(%{execution_request: refused})
    assert Runtime.run_pid(refused.run_id) == nil
    assert {:ok, nil} = RunStore.fetch(refused.run_id)
    assert_eventually(fn -> match?({:ok, %{in_flight: 1, waitq: 0}}, Slots.stats()) end)
  end

  test "cancelling a non-responsive executor holds capacity until the drain deadline, then " <>
         "persists and releases the permit and claim exactly once" do
    request = request()
    request = %{request | meta: Map.put(request.meta, :unresponsive, true)}
    id = request.run_id
    Bus.subscribe(Bus.run_topic(id))
    pid = start(request)
    assert_receive {:executor_started, ^id}
    assert_eventually(fn -> match?({:ok, %{in_flight: 1}}, Slots.stats()) end)
    trace_terminal_calls(pid)

    GenServer.cast(pid, {:cancel, :user_requested})

    # The executor did not stop: the permit and engine session stay held.
    refute_receive %Event{type: :run_completed}, 200
    assert {:ok, %{in_flight: 1}} = Slots.stats()
    claim_key = {:session, request.session_key}
    claim = {:engine_session, claim_key}
    assert [{^pid, _}] = Registry.lookup(LemonGateway.RunRegistry, claim)
    assert Process.read_timer(:sys.get_state(pid).cancel_timeout_ref) > 14_000

    # The drain deadline fires.
    monitor = Process.monitor(pid)
    send(pid, :cancel_timeout)

    assert_receive %Event{
                     type: :run_completed,
                     meta: %{run_id: ^id},
                     payload: %{
                       completed: %{
                         ok: false,
                         error: :user_requested,
                         meta: %{cancelled: true, cancel_reason: :user_requested}
                       }
                     }
                   },
                   1_000

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    assert Registry.lookup(LemonGateway.RunRegistry, claim) == []
    assert_eventually(fn -> match?({:ok, %{in_flight: 0}}, Slots.stats()) end)

    assert [
             {:return_from, {RunStore, :finalize, 2}, :ok},
             {:call, {Slots, :release, [_permit]}},
             {:call, {LemonGateway.EngineSessionClaim, :release, [^claim_key]}}
           ] = traced_calls(pid)
  end

  defp request do
    id = "lifecycle-#{System.unique_integer([:positive])}"

    %ExecutionRequest{
      run_id: id,
      session_key: id,
      conversation_key: {:session, id},
      prompt: "test",
      meta: %{test_pid: self()}
    }
  end

  defp start(request) do
    {:ok, pid} = Run.start_link(%{execution_request: request})
    Process.unlink(pid)
    pid
  end

  @traced [
    {RunStore, :finalize, 2},
    {Slots, :release, 1},
    {LemonGateway.EngineSessionClaim, :release, 1}
  ]

  defp trace_terminal_calls(pid) do
    Enum.each(@traced, &:erlang.trace_pattern(&1, [{:_, [], [{:return_trace}]}], []))
    :erlang.trace(pid, true, [:call, {:tracer, self()}])
    on_exit(fn -> Enum.each(@traced, &:erlang.trace_pattern(&1, false, [])) end)
  end

  # Call and return order of the traced Run, collected after it exited.
  defp traced_calls(pid) do
    receive do
      {:trace, ^pid, :call, {RunStore, :finalize, _args}} ->
        traced_calls(pid)

      {:trace, ^pid, :call, {module, function, args}} ->
        [{:call, {module, function, args}} | traced_calls(pid)]

      {:trace, ^pid, :return_from, {RunStore, :finalize, 2} = mfa, result} ->
        [{:return_from, mfa, result} | traced_calls(pid)]

      {:trace, ^pid, :return_from, _mfa, _result} ->
        traced_calls(pid)
    after
      100 -> []
    end
  end
end
