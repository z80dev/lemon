defmodule CodingAgent.Search.SingleFlightTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Search.SingleFlight
  alias LemonAgent.AbortSignal

  @flight_timeout_ms 15_000

  setup do
    %{server: start_supervised!({SingleFlight, name: nil})}
  end

  test "coalesces concurrent work and returns one result to every caller", %{server: server} do
    counter = :counters.new(1, [:atomics])
    controlled = operation(:shared)

    operation = fn ->
      :counters.add(counter, 1, 1)
      controlled.(nil)
    end

    requests = for _ <- 1..12, do: enqueue(server, :same_query, operation)
    assert_receive {:operation_started, :shared, operation_pid, nil}, 5_000
    flight = flight(server, :same_query)
    assert length(flight.callers) == 12

    finish_operation(server, flight, {:ok, :shared})
    assert Enum.map(requests, &reply/1) == List.duplicate({:ok, :shared}, 12)
    assert :counters.get(counter, 1) == 1
    refute Process.alive?(operation_pid)
    assert_clean(server, flight)
  end

  test "contains task exceptions", %{server: server} do
    assert {:error, {:single_flight_exception, "boom"}} =
             SingleFlight.run(make_ref(), fn -> raise "boom" end, 1_000, server: server)
  end

  test "an already-aborted caller never starts or joins work", %{server: server} do
    signal = signal()
    AbortSignal.abort(signal)
    test_pid = self()

    assert {:error, "Operation aborted"} =
             SingleFlight.run(
               :already_aborted,
               fn ->
                 send(test_pid, :unexpected_operation)
                 {:ok, :unexpected}
               end,
               @flight_timeout_ms,
               server: server,
               signal: signal
             )

    assert Map.take(:sys.get_state(server), [:by_key, :by_ref, :abandoned]) ==
             %{by_key: %{}, by_ref: %{}, abandoned: %{}}

    refute_receive :unexpected_operation, 0

    request = enqueue(server, :already_aborted, operation(:active))
    assert_receive {:operation_started, :active, _operation_pid, _flight_signal}, 5_000
    active = flight(server, :already_aborted)

    assert {:error, "Operation aborted"} =
             SingleFlight.run(:already_aborted, fn -> {:ok, :unused} end, @flight_timeout_ms,
               server: server,
               signal: signal
             )

    assert flight(server, :already_aborted).callers == active.callers
    finish_operation(server, active, {:ok, :active})
    assert reply(request) == {:ok, :active}
    assert_clean(server, active)
  end

  test "an aborted caller leaves the flight without cancelling other callers", %{server: server} do
    leaving = signal()
    staying = signal()
    operation = operation(:partial_abort)
    leaver = enqueue(server, :partial_abort, operation, leaving)
    assert_receive {:operation_started, :partial_abort, _operation_pid, flight_signal}, 5_000
    stayer = enqueue(server, :partial_abort, operation, staying)
    assert length(flight(server, :partial_abort).callers) == 2

    abort_before_poll(server, [leaving])
    check_aborts(server)
    assert reply(leaver) == {:error, "Operation aborted"}
    shared = flight(server, :partial_abort)
    assert length(shared.callers) == 1
    refute AbortSignal.aborted?(flight_signal)

    finish_operation(server, shared, {:ok, :shared})
    assert reply(stayer) == {:ok, :shared}
    assert_clean(server, shared)
  end

  test "completion observes caller cancellation even before the next poll", %{server: server} do
    leaving = signal()
    operation = operation(:completion_abort)
    leaver = enqueue(server, :completion_abort, operation, leaving)
    assert_receive {:operation_started, :completion_abort, _operation_pid, _flight_signal}, 5_000
    stayer = enqueue(server, :completion_abort, operation)
    shared = flight(server, :completion_abort)

    abort_before_poll(server, [leaving])
    finish_operation(server, shared, {:ok, :shared})

    assert reply(leaver) == {:error, "Operation aborted"}
    assert reply(stayer) == {:ok, :shared}
    assert_clean(server, shared)
  end

  test "commit refreshes callers before authorizing publication", %{server: server} do
    caller_signal = signal()
    request = enqueue(server, :commit_aborted, operation(:commit_aborted), caller_signal)
    assert_receive {:operation_started, :commit_aborted, _, flight_signal}, 5_000
    active = flight(server, :commit_aborted)
    parent = self()

    abort_before_poll(server, [caller_signal])
    refute AbortSignal.aborted?(flight_signal)

    assert SingleFlight.commit(
             flight_signal,
             fn -> send(parent, :unauthorized_publication) end,
             server: server
           ) == {:error, "Operation aborted"}

    assert reply(request) == {:error, "Operation aborted"}
    refute_received :unauthorized_publication
    finish_operation(server, active, {:ok, :discarded})
    assert_clean(server, active)
  end

  test "publication keeps its authorization without blocking unrelated flights", %{server: server} do
    caller_signal = signal()
    request = enqueue(server, :atomic_commit, operation(:atomic_commit), caller_signal)
    assert_receive {:operation_started, :atomic_commit, _, flight_signal}, 5_000
    active = flight(server, :atomic_commit)
    parent = self()
    publications = :ets.new(:single_flight_publications, [:public])

    # Disable only the timer, leaving the server able to authorize the commit.
    abort_before_poll(server, [])

    commit =
      Task.async(fn ->
        SingleFlight.commit(
          flight_signal,
          fn ->
            send(parent, {:publication_authorized, self()})

            receive do
              :publish ->
                live = not AbortSignal.aborted?(flight_signal)
                :ets.insert(publications, {:published, live})
                {:published, live}
            after
              5_000 -> raise "publication was not released"
            end
          end,
          server: server
        )
      end)

    assert_receive {:publication_authorized, publisher}, 5_000
    refute publisher == server
    assert flight(server, :atomic_commit).status == :committing

    assert SingleFlight.authorize(flight_signal, server: server) ==
             {:error, "Operation aborted"}

    assert SingleFlight.commit(flight_signal, fn -> flunk("duplicate publication") end,
             server: server
           ) == {:error, "Operation aborted"}

    other = enqueue(server, :unrelated, operation(:unrelated))
    assert_receive {:operation_started, :unrelated, _, _}, 5_000
    unrelated = flight(server, :unrelated)
    finish_operation(server, unrelated, {:ok, :unrelated})
    assert reply(other) == {:ok, :unrelated}
    assert_clean(server, unrelated)

    cancelled_signal = signal()
    cancelled = enqueue(server, :cancelled, operation(:cancelled), cancelled_signal)
    assert_receive {:operation_started, :cancelled, _, cancelled_flight_signal}, 5_000
    cancelled_flight = flight(server, :cancelled)
    AbortSignal.abort(cancelled_signal)
    check_aborts(server)
    assert reply(cancelled) == {:error, "Operation aborted"}
    assert AbortSignal.aborted?(cancelled_flight_signal)
    finish_operation(server, cancelled_flight, {:error, "Operation aborted"})
    assert_clean(server, cancelled_flight)

    AbortSignal.abort(caller_signal)
    check_aborts(server)
    assert reply(request) == {:error, "Operation aborted"}
    assert flight(server, :atomic_commit).status == :committing
    assert :ets.lookup(publications, :published) == []
    refute AbortSignal.aborted?(flight_signal)
    send(publisher, :publish)
    assert Task.await(commit, 5_000) == {:published, true}
    assert :ets.lookup(publications, :published) == [{:published, true}]
    refute AbortSignal.aborted?(flight_signal)
    finish_operation(server, active, {:ok, :published})
    assert_clean(server, active)
  end

  test "a stalled publication is stopped at the flight deadline", %{server: server} do
    parent = self()

    request =
      enqueue(server, :publication_timeout, fn flight_signal ->
        SingleFlight.commit(
          flight_signal,
          fn ->
            send(parent, {:publication_blocked, self()})

            receive do
              :unexpected_release -> :published
            end
          end,
          server: server
        )
      end)

    assert_receive {:publication_blocked, publisher}, 5_000
    monitor = Process.monitor(publisher)
    active = flight(server, :publication_timeout)
    send(server, {:flight_timeout, active.task.ref})
    assert reply(request) == {:error, :single_flight_timeout}
    assert_receive {:DOWN, ^monitor, :process, ^publisher, _}, 5_000
    refute Process.alive?(active.task.pid)
    assert_clean(server, active)

    assert SingleFlight.run(:publication_timeout, fn -> :fresh end, 5_000, server: server) ==
             :fresh
  end

  test "a new caller replaces a fully-aborted flight before the abort poll", %{server: server} do
    signal = signal()
    old_request = enqueue(server, :admission_abort, operation(:old), signal)
    assert_receive {:operation_started, :old, _old_pid, old_signal}, 5_000
    old = flight(server, :admission_abort)

    # No poll can run between aborting the old caller and admitting this one.
    abort_before_poll(server, [signal])
    replacement_request = enqueue(server, :admission_abort, operation(:replacement))
    assert_receive {:operation_started, :replacement, _replacement_pid, replacement_signal}, 5_000
    replacement = flight(server, :admission_abort)

    assert reply(old_request) == {:error, "Operation aborted"}
    assert AbortSignal.aborted?(old_signal)
    refute AbortSignal.aborted?(replacement_signal)
    refute replacement.task.ref == old.task.ref
    assert Map.has_key?(:sys.get_state(server).abandoned, old.task.ref)

    finish_operation(server, old, {:ok, :old})
    assert_clean(server, old)
    assert flight(server, :admission_abort).task.ref == replacement.task.ref
    finish_operation(server, replacement, {:ok, :replacement})
    assert reply(replacement_request) == {:ok, :replacement}
    assert_clean(server, replacement)
  end

  test "an abandoned result cannot remove or reply to its replacement", %{server: server} do
    assert_abandoned_cleanup(server, :result)
  end

  test "an abandoned timeout cannot stop or remove its replacement", %{server: server} do
    assert_abandoned_cleanup(server, :timeout)
  end

  test "an abandoned DOWN cannot remove or reply to its replacement", %{server: server} do
    assert_abandoned_cleanup(server, :down)
  end

  test "timeout stops the active operation and releases its resources", %{server: server} do
    request = enqueue(server, :timeout, operation(:timeout))
    assert_receive {:operation_started, :timeout, _operation_pid, _flight_signal}, 5_000
    active = flight(server, :timeout)

    send(server, {:flight_timeout, active.task.ref})
    assert reply(request) == {:error, :single_flight_timeout}
    refute Process.alive?(active.task.pid)
    assert_clean(server, active)

    assert SingleFlight.run(:timeout, fn -> {:ok, :fresh} end, 5_000, server: server) ==
             {:ok, :fresh}
  end

  test "DOWN releases active callers and resources", %{server: server} do
    request = enqueue(server, :crash, operation(:crash))
    assert_receive {:operation_started, :crash, _operation_pid, _flight_signal}, 5_000
    active = flight(server, :crash)

    crash_operation(server, active)
    assert reply(request) == {:error, {:single_flight_crash, :killed}}
    assert_clean(server, active)

    assert SingleFlight.run(:crash, fn -> {:ok, :fresh} end, 5_000, server: server) ==
             {:ok, :fresh}
  end

  defp assert_abandoned_cleanup(server, completion) do
    first_signal = signal()
    second_signal = signal()
    old_operation = operation(:abandoned)
    first = enqueue(server, :same_key, old_operation, first_signal)
    assert_receive {:operation_started, :abandoned, _old_pid, old_signal}, 5_000
    second = enqueue(server, :same_key, old_operation, second_signal)
    old = flight(server, :same_key)

    abort_before_poll(server, [first_signal])
    check_aborts(server)
    assert reply(first) == {:error, "Operation aborted"}
    refute AbortSignal.aborted?(old_signal)

    abort_before_poll(server, [second_signal])
    state = check_aborts(server)
    assert reply(second) == {:error, "Operation aborted"}
    assert AbortSignal.aborted?(old_signal)
    refute Map.has_key?(state.by_key, :same_key)
    refute Map.has_key?(state.by_ref, old.task.ref)
    assert state.abandoned[old.task.ref].callers == []

    request = enqueue(server, :same_key, operation(:replacement))
    assert_receive {:operation_started, :replacement, _replacement_pid, replacement_signal}, 5_000
    replacement = flight(server, :same_key)

    case completion do
      :result -> finish_operation(server, old, {:ok, :abandoned})
      :timeout -> send(server, {:flight_timeout, old.task.ref})
      :down -> crash_operation(server, old)
    end

    state = assert_clean(server, old)
    assert state.by_key.same_key.task.ref == replacement.task.ref
    assert state.by_ref == %{replacement.task.ref => :same_key}
    assert :ets.member(:agent_core_abort_signals, replacement_signal)
    refute AbortSignal.aborted?(replacement_signal)
    assert Process.alive?(replacement.task.pid)
    assert :gen_server.wait_response(request, 0) == :timeout

    # Already queued timeout, result or DOWN notifications must be harmless too.
    send(server, {:flight_timeout, old.task.ref})
    send(server, {old.task.ref, {:ok, :stale}})
    send(server, {:DOWN, old.task.ref, :process, old.task.pid, :normal})
    assert flight(server, :same_key).task.ref == replacement.task.ref

    finish_operation(server, replacement, {:ok, :replacement})
    assert reply(request) == {:ok, :replacement}
    assert_clean(server, replacement)
  end

  defp operation(tag) do
    test_pid = self()

    fn flight_signal ->
      monitor = Process.monitor(test_pid)
      send(test_pid, {:operation_started, tag, self(), flight_signal})

      receive do
        {:finish, result} -> result
        {:DOWN, ^monitor, :process, ^test_pid, _reason} -> {:error, :test_finished}
      end
    end
  end

  defp signal do
    signal = AbortSignal.new()
    on_exit(fn -> AbortSignal.clear(signal) end)
    signal
  end

  defp enqueue(server, key, operation, signal \\ nil) do
    # Sending the call and state request from one process makes admission a
    # barrier, without polling for asynchronously scheduled caller tasks.
    request =
      :gen_server.send_request(server, {:run, key, operation, @flight_timeout_ms, signal})

    :sys.get_state(server)
    request
  end

  defp reply(request) do
    assert {:reply, result} = :gen_server.receive_response(request, 5_000)
    result
  end

  defp flight(server, key), do: Map.fetch!(:sys.get_state(server).by_key, key)

  defp abort_before_poll(server, signals) do
    :sys.replace_state(server, fn state ->
      if state.abort_timer do
        case Process.cancel_timer(state.abort_timer) do
          false ->
            receive do
              :check_aborts -> :ok
            after
              5_000 -> raise "abort timer notification was not delivered"
            end

          _remaining_ms ->
            :ok
        end
      end

      Enum.each(signals, &AbortSignal.abort/1)
      %{state | abort_timer: nil}
    end)
  end

  defp check_aborts(server) do
    send(server, :check_aborts)
    :sys.get_state(server)
  end

  defp finish_operation(server, flight, result) do
    stop_operation(server, flight, &send(&1, {:finish, result}))
  end

  defp crash_operation(server, flight) do
    stop_operation(server, flight, &Process.exit(&1, :kill))
  end

  defp stop_operation(server, flight, stop) do
    :sys.replace_state(server, fn state ->
      stop.(flight.task.pid)
      ref = flight.task.ref
      pid = flight.task.pid

      # Hold the server until the real task DOWN arrives, then put it back.
      # A successful task's result precedes DOWN in this same mailbox, so the
      # following state request observes completion rather than racing it.
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} = down ->
          send(self(), down)
          state
      after
        5_000 -> raise "operation did not stop"
      end
    end)

    :sys.get_state(server)
  end

  defp assert_clean(server, flight) do
    state = :sys.get_state(server)
    refute Map.has_key?(state.by_ref, flight.task.ref)
    refute Map.has_key?(state.abandoned, flight.task.ref)

    refute Enum.any?(state.by_key, fn {_key, active} ->
             active.task.ref == flight.task.ref
           end)

    refute :ets.member(:agent_core_abort_signals, flight.signal)
    assert Process.read_timer(flight.timer) == false
    assert {:monitors, monitors} = Process.info(server, :monitors)
    refute {:process, flight.task.pid} in monitors
    state
  end
end
