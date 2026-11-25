defmodule LemonCli.Service.LegacyProcess do
  @moduledoc false

  alias LemonCli.Service.{Command, Role, Unit}
  alias LemonCore.ProcessIdentity

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
              with true <- owner == ProcessIdentity.uid(opts),
                   {:ok, words} <- Unit.split_command(command, :process),
                   true <- word_sequence?(words, ["node", "join", "--name", name]),
                   {:ok, identity} <- ProcessIdentity.capture(String.to_integer(pid), opts),
                   true <- identity.started_at == ProcessIdentity.normalize_time(started),
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
end
