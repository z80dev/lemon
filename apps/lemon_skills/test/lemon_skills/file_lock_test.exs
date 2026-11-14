defmodule LemonSkills.FileLockTest do
  use ExUnit.Case, async: true

  alias LemonSkills.FileLock

  @moduletag :tmp_dir

  test "holds an exclusive lock during the callback and removes it afterward", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "state.lock")

    assert FileLock.with_lock(path, fn ->
             assert File.exists?(path)
             assert FileLock.with_lock(path, fn -> flunk("lock is already held") end, 1) ==
                      {:error, :lock_timeout}

             :callback_result
           end) == :callback_result

    refute File.exists?(path)
    assert FileLock.with_lock(path, fn -> :acquired_again end) == :acquired_again
  end

  test "cleans up when the callback raises", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "state.lock")

    assert_raise RuntimeError, "callback failed", fn ->
      FileLock.with_lock(path, fn -> raise "callback failed" end)
    end

    refute File.exists?(path)
  end

  test "returns timeout when the supplied retry budget is exhausted", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "state.lock")
    assert FileLock.with_lock(path, fn -> flunk("no retries remain") end, 0) ==
             {:error, :lock_timeout}

    refute File.exists?(path)
  end

  test "returns file errors without invoking the callback", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "missing", "state.lock"])
    assert FileLock.with_lock(path, fn -> flunk("lock could not be acquired") end) ==
             {:error, {:lock_failed, :enoent}}
  end
end
