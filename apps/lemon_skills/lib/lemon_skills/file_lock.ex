defmodule LemonSkills.FileLock do
  @moduledoc false

  @lock_sleep_ms 10

  def with_lock(lock_path, fun, retries \\ 100) do
    acquire_lock(to_charlist(lock_path), fun, retries)
  end

  defp acquire_lock(_lock_path, _fun, 0), do: {:error, :lock_timeout}

  defp acquire_lock(lock_path, fun, retries) do
    case :file.open(lock_path, [:write, :exclusive]) do
      {:ok, fd} ->
        try do
          fun.()
        after
          :file.close(fd)
          :file.delete(lock_path)
        end

      {:error, :eexist} ->
        Process.sleep(@lock_sleep_ms)
        acquire_lock(lock_path, fun, retries - 1)

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end
end
