defmodule LemonCore.Runtime.HealthTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Health

  describe "running?/2" do
    test "returns false when nothing is listening on the port" do
      # Pick an unlikely port; if by chance it is in use the test still passes
      # because we only assert false here and false is the common case.
      refute Health.running?(19_999, timeout_ms: 200)
    end

    test "repeated failures on closed port do not leak file descriptors" do
      # Probe a closed port many times and confirm we don't run out of fds.
      # If sockets leak, this would eventually fail with {:error, :emfile} or similar.
      before_fds = count_open_fds()

      for _ <- 1..20 do
        Health.running?(19_997, timeout_ms: 100)
      end

      after_fds = count_open_fds()

      # Allow a small margin for any transient fds (e.g. from test infra), but
      # reject a large growth that would indicate socket leaks.
      assert after_fds - before_fds < 5,
             "Expected fewer than 5 new fds, got #{after_fds - before_fds} (before=#{before_fds}, after=#{after_fds})"
    end
  end

  describe "await/2" do
    test "returns {:error, :timeout} when port is closed" do
      assert {:error, :timeout} = Health.await(19_998, timeout_ms: 300)
    end
  end

  # Returns a count of open file descriptors for the current process (Unix only).
  # Falls back to 0 on platforms that don't support /proc.
  defp count_open_fds do
    fd_dir = "/proc/self/fd"

    if File.dir?(fd_dir) do
      fd_dir |> File.ls!() |> length()
    else
      0
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
