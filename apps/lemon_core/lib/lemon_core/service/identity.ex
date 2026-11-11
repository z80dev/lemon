defmodule LemonCore.Service.Identity do
  @moduledoc "Same-user process identity checks. Signals are bound to PID and start time."
  alias LemonCore.Service.{Command, Role, Unit}

  def uid(opts) do
    Keyword.get_lazy(opts, :uid, fn ->
      case Command.run("id", ["-u"], opts) do
        {value, 0} -> String.trim(value)
        _ -> "unknown"
      end
    end)
    |> to_string()
  end

  def capture(pid, opts) when is_integer(pid) and pid > 1 do
    with {output, 0} <-
           Command.run("ps", ["-p", to_string(pid), "-o", "uid=,lstart=,comm="], opts),
         [_, uid, started, executable] <-
           Regex.run(~r/^\s*(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d{4})\s+(.+?)\s*$/s, output),
         true <- uid == uid(opts) do
      {:ok,
       %{
         pid: pid,
         started_at: normalize_time(started),
         executable: executable_path(pid, executable, opts)
       }}
    else
      _ -> {:error, :process_identity_unverified}
    end
  end

  def capture(_, _), do: {:error, :process_identity_unverified}

  def same?(identity, opts) do
    case capture(identity.pid, opts) do
      {:ok, current} -> current == identity
      _ -> false
    end
  end

  def gone?(identity, opts) do
    case Command.run("ps", ["-p", to_string(identity.pid), "-o", "lstart="], opts) do
      {started, 0} ->
        normalize_time(started) != identity.started_at and String.trim(started) != ""

      {output, 1} ->
        String.trim(output) == ""

      _ ->
        false
    end
  end

  def terminate(identity, opts) do
    if same?(identity, opts) do
      with :ok <- Command.ok("kill", ["-TERM", to_string(identity.pid)], opts) do
        deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :stop_timeout, 15_000)
        wait_gone(identity, deadline, opts)
      end
    else
      {:error, :process_identity_changed}
    end
  end

  defp wait_gone(identity, deadline, opts) do
    cond do
      gone?(identity, opts) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :stop_timeout}

      true ->
        Process.sleep(100)
        wait_gone(identity, deadline, opts)
    end
  end

  def listeners(port, opts) do
    case Command.run("lsof", ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fp"], opts) do
      {output, status} when status in [0, 1] ->
        Regex.scan(~r/^p(\d+)$/m, output)
        |> Enum.map(fn [_, pid] -> String.to_integer(pid) end)
        |> Enum.uniq()

      _ ->
        :unknown
    end
  end

  def backend_program?(identity, bot, opts) do
    identity.executable == bot or
      String.starts_with?(
        identity.executable,
        Path.join(Role.home(opts), ".lemon/lemon_bot/versions") <> "/"
      )
  end

  def legacy_workers(name, opts) do
    case Command.run("ps", ["-axo", "pid=,uid=,lstart=,command="], opts) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(\S+\s+\S+\s+\d+\s+[\d:]+\s+\d{4})\s+(.+)$/, line) do
            [_, pid, owner, started, command] ->
              with true <- owner == uid(opts),
                   {:ok, words} <- Unit.split_command(command, :process),
                   true <- word_sequence?(words, ["node", "join", "--name", name]),
                   {:ok, identity} <- capture(String.to_integer(pid), opts),
                   true <- identity.started_at == normalize_time(started),
                   true <- beam_program?(identity.executable, opts) do
                [identity]
              else
                _ -> []
              end

            _ ->
              []
          end
        end)

      _ ->
        {:error, :process_scan_failed}
    end
  end

  defp word_sequence?(words, sequence),
    do: Enum.chunk_every(words, length(sequence), 1, :discard) |> Enum.any?(&(&1 == sequence))

  defp beam_program?(program, opts) do
    roots = [Path.join(Role.home(opts), ".lemon/versions"), to_string(:code.root_dir())]

    String.ends_with?(program, "/bin/beam.smp") and
      Enum.any?(roots, &String.starts_with?(program, &1 <> "/"))
  end

  defp executable_path(pid, fallback, opts) do
    if Keyword.get(opts, :os, :os.type()) in [:linux, {:unix, :linux}] do
      case Command.run("readlink", ["/proc/#{pid}/exe"], opts) do
        {path, 0} -> String.trim(path)
        _ -> String.trim(fallback)
      end
    else
      String.trim(fallback)
    end
  end

  def read_json(path) do
    with {:ok, %{type: :regular, size: size, mode: mode}} when size <= 65_536 <- File.lstat(path),
         true <- Bitwise.band(mode, 0o077) == 0,
         {:ok, body} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      {:ok, map}
    else
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :invalid_record}
    end
  end

  def normalize_time(value) when is_binary(value),
    do: value |> String.trim() |> String.replace(~r/\s+/, " ")

  def normalize_time(_), do: nil
end
