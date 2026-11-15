defmodule LemonChannels.Telegram.PollerLock do
  @moduledoc """
  Token-scoped poller exclusion using the shared service identity lock.

  A supervised holder monitors the transport, releasing the lock even when the
  transport is killed. Separate OS processes share the service lock directory.
  """

  @supervisor LemonChannels.Adapters.Telegram.AsyncSupervisor

  def acquire(_account_id, token) do
    owner = self()
    name = lock_name(token)

    case :global.register_name(name, owner) do
      :yes ->
        case start_holder(owner, token) do
          :ok ->
            :ok

          error ->
            :global.unregister_name(name)
            error
        end

      :no ->
        {:error, :locked}
    end
  end

  def release(_account_id, token) do
    case Process.delete({__MODULE__, token}) do
      {pid, ref} ->
        monitor = Process.monitor(pid)
        send(pid, {:release, ref})

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

      nil ->
        :ok
    end

    if :global.whereis_name(lock_name(token)) == self(),
      do: :global.unregister_name(lock_name(token))

    :ok
  end

  defp start_holder(owner, token) do
    ref = make_ref()

    result =
      Task.Supervisor.start_child(@supervisor, fn ->
        monitor = Process.monitor(owner)

        result =
          LemonCore.Service.Lock.with_lock(label(token), lock_options(), fn ->
            send(owner, {ref, :ok})

            receive do
              {:release, ^ref} -> :ok
              {:DOWN, ^monitor, :process, ^owner, _} -> :ok
            end
          end)

        if result != :ok, do: send(owner, {ref, {:error, :locked}})
      end)

    case result do
      {:ok, pid} ->
        monitor = Process.monitor(pid)

        receive do
          {^ref, :ok} ->
            Process.demonitor(monitor, [:flush])
            Process.put({__MODULE__, token}, {pid, ref})
            :ok

          {^ref, error} ->
            Process.demonitor(monitor, [:flush])
            error

          {:DOWN, ^monitor, :process, ^pid, _} ->
            {:error, :locked}
        end

      _ ->
        {:error, :locked}
    end
  catch
    :exit, _ -> {:error, :locked}
  end

  defp lock_options do
    case System.get_env("LEMON_LOCK_DIR") do
      dir when is_binary(dir) and dir != "" -> [run_dir: dir]
      _ -> []
    end
  end

  defp lock_name(token), do: {__MODULE__, label(token)}

  defp label(token),
    do: "telegram-poller-" <> Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
