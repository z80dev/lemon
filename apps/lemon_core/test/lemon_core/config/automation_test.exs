defmodule LemonCore.Config.AutomationTest do
  use ExUnit.Case, async: true

  alias LemonCore.Config.Automation

  test "the daily brief is off unless a time is configured" do
    assert %Automation{daily_brief: nil} = Automation.resolve(%{})
    assert %Automation{daily_brief: nil} = Automation.resolve(%{"automation" => %{}})

    assert %Automation{daily_brief: nil} =
             Automation.resolve(%{"automation" => %{"daily_brief" => false}})

    assert %Automation{daily_brief: "08:00"} =
             Automation.resolve(%{"automation" => %{"daily_brief" => " 08:00 "}})
  end

  test "only HH:MM 24-hour times validate" do
    assert [] = Automation.validate(%Automation{daily_brief: "7:05"}, [])
    assert [] = Automation.validate(%Automation{daily_brief: "23:59"}, [])

    for bad <- ["24:00", "8am", "08:60", "0800"] do
      assert ["automation.daily_brief: must be a HH:MM 24-hour time"] =
               Automation.validate(%Automation{daily_brief: bad}, [])
    end
  end

  test "parse_time/1 returns hour and minute" do
    assert {:ok, {7, 5}} = Automation.parse_time("7:05")
    assert :error = Automation.parse_time(nil)
  end

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
end
