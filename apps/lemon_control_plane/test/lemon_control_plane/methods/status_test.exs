defmodule LemonControlPlane.Methods.StatusTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Methods.{Health, Status}

  test "health returns public runtime summary" do
    assert {:ok, result} = Health.handle(%{}, %{})

    assert result["ok"] == true
    assert is_integer(result["uptime_ms"])
    assert is_float(result["memory_mb"])
    assert is_integer(result["schedulers"])
    assert result["summary"]["action"] == "health"
    assert result["summary"]["ok"] == true
    assert result["summary"]["uptimeMs"] == result["uptime_ms"]
    assert result["summary"]["memoryMb"] == result["memory_mb"]
    assert result["summary"]["schedulerCount"] == result["schedulers"]
    assert result["summary"]["cleanup"]["includesRawProcessState"] == false
    assert result["summary"]["cleanup"]["includesCredentialValues"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
  end

  test "returns BEAM runtime capacity counters" do
    assert {:ok, result} = Status.handle(%{}, %{})

    assert result["server"]["version"] == LemonControlPlane.server_version()
    assert is_integer(result["server"]["beam"]["processCount"])
    assert result["server"]["beam"]["processCount"] > 0
    assert result["server"]["beam"]["processLimit"] >= result["server"]["beam"]["processCount"]
    assert is_integer(result["server"]["beam"]["portCount"])
    assert result["server"]["beam"]["portLimit"] >= result["server"]["beam"]["portCount"]
    assert is_integer(result["server"]["beam"]["atomCount"])
    assert result["server"]["beam"]["atomLimit"] >= result["server"]["beam"]["atomCount"]
    assert is_integer(result["server"]["beam"]["runQueue"])
    assert result["summary"]["action"] == "status"
    assert result["summary"]["version"] == result["server"]["version"]
    assert result["summary"]["uptimeMs"] == result["server"]["uptime_ms"]
    assert result["summary"]["memoryMb"] == result["server"]["memory_mb"]
    assert result["summary"]["schedulerCount"] == result["server"]["schedulers"]
    assert result["summary"]["processCount"] == result["server"]["beam"]["processCount"]
    assert result["summary"]["processLimit"] == result["server"]["beam"]["processLimit"]
    assert result["summary"]["portCount"] == result["server"]["beam"]["portCount"]
    assert result["summary"]["portLimit"] == result["server"]["beam"]["portLimit"]
    assert result["summary"]["atomCount"] == result["server"]["beam"]["atomCount"]
    assert result["summary"]["atomLimit"] == result["server"]["beam"]["atomLimit"]
    assert result["summary"]["runQueue"] == result["server"]["beam"]["runQueue"]
    assert result["summary"]["connectionCount"] == result["connections"]["active"]
    assert result["summary"]["activeRunCount"] == result["runs"]["active"]
    assert result["summary"]["configuredChannelCount"] == length(result["channels"]["configured"])
    assert result["summary"]["connectedChannelCount"] == length(result["channels"]["connected"])
    assert result["summary"]["installedSkillCount"] == result["skills"]["installed"]
    assert result["summary"]["enabledSkillCount"] == result["skills"]["enabled"]
    assert result["summary"]["cleanup"]["includesRawProcessState"] == false
    assert result["summary"]["cleanup"]["includesChannelCredentials"] == false
    assert result["summary"]["cleanup"]["includesSkillSources"] == false
    assert result["summary"]["cleanup"]["includesSecretValues"] == false
  end

  test "has correct method name and scopes" do
    assert Health.name() == "health"
    assert Health.scopes() == []
    assert Status.name() == "status"
    assert Status.scopes() == [:read]
  end
end
