defmodule LemonCore.Runtime.HealthTest do
  use ExUnit.Case, async: true

  alias LemonCore.Runtime.Health

  describe "running?/2" do
    test "returns false when nothing is listening on the port" do
      # Pick an unlikely port; if by chance it is in use the test still passes
      # because we only assert false here and false is the common case.
      refute Health.running?(19_999, timeout_ms: 200)
    end

    test "requires Lemon's health body, not an unrelated HTTP 200" do
      for {body, expected} <- [
            {~s({"ok":true}), true},
            {~s({"ok":false}), false},
            {"unrelated server", false}
          ] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listener)

        server =
          Task.async(fn ->
            {:ok, socket} = :gen_tcp.accept(listener)
            {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.0 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
              )

            :gen_tcp.close(socket)
          end)

        assert Health.running?(port, timeout_ms: 1_000) == expected
        Task.await(server)
        :gen_tcp.close(listener)
      end
    end
  end

  describe "check/2" do
    test "names the missing applications of an unhealthy Lemon runtime" do
      for {status, body, expected} <- [
            {"200 OK", ~s({"ok":true}), {:ok, :healthy}},
            {"503 Service Unavailable", ~s({"ok":false,"missing":["lemon_web"]}),
             {:error, {:unhealthy, ["lemon_web"]}}},
            {"503 Service Unavailable", ~s({"ok":false,"missing":[]}), {:error, :bad_response}},
            {"503 Service Unavailable", ~s({"ok":false,"missing":["Not An App"]}),
             {:error, :bad_response}},
            {"500 Internal Server Error", ~s({"ok":false}), {:error, :bad_response}}
          ] do
        {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
        {:ok, port} = :inet.port(listener)

        server =
          Task.async(fn ->
            {:ok, socket} = :gen_tcp.accept(listener)
            {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{status}\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"
              )

            :gen_tcp.close(socket)
          end)

        assert Health.check(port, timeout_ms: 1_000) == expected
        Task.await(server)
        :gen_tcp.close(listener)
      end
    end
  end

  describe "runtime_status/1" do
    test "a node that runs no profile has no expected applications" do
      assert Health.runtime_status(profile: :none) == %{ok: true, profile: nil, missing: []}
    end

    test "an unknown configured profile is unhealthy" do
      assert %{ok: false, error: :unknown_profile} =
               Health.runtime_status(profile: {:error, :unknown_profile})
    end

    test "a profile expects exactly its :permanent applications" do
      %{profile: :runtime_full, missing: missing, ok: ok} =
        Health.runtime_status(profile: {:ok, :runtime_full})

      assert missing -- LemonCore.Runtime.Profile.running_apps(:runtime_full) == []
      assert ok == (missing == [])
    end

    test "the :apps option names the expected applications" do
      assert %{ok: true, missing: []} = Health.runtime_status(apps: [:kernel])

      assert %{ok: false, missing: [:nonexistent_app_xyz]} =
               Health.runtime_status(apps: [:kernel, :nonexistent_app_xyz])
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

defmodule LemonCore.Runtime.HealthFdLeakTest do
  # Runs outside the async pool: /proc/self/fd is VM-wide, so concurrently
  # running async tests opening sockets would otherwise skew the count.
  use ExUnit.Case, async: false

  alias LemonCore.Runtime.Health

  test "repeated failures on closed port do not leak file descriptors" do
    # Probe a closed port many times and confirm we don't run out of fds.
    # If sockets leak, this would eventually fail with {:error, :emfile} or similar.
    before_fds = count_open_fds()

    for _ <- 1..20 do
      Health.running?(19_997, timeout_ms: 100)
    end

    after_fds = count_open_fds()

    # A leak would add roughly one fd per probe (20); allow a margin for transient
    # fds from background processes.
    assert after_fds - before_fds < 15,
           "Expected fewer than 15 new fds, got #{after_fds - before_fds} (before=#{before_fds}, after=#{after_fds})"
  end

  # Returns a count of open file descriptors for the VM (Unix only).
  # Falls back to 0 on platforms that don't support /proc.
  defp count_open_fds do
    fd_dir = "/proc/self/fd"

    if File.dir?(fd_dir) do
      fd_dir |> File.ls!() |> length()
    else
      0
    end
  end
end
