defmodule LemonAi.ProviderAdmissionTest do
  use ExUnit.Case, async: false

  alias LemonAi.{CallDispatcher, CircuitBreaker, RateLimiter}
  alias LemonAi.CallDispatcher.Slots

  setup do
    provider = "admission-#{System.unique_integer([:positive])}"
    start_supervised!({RateLimiter, provider: provider, max_tokens: 100})
    start_supervised!({CircuitBreaker, provider: provider})
    :ok = CallDispatcher.set_concurrency_cap(provider, 1)

    on_exit(fn ->
      case GenServer.whereis(Slots.via(provider)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, pid)
      end

      :ets.match_delete(Slots, {{:lease, provider, :_}, :_})
      :ets.delete(Slots, {:provider, provider})
    end)

    {:ok, provider: provider}
  end

  test "a stopped authority fails closed and a replacement retains live leases and the cap", %{
    provider: provider
  } do
    parent = self()

    holder =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn ->
          send(parent, :admitted)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :admitted
    authority = GenServer.whereis(Slots.via(provider))
    :ok = DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, authority)

    assert {:error, :admission_unavailable} =
             CallDispatcher.dispatch(provider, fn -> flunk("admitted without an authority") end,
               queue_timeout_ms: 0
             )

    assert LemonAi.Error.classify(:admission_unavailable) == :transient
    assert LemonAi.Error.retryable?(:admission_unavailable)
    # The rejected attempt may rebuild the authority, but never runs its callback.
    assert CallDispatcher.get_concurrency_cap(provider) == 1
    assert CallDispatcher.get_active_requests(provider) == 1

    assert {:error, :max_concurrency} =
             CallDispatcher.dispatch(
               provider,
               fn -> flunk("replacement forgot the live lease") end,
               queue_timeout_ms: 0
             )

    send(holder.pid, :finish)
    assert Task.await(holder) == {:ok, :finished}
    assert CallDispatcher.get_active_requests(provider) == 0
    assert {:ok, :next} = CallDispatcher.dispatch(provider, fn -> {:ok, :next} end)
  end

  test "one saturated and suspended authority cannot block another provider", %{
    provider: provider
  } do
    {:ok, authority} = Slots.ensure_started(provider)
    parent = self()

    holder =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn ->
          send(parent, :at_cap)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :at_cap
    assert CallDispatcher.get_active_requests(provider) == 1
    :ok = :sys.suspend(authority)
    on_exit(fn -> if Process.alive?(authority), do: :sys.resume(authority) end)

    other = "independent-#{System.unique_integer([:positive])}"
    start_supervised!({RateLimiter, provider: other, max_tokens: 100}, id: {RateLimiter, other})
    start_supervised!({CircuitBreaker, provider: other}, id: {CircuitBreaker, other})

    on_exit(fn ->
      case GenServer.whereis(Slots.via(other)) do
        nil -> :ok
        pid -> DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, pid)
      end

      :ets.delete(Slots, {:provider, other})
      :ets.match_delete(Slots, {{:lease, other, :_}, :_})
    end)

    assert {:ok, :independent} =
             CallDispatcher.dispatch(other, fn -> {:ok, :independent} end, queue_timeout_ms: 0)

    :ok = :sys.resume(authority)
    send(holder.pid, :finish)
    assert Task.await(holder) == {:ok, :finished}
  end

  test "completion during authority downtime is not resurrected by restart", %{provider: provider} do
    parent = self()

    holder =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn ->
          send(parent, :admitted)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :admitted
    authority = GenServer.whereis(Slots.via(provider))
    :ok = DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, authority)
    send(holder.pid, :finish)
    assert Task.await(holder) == {:ok, :finished}

    assert {:ok, _replacement} =
             DynamicSupervisor.start_child(
               LemonAi.ProviderSupervisor,
               {Slots, provider: provider}
             )

    assert CallDispatcher.get_active_requests(provider) == 0
    assert {:ok, :next} = CallDispatcher.dispatch(provider, fn -> {:ok, :next} end)
  end

  test "dispatcher restart cannot reset a provider's occupied slot", %{provider: provider} do
    parent = self()

    holder =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn ->
          send(parent, :admitted)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :admitted
    previous_state = :sys.get_state(CallDispatcher)

    on_exit(fn ->
      if Process.whereis(CallDispatcher) == nil do
        Supervisor.restart_child(LemonAi.Supervisor, CallDispatcher)
      end

      :sys.replace_state(CallDispatcher, fn _ -> previous_state end)
    end)

    :ok = Supervisor.terminate_child(LemonAi.Supervisor, CallDispatcher)
    assert {:ok, _replacement} = Supervisor.restart_child(LemonAi.Supervisor, CallDispatcher)

    assert {:error, :max_concurrency} =
             CallDispatcher.dispatch(provider, fn -> flunk("dispatcher reset the lease") end,
               queue_timeout_ms: 0
             )

    send(holder.pid, :finish)
    assert Task.await(holder) == {:ok, :finished}
  end

  test "diagnostics report a missing authority as unavailable rather than idle", %{
    provider: provider
  } do
    authority = GenServer.whereis(Slots.via(provider))
    :ok = DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, authority)
    assert provider in CallDispatcher.get_state().unavailable
    assert CallDispatcher.get_active_requests(provider) == 0
  end

  test "queued admission fails closed when its authority stops", %{provider: provider} do
    parent = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:lemon_ai, :dispatcher, :queued],
        fn _, _, metadata, _ ->
          if metadata.provider == provider, do: send(parent, :queued)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    holder =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn ->
          send(parent, :admitted)

          receive do
            :finish -> {:ok, :finished}
          end
        end)
      end)

    assert_receive :admitted

    waiter =
      Task.async(fn ->
        CallDispatcher.dispatch(provider, fn -> flunk("interrupted waiter was admitted") end,
          queue_timeout_ms: 60_000
        )
      end)

    assert_receive :queued
    authority = GenServer.whereis(Slots.via(provider))
    :ok = DynamicSupervisor.terminate_child(LemonAi.ProviderSupervisor, authority)
    assert Task.await(waiter) == {:error, :admission_unavailable}

    assert {:ok, _replacement} =
             DynamicSupervisor.start_child(
               LemonAi.ProviderSupervisor,
               {Slots, provider: provider}
             )

    assert CallDispatcher.get_active_requests(provider) == 1
    send(holder.pid, :finish)
    assert Task.await(holder) == {:ok, :finished}
    assert CallDispatcher.get_active_requests(provider) == 0
  end
end
