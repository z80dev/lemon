defmodule LemonControlPlane.Methods.CronMethodsTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.CronManager
  alias LemonControlPlane.Methods.CronUpdate

  setup do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "cp-cron-update-#{token}",
        schedule: "0 0 1 1 *",
        enabled: false,
        agent_id: "cp_agent_#{token}",
        session_key: "agent:cp_agent_#{token}:main",
        prompt: "ping",
        timezone: "UTC"
      })

    on_exit(fn ->
      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "cron.update rejects sessionKey patch", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(
               %{"id" => job.id, "sessionKey" => "agent:other:main", "enabled" => true},
               %{}
             )

    assert msg =~ "Immutable fields cannot be updated"
    assert msg =~ "session_key"
  end

  test "cron.update rejects agentId patch", %{job: job} do
    assert {:error, {:invalid_request, msg, nil}} =
             CronUpdate.handle(%{"id" => job.id, "agentId" => "other"}, %{})

    assert msg =~ "Immutable fields cannot be updated"
    assert msg =~ "agent_id"
  end

  test "cron.update still updates mutable fields", %{job: job} do
    assert {:ok, %{"id" => id, "updated" => true}} =
             CronUpdate.handle(%{"id" => job.id, "enabled" => true, "timezone" => "UTC"}, %{})

    assert id == job.id
  end
end
