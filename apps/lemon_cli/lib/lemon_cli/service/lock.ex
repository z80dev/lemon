defmodule LemonCli.Service.Lock do
  @moduledoc false

  alias LemonCli.Service.Role
  alias LemonCore.FileLock

  def with_lock(label, opts, fun) do
    dir = Keyword.get_lazy(opts, :run_dir, fn -> Role.run_dir(opts) end)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      case FileLock.with_lock_path(Path.join(dir, label <> ".lock"), opts, fn ->
             {:held, fun.()}
           end) do
        {:held, result} -> result
        {:error, :lock_timeout} -> {:error, :service_locked}
        {:error, _} -> {:error, :service_lock_failed}
      end
    end
  end
end
