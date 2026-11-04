defmodule LemonCore.Config.AutomationTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.Automation

  test "catch-up and retention defaults and overrides validate" do
    assert %Automation{catch_up_missed: true, run_retention_per_job: 100} =
             Automation.resolve(%{})

    config =
      Automation.resolve(%{
        "automation" => %{
          "catch_up_missed" => false,
          "run_retention_per_job" => 0
        }
      })

    assert config.catch_up_missed == false
    assert config.run_retention_per_job == 0
    assert Automation.validate(config, []) == []

    assert ["automation.catch_up_missed: must be a boolean"] =
             Automation.validate(%Automation{catch_up_missed: "false"}, [])

    for invalid <- [-1, "100", nil] do
      assert ["automation.run_retention_per_job: must be a non-negative integer"] =
               Automation.validate(%Automation{run_retention_per_job: invalid}, [])
    end
  end

  test "cron failure cooldown defaults to six hours and validates overrides" do
    assert Automation.resolve(%{}).failure_alert_cooldown_ms == 21_600_000

    for value <- [0, 1, 21_600_000] do
      config = Automation.resolve(%{"cron" => %{"failure_alert_cooldown_ms" => value}})
      assert config.failure_alert_cooldown_ms == value
      assert Automation.validate(config, []) == []
    end

    for value <- [-1, nil, false, "3600", 1.5] do
      config = Automation.resolve(%{"cron" => %{"failure_alert_cooldown_ms" => value}})

      assert ["cron.failure_alert_cooldown_ms: must be a non-negative integer"] =
               Automation.validate(config, [])
    end
  end
end
