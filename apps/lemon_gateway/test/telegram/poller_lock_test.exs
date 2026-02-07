defmodule LemonGateway.Telegram.PollerLockTest do
  # This test mutates `LEMON_LOCK_DIR` which is process-global.
  use ExUnit.Case, async: false

  alias LemonGateway.Telegram.PollerLock

  @tag :tmp_dir
  test "cleans up stale file lock with dead os_pid", %{tmp_dir: tmp_dir} do
    lock_dir = Path.join(tmp_dir, "locks")
    System.put_env("LEMON_LOCK_DIR", lock_dir)

    account_id = "test"
    token = "123456:token"

    # Simulate a stale lock file.
    fingerprint = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    path = Path.join(lock_dir, "telegram_poller_#{account_id}_#{fingerprint}.lock")
    File.mkdir_p!(lock_dir)
    File.write!(path, "os_pid=0\nnode=stale\n")

    assert :ok = PollerLock.acquire(account_id, token)
    assert File.exists?(path)

    assert :ok = PollerLock.release(account_id, token)
    refute File.exists?(path)
  after
    System.delete_env("LEMON_LOCK_DIR")
  end

  @tag :tmp_dir
  test "steals stale lock even if os_pid is alive (pid reuse protection)", %{tmp_dir: tmp_dir} do
    lock_dir = Path.join(tmp_dir, "locks")
    System.put_env("LEMON_LOCK_DIR", lock_dir)
    System.put_env("LEMON_TELEGRAM_POLLER_LOCK_STALE_MS", "1")

    account_id = "test"
    token = "123456:token"

    fingerprint = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    path = Path.join(lock_dir, "telegram_poller_#{account_id}_#{fingerprint}.lock")
    File.mkdir_p!(lock_dir)

    # PID 1 exists on Unix, so `kill -0 1` is alive. We still want to steal if the lock file is stale
    # and the PID does not look like a BEAM process.
    File.write!(path, "os_pid=1\nnode=stale\n")
    :ok = File.touch(path, {{2000, 1, 1}, {0, 0, 0}})

    assert :ok = PollerLock.acquire(account_id, token)
    assert :ok = PollerLock.release(account_id, token)
    refute File.exists?(path)
  after
    System.delete_env("LEMON_LOCK_DIR")
    System.delete_env("LEMON_TELEGRAM_POLLER_LOCK_STALE_MS")
  end
end
