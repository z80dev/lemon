defmodule LemonCore.Service.Launchd do
  @moduledoc false
  @behaviour LemonCore.Service.Manager
  alias LemonCore.Service.{Command, Identity, Unit}

  def domain(opts), do: "gui/" <> Identity.uid(opts)
  def target(spec, opts), do: domain(opts) <> "/" <> spec.label

  def available?(opts),
    do: match?({_, 0}, Command.run("launchctl", ["print", domain(opts)], opts))

  def persistence(_opts), do: {"login", nil}

  def install(spec, opts) do
    with :ok <- Unit.write(spec, "launchd"),
         :ok <- Command.ok("launchctl", ["bootstrap", domain(opts), spec.path], opts),
         do: :ok
  end

  def status(spec, opts) do
    case Command.run("launchctl", ["print", target(spec, opts)], opts) do
      {text, 0} ->
        pid =
          case Regex.run(~r/^\s*pid = (\d+)\s*$/m, text) do
            [_, number] -> String.to_integer(number)
            _ -> nil
          end

        failed =
          case Regex.run(~r/^\s*last exit code = (\d+)\s*$/m, text) do
            [_, "0"] -> false
            [_, _] -> true
            _ -> false
          end

        %{loaded: true, pid: pid, failed: failed}

      _ ->
        %{loaded: false, pid: nil, failed: false}
    end
  end

  def start(spec, opts), do: Command.ok("launchctl", ["kickstart", target(spec, opts)], opts)

  def restart(spec, opts),
    do: Command.ok("launchctl", ["kickstart", "-k", target(spec, opts)], opts)

  def stop(spec, opts) do
    case status(spec, opts) do
      %{pid: nil} ->
        :ok

      %{pid: pid} ->
        with {:ok, identity} <- Identity.capture(pid, opts),
             :ok <- Command.ok("launchctl", ["kill", "SIGTERM", target(spec, opts)], opts) do
          wait_stopped(identity, opts, System.monotonic_time(:millisecond) + 30_000)
        end
    end
  end

  def unload(spec, opts) do
    if status(spec, opts).loaded,
      do: Command.ok("launchctl", ["bootout", target(spec, opts)], opts),
      else: :ok
  end

  def uninstall(spec, opts) do
    with :ok <- unload(spec, opts), do: remove(spec.path)
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unit_remove_failed}
    end
  end

  defp wait_stopped(identity, opts, deadline) do
    cond do
      Identity.gone?(identity, opts) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :stop_timeout}

      true ->
        Process.sleep(100)
        wait_stopped(identity, opts, deadline)
    end
  end
end
