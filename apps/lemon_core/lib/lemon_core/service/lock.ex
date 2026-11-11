defmodule LemonCore.Service.Lock do
  @moduledoc false
  alias LemonCore.Service.{Identity, Role, Unit}

  def with_lock(label, opts, fun) do
    dir = Role.run_dir(opts)
    path = Path.join(dir, label <> ".lock")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- acquire(path, opts, false) do
      try do
        fun.()
      after
        File.rm(Path.join(path, "owner.json"))
        File.rmdir(path)
      end
    end
  end

  defp acquire(path, opts, reclaimed) do
    case File.mkdir(path) do
      :ok ->
        with :ok <- File.chmod(path, 0o700),
             {:ok, identity} <- Identity.capture(String.to_integer(System.pid()), opts),
             :ok <-
               Unit.atomic_write(Path.join(path, "owner.json"), Jason.encode!(identity), 0o600) do
          :ok
        else
          _ ->
            File.rmdir(path)
            {:error, :service_lock_failed}
        end

      {:error, :eexist} when not reclaimed ->
        reclaim(path, opts)

      _ ->
        {:error, :service_locked}
    end
  end

  defp reclaim(path, opts) do
    guard = path <> ".reclaim"

    case File.mkdir(guard) do
      :ok ->
        try do
          with {:ok, %{"pid" => pid, "started_at" => started}} <-
                 Identity.read_json(Path.join(path, "owner.json")),
               true <- Identity.gone?(%{pid: pid, started_at: started}, opts) do
            stale = path <> ".stale.#{System.unique_integer([:positive])}"

            case File.rename(path, stale) do
              :ok ->
                File.rm(Path.join(stale, "owner.json"))
                File.rmdir(stale)
                acquire(path, opts, true)

              _ ->
                {:error, :service_locked}
            end
          else
            _ -> {:error, :service_locked}
          end
        after
          File.rmdir(guard)
        end

      _ ->
        {:error, :service_locked}
    end
  end
end
