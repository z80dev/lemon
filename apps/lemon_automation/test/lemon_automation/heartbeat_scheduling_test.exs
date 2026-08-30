defmodule LemonAutomation.HeartbeatSchedulingTest do
  use ExUnit.Case, async: false

  alias LemonAgent.Workspace.HeartbeatStore
  alias LemonAutomation.{CronManager, HeartbeatManager}

  test "selects cron only when the interval is exactly representable" do
    assert {:cron, "*/1 * * * *"} = HeartbeatManager.scheduling_mode(60_000)
    assert {:cron, "*/5 * * * *"} = HeartbeatManager.scheduling_mode(5 * 60_000)
    assert {:cron, "0 */2 * * *"} = HeartbeatManager.scheduling_mode(2 * 60 * 60_000)
    assert {:cron, "0 0 * * *"} = HeartbeatManager.scheduling_mode(24 * 60 * 60_000)

    assert :timer = HeartbeatManager.scheduling_mode(30_000)
    assert :timer = HeartbeatManager.scheduling_mode(90_000)
    assert :timer = HeartbeatManager.scheduling_mode(90 * 60_000)
    assert :timer = HeartbeatManager.scheduling_mode(5 * 60 * 60_000)
    assert :timer = HeartbeatManager.scheduling_mode(25 * 60_000)
    assert {:error, :invalid_interval} = HeartbeatManager.scheduling_mode(0)
  end

  test "creates and reconfigures one cron heartbeat with mutable fields only" do
    with_agent(fn agent_id ->
      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 5 * 60_000,
                 prompt: "first"
               })

      first = heartbeat_job!(agent_id)
      assert first.enabled
      assert first.schedule == "*/5 * * * *"

      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 10 * 60_000,
                 prompt: "second"
               })

      second = heartbeat_job!(agent_id)
      assert second.id == first.id
      assert second.enabled
      assert second.schedule == "*/10 * * * *"
      assert second.prompt == "second"
      assert Enum.count(CronManager.list(), &(&1.name == "heartbeat-#{agent_id}")) == 1
    end)
  end

  test "cron to timer transition disables the old cron mechanism" do
    with_agent(fn agent_id ->
      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 120_000,
                 prompt: "cron"
               })

      cron_job_id = heartbeat_job!(agent_id).id

      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 30_000,
                 prompt: "timer"
               })

      refute heartbeat_job!(agent_id).enabled
      assert heartbeat_job!(agent_id).id == cron_job_id

      state = :sys.get_state(HeartbeatManager)
      assert %{interval_ms: 30_000, prompt: "timer"} = state.timer_configs[agent_id]
      assert match?({:timer, ref} when is_reference(ref), state.active_heartbeats[agent_id])
    end)
  end

  test "timer to cron transition cancels the timer and re-enables the cron job" do
    with_agent(fn agent_id ->
      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 30_000,
                 prompt: "timer"
               })

      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 120_000,
                 prompt: "cron"
               })

      job = heartbeat_job!(agent_id)
      assert job.enabled
      assert job.schedule == "*/2 * * * *"

      state = :sys.get_state(HeartbeatManager)
      refute Map.has_key?(state.timer_configs, agent_id)
      assert state.active_heartbeats[agent_id] == job.id
    end)
  end

  test "nonrepresentable long intervals stay exact on timers" do
    with_agent(fn agent_id ->
      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 90 * 60_000,
                 prompt: "ninety minutes"
               })

      state = :sys.get_state(HeartbeatManager)
      assert state.timer_configs[agent_id].interval_ms == 90 * 60_000
      assert heartbeat_job(agent_id) == nil

      assert :ok =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: 5 * 60 * 60_000,
                 prompt: "five hours"
               })

      state = :sys.get_state(HeartbeatManager)
      assert state.timer_configs[agent_id].interval_ms == 5 * 60 * 60_000
      assert heartbeat_job(agent_id) == nil
    end)
  end

  test "disable and cleanup leave no timer or cron job behind" do
    agent_id = unique_agent()

    assert :ok =
             HeartbeatManager.update_config(agent_id, %{
               enabled: true,
               interval_ms: 15_000,
               prompt: "HEARTBEAT"
             })

    assert :ok = HeartbeatManager.update_config(agent_id, %{enabled: false})

    state = :sys.get_state(HeartbeatManager)
    refute Map.has_key?(state.active_heartbeats, agent_id)
    refute Map.has_key?(state.timer_configs, agent_id)
    refute Map.has_key?(state.in_flight, agent_id)
    assert HeartbeatStore.get_config(agent_id).enabled == false

    cleanup_agent(agent_id)
    assert heartbeat_job(agent_id) == nil
    assert HeartbeatStore.get_config(agent_id) == nil
  end

  test "rejects invalid timer intervals without installing a mechanism" do
    with_agent(fn agent_id ->
      assert {:error, :invalid_interval} =
               HeartbeatManager.update_config(agent_id, %{
                 enabled: true,
                 interval_ms: -1,
                 prompt: "bad"
               })

      state = :sys.get_state(HeartbeatManager)
      refute Map.has_key?(state.active_heartbeats, agent_id)
      assert heartbeat_job(agent_id) == nil
      assert HeartbeatStore.get_config(agent_id) == nil
    end)
  end

  defp with_agent(fun) do
    agent_id = unique_agent()

    try do
      fun.(agent_id)
    after
      cleanup_agent(agent_id)
    end
  end

  defp cleanup_agent(agent_id) do
    if Process.whereis(HeartbeatManager) do
      _ = HeartbeatManager.update_config(agent_id, %{enabled: false})
    end

    if job = heartbeat_job(agent_id) do
      _ = CronManager.remove(job.id)
    end

    HeartbeatStore.delete_config(agent_id)
    HeartbeatStore.delete_last(agent_id)
  end

  defp heartbeat_job!(agent_id), do: heartbeat_job(agent_id) || flunk("missing heartbeat job")

  defp heartbeat_job(agent_id) do
    Enum.find(CronManager.list(), &(&1.name == "heartbeat-#{agent_id}"))
  end

  defp unique_agent, do: "heartbeat-scheduling-#{System.unique_integer([:positive])}"
end
