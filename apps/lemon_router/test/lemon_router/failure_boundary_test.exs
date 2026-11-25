defmodule LemonRouter.FailureBoundaryTest do
  use ExUnit.Case, async: false

  alias LemonCore.{Event, SessionKey}
  alias LemonRouter.{StreamCoalescer, SurfaceManager}

  defmodule Dispatcher do
    def dispatch(intent) do
      case Application.fetch_env!(:lemon_router, :failure_boundary_dispatch) do
        :raise ->
          raise "dispatcher callback bug"

        {:error, reason} ->
          {:error, reason}

        {:deliver, recipient} ->
          send(recipient, {:delivered, intent})
          :ok
      end
    end
  end

  setup do
    previous = Application.get_env(:lemon_router, :dispatcher)
    previous_result = Application.get_env(:lemon_router, :failure_boundary_dispatch)
    Application.put_env(:lemon_router, :dispatcher, Dispatcher)

    on_exit(fn ->
      restore_env(:dispatcher, previous)
      restore_env(:failure_boundary_dispatch, previous_result)
    end)

    unless Process.whereis(LemonRouter.CoalescerRegistry) do
      start_supervised!({Registry, keys: :unique, name: LemonRouter.CoalescerRegistry})
    end

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "test",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: "failure-#{System.unique_integer([:positive])}"
      })

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, coalescer} =
      DynamicSupervisor.start_child(
        supervisor,
        {StreamCoalescer, session_key: session_key, channel_id: "telegram"}
      )

    %{supervisor: supervisor, coalescer: coalescer, session_key: session_key}
  end

  @tag capture_log: true
  test "unexpected dispatcher exception reaches the caller and supervisor recovers", context do
    Application.put_env(:lemon_router, :failure_boundary_dispatch, :raise)
    monitor = Process.monitor(context.coalescer)

    assert {:error, {:finalize_call_failed, _}} =
             StreamCoalescer.finalize_run(context.session_key, "telegram", "run-failure",
               final_text: "complete answer"
             )

    assert_receive {:DOWN, ^monitor, :process, _pid,
                    {%RuntimeError{message: "dispatcher callback bug"}, _stack}}

    recovered = await_replacement(context.supervisor, context.coalescer)
    Application.put_env(:lemon_router, :failure_boundary_dispatch, {:deliver, self()})

    assert :ok =
             StreamCoalescer.finalize_run(context.session_key, "telegram", "run-failure",
               final_text: "complete answer"
             )

    assert_receive {:delivered, %{kind: :stream_finalize, body: %{text: "complete answer"}}}
    assert %{finalized: true} = :sys.get_state(recovered)
  end

  test "explicit delivery rejection keeps the answer retryable without a restart", context do
    Application.put_env(:lemon_router, :failure_boundary_dispatch, {:error, :unavailable})

    assert {:error, {:dispatch_failed, :unavailable}} =
             StreamCoalescer.finalize_run(context.session_key, "telegram", "run-retry",
               final_text: "retry answer"
             )

    assert %{finalized: false} = :sys.get_state(context.coalescer)
    Application.put_env(:lemon_router, :failure_boundary_dispatch, {:deliver, self()})

    assert :ok =
             StreamCoalescer.finalize_run(context.session_key, "telegram", "run-retry",
               final_text: "retry answer"
             )

    assert_receive {:delivered, %{kind: :stream_finalize, body: %{text: "retry answer"}}}
    assert Process.alive?(context.coalescer)
  end

  test "surface finalization does not acknowledge an unexpected dispatcher failure", context do
    Application.put_env(:lemon_router, :failure_boundary_dispatch, :raise)
    state = %{run_id: "run-surface", session_key: context.session_key, saw_delta: true}
    event = Event.new(:run_completed, %{completed: %{ok: true, answer: "final answer"}}, %{})

    assert_raise RuntimeError, "dispatcher callback bug", fn ->
      SurfaceManager.finalize_answer(state, event, %{})
    end
  end

  test "surface delivery rejection remains explicit and does not finalize its coalescer",
       context do
    Application.put_env(:lemon_router, :failure_boundary_dispatch, {:error, :unavailable})
    state = %{run_id: "run-surface", session_key: context.session_key, saw_delta: true}
    event = Event.new(:run_completed, %{completed: %{ok: true, answer: "final answer"}}, %{})

    assert {:error, {:dispatch_failed, :unavailable}} =
             SurfaceManager.finalize_answer(state, event, %{})

    assert %{finalized: false} = :sys.get_state(context.coalescer)
  end

  defp await_replacement(supervisor, old_pid, attempts \\ 500)

  defp await_replacement(_supervisor, _old_pid, 0), do: flunk("coalescer was not restarted")

  defp await_replacement(supervisor, old_pid, attempts) do
    case DynamicSupervisor.which_children(supervisor) do
      [{:undefined, pid, :worker, _}] when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        Process.sleep(10)
        await_replacement(supervisor, old_pid, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_router, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_router, key, value)
end
