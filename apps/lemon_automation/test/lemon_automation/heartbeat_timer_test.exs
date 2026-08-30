defmodule LemonAutomation.HeartbeatTimerTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.HeartbeatStore
  alias LemonAutomation.{CronManager, CronStore, HeartbeatManager}
  alias LemonCore.{Bus, Event}

  defmodule SynchronousRouter do
    @moduledoc false

    def submit(params) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:timer_router_submit, params})

      send(
        self(),
        Event.new(:run_completed, %{completed: %{ok: true, answer: "HEARTBEAT_OK"}})
      )

      {:ok, params.run_id}
    end
  end

  defmodule BlockingRouter do
    @moduledoc false

    def submit(params) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:timer_router_started, self(), params})

      receive do
        :release -> :ok
      end

      send(
        self(),
        Event.new(:run_completed, %{completed: %{ok: true, answer: "HEARTBEAT_OK"}})
      )

      {:ok, params.run_id}
    end
  end

  defmodule ErrorRouter do
    @moduledoc false
    def submit(_params), do: {:error, :busy}
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:heartbeat_skip_telemetry, event, measurements, metadata})
  end

  setup do
    previous_router = Application.get_env(:lemon_automation, :heartbeat_router_mod)
    previous_waiter = Application.get_env(:lemon_automation, :heartbeat_waiter_mod)
    previous_bus = Application.get_env(:lemon_automation, :heartbeat_bus_mod)

    on_exit(fn ->
      restore_env(:heartbeat_router_mod, previous_router)
      restore_env(:heartbeat_waiter_mod, previous_waiter)
      restore_env(:heartbeat_bus_mod, previous_bus)
      :persistent_term.erase({SynchronousRouter, :test_pid})
      :persistent_term.erase({BlockingRouter, :test_pid})
    end)

    :ok
  end

  test "records synchronous timer completion and suppression in HeartbeatStore" do
    agent_id = unique_agent()
    stats_before = HeartbeatManager.stats()
    :persistent_term.put({SynchronousRouter, :test_pid}, self())
    Application.put_env(:lemon_automation, :heartbeat_router_mod, SynchronousRouter)
    Bus.subscribe("cron")

    try do
      assert :ok = configure_timer(agent_id)
      send(HeartbeatManager, {:timer_heartbeat, agent_id})

      assert_receive {:timer_router_submit, params}, 500
      assert params.meta.timer_based
      assert params.run_id

      assert eventually(fn ->
               case HeartbeatStore.get_last(agent_id) do
                 %{status: :ok, terminal_status: :completed, suppressed: true} -> true
                 _ -> false
               end
             end)

      last = HeartbeatStore.get_last(agent_id)
      assert last.response == "HEARTBEAT_OK"
      assert last.router_run_id == params.run_id
      assert CronStore.get_run(last.run_id) == nil
      assert_receive %Event{type: :heartbeat_suppressed}, 500

      stats = HeartbeatManager.stats()
      assert stats.total_heartbeats == stats_before.total_heartbeats + 1
      assert stats.suppressed == stats_before.suppressed + 1
      assert eventually(fn -> not in_flight?(agent_id) end)
    after
      Bus.unsubscribe("cron")
      cleanup_agent(agent_id)
    end
  end

  test "records timer submission failures as terminal alerts" do
    agent_id = unique_agent()
    stats_before = HeartbeatManager.stats()
    Application.put_env(:lemon_automation, :heartbeat_router_mod, ErrorRouter)

    try do
      assert :ok = configure_timer(agent_id)
      send(HeartbeatManager, {:timer_heartbeat, agent_id})

      assert eventually(fn ->
               case HeartbeatStore.get_last(agent_id) do
                 %{status: :failed, terminal_status: :failed, suppressed: false} -> true
                 _ -> false
               end
             end)

      last = HeartbeatStore.get_last(agent_id)
      assert last.response =~ "HEARTBEAT_ERROR"
      assert eventually(fn -> not in_flight?(agent_id) end)

      stats = HeartbeatManager.stats()
      assert stats.total_heartbeats == stats_before.total_heartbeats + 1
      assert stats.alerts == stats_before.alerts + 1
    after
      cleanup_agent(agent_id)
    end
  end

  test "skips overlapping timer ticks and clears the in-flight guard" do
    agent_id = unique_agent()
    stats_before = HeartbeatManager.stats()
    handler_id = {__MODULE__, self(), make_ref()}
    :persistent_term.put({BlockingRouter, :test_pid}, self())
    Application.put_env(:lemon_automation, :heartbeat_router_mod, BlockingRouter)

    :ok =
      :telemetry.attach(
        handler_id,
        [:lemon, :heartbeat, :skipped],
        &__MODULE__.handle_telemetry/4,
        self()
      )

    try do
      assert :ok = configure_timer(agent_id)
      send(HeartbeatManager, {:timer_heartbeat, agent_id})

      assert_receive {:timer_router_started, worker_pid, first_params}, 500
      assert in_flight?(agent_id)

      send(HeartbeatManager, {:timer_heartbeat, agent_id})

      assert_receive {:heartbeat_skip_telemetry, [:lemon, :heartbeat, :skipped], %{count: 1},
                      %{agent_id: ^agent_id, reason: :overlap}},
                     500

      refute_receive {:timer_router_started, _, _}, 50

      stats = HeartbeatManager.stats()
      assert stats.skipped_overlap == stats_before.skipped_overlap + 1

      send(worker_pid, :release)

      assert eventually(fn ->
               case HeartbeatStore.get_last(agent_id) do
                 %{router_run_id: run_id, suppressed: true} when run_id == first_params.run_id ->
                   true

                 _ ->
                   false
               end
             end)

      assert eventually(fn -> not in_flight?(agent_id) end)
    after
      :telemetry.detach(handler_id)
      cleanup_agent(agent_id)
    end
  end

  defp configure_timer(agent_id) do
    HeartbeatManager.update_config(agent_id, %{
      enabled: true,
      interval_ms: 10_000,
      prompt: "HEARTBEAT"
    })
  end

  defp in_flight?(agent_id) do
    HeartbeatManager
    |> :sys.get_state()
    |> Map.fetch!(:in_flight)
    |> Map.has_key?(agent_id)
  end

  defp cleanup_agent(agent_id) do
    if Process.whereis(HeartbeatManager) do
      _ = HeartbeatManager.update_config(agent_id, %{enabled: false})
    end

    CronManager.list()
    |> Enum.filter(&(&1.name == "heartbeat-#{agent_id}"))
    |> Enum.each(&CronManager.remove(&1.id))

    HeartbeatStore.delete_config(agent_id)
    HeartbeatStore.delete_last(agent_id)
  end

  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(5)
        do_eventually(fun, deadline)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_automation, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_automation, key, value)

  defp unique_agent, do: "heartbeat-timer-#{System.unique_integer([:positive])}"
end
