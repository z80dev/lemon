defmodule LemonAutomation.CronManagerUpdateTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronStore}

  setup do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "update-test-#{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "agent_update_#{token}",
        session_key: "agent:agent_update_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn ->
      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "rejects session_key updates", %{job: job} do
    assert {:error, {:immutable_fields, [:session_key]}} =
             CronManager.update(job.id, %{session_key: "agent:changed:main"})

    assert CronStore.get_job(job.id).session_key == job.session_key
  end

  test "rejects agent_id and session_key updates across key variants", %{job: job} do
    assert {:error, {:immutable_fields, [:agent_id, :session_key]}} =
             CronManager.update(job.id, %{
               "agentId" => "agent_changed",
               "session_key" => "agent:changed:main"
             })

    persisted = CronStore.get_job(job.id)
    assert persisted.agent_id == job.agent_id
    assert persisted.session_key == job.session_key
  end

  test "allows mutable updates", %{job: job} do
    assert {:ok, updated} =
             CronManager.update(job.id, %{
               enabled: true,
               timezone: "America/New_York"
             })

    assert updated.enabled == true
    assert updated.timezone == "America/New_York"
  end
end
