defmodule LemonCore.Runtime.HealthTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Health

  describe "running?/2" do
    test "returns false when nothing is listening on the port" do
      # Pick an unlikely port; if by chance it is in use the test still passes
      # because we only assert false here and false is the common case.
      refute Health.running?(19_999, timeout_ms: 200)
    end
  end

  describe "await/2" do
    test "returns {:error, :timeout} when port is closed" do
      assert {:error, :timeout} = Health.await(19_998, timeout_ms: 300)
    end
  end

  describe "status/1" do
    test "returns :ok status when no expected apps are specified" do
      result = Health.status()
      assert result.status == :ok
      assert is_list(result.apps)
      assert result.missing == []
    end

    test "reports missing apps" do
      result = Health.status(apps: [:nonexistent_app_xyz])
      assert result.status == :degraded
      assert :nonexistent_app_xyz in result.missing
    end

    test "started apps are included in apps list" do
      result = Health.status()
      # :kernel is always started
      assert :kernel in result.apps
    end
  end
end
