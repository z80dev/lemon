defmodule LemonCore.Service.Systemd do
  @moduledoc false
  @behaviour LemonCore.Service.Manager
  alias LemonCore.Service.{Command, Identity, Unit}

  def available?(opts),
    do: match?({_, 0}, Command.run("systemctl", ["--user", "show-environment"], opts))

  def persistence(opts) do
    linger =
      case Command.run(
             "loginctl",
             ["show-user", Identity.uid(opts), "-p", "Linger", "--value"],
             opts
           ) do
        {value, 0} -> String.trim(value) == "yes"
        _ -> false
      end

    {if(linger, do: "boot", else: "session"), linger}
  end

  def enable_linger(opts) do
    case Command.run("loginctl", ["enable-linger"], opts) do
      {_, 0} ->
        :ok

      _ ->
        IO.puts(:stderr, "sudo loginctl enable-linger $USER")
        :ok
    end
  end

  def install(spec, opts) do
    with :ok <- Unit.write(spec, "systemd"),
         :ok <- Command.ok("systemctl", ["--user", "daemon-reload"], opts),
         :ok <- Command.ok("systemctl", ["--user", "enable", "--now", spec.label], opts),
         do: :ok
  end

  def status(spec, opts) do
    case Command.run(
           "systemctl",
           [
             "--user",
             "show",
             "-p",
             "LoadState,ActiveState,SubState,MainPID,ExecMainStatus",
             spec.label
           ],
           opts
         ) do
      {text, 0} ->
        fields =
          text
          |> String.split("\n", trim: true)
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(line, "=", parts: 2) do
              [key, value] -> Map.put(acc, key, value)
              _ -> acc
            end
          end)

        pid =
          case Integer.parse(Map.get(fields, "MainPID", "0")) do
            {number, ""} when number > 1 -> number
            _ -> nil
          end

        %{
          loaded: fields["LoadState"] != "not-found",
          pid: pid,
          failed: fields["ActiveState"] == "failed"
        }

      _ ->
        %{loaded: false, pid: nil, failed: false}
    end
  end

  def start(spec, opts), do: Command.ok("systemctl", ["--user", "start", spec.label], opts)
  def restart(spec, opts), do: Command.ok("systemctl", ["--user", "restart", spec.label], opts)
  def stop(spec, opts), do: Command.ok("systemctl", ["--user", "stop", spec.label], opts)
  def unload(spec, opts), do: stop(spec, opts)

  def uninstall(spec, opts) do
    with :ok <- Command.ok("systemctl", ["--user", "disable", "--now", spec.label], opts),
         :ok <- remove(spec.path),
         :ok <- Command.ok("systemctl", ["--user", "daemon-reload"], opts),
         do: :ok
  end

  defp remove(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unit_remove_failed}
    end
  end
end
