defmodule LemonCore.NodeCredentials do
  @moduledoc """
  Launcher → VM handoff for execution-node pairing credentials.

  `bin/lemon` and the release launcher remove `LEMON_NODE_OPERATOR_TOKEN` and
  `LEMON_NODE_TOKEN` from their environment at startup, so the credentials
  never appear in the VM's initial environment (`/proc/<pid>/environ`,
  `ps -E`) or in any child. Only when exec'ing the VM for `lemon node` does
  the launcher open an anonymous pipe on fd 3 holding the NUL-separated
  name/value pairs and set `LEMON_NODE_CREDENTIAL_FD=3`; nothing touches the
  filesystem, so no path can leave credentials behind. `consume_handoff/0`
  runs in the CLI entry expression, before any application starts, and drains
  the pipe; a handoff that cannot be read completely refuses to start.

  The values live only in the consuming process's dictionary: the CLI entry
  expression, `LemonCli.CLI.main/1` and `CodingAgent.ExecutionNode.CLI.run/2`
  run in that one process, which `take/1` reads from. No other process can
  see them, and nothing is published VM-wide.
  """

  @handoff "LEMON_NODE_CREDENTIAL_FD"
  @names ["LEMON_NODE_OPERATOR_TOKEN", "LEMON_NODE_TOKEN"]
  @key {__MODULE__, :credentials}

  @spec consume_handoff() :: :ok
  def consume_handoff do
    fd = System.get_env(@handoff)
    System.delete_env(@handoff)

    credentials =
      case fd do
        nil -> %{}
        "3" -> "/dev/fd/3" |> read_pipe!() |> parse()
        _ -> raise "invalid #{@handoff}"
      end

    Process.put(@key, credentials)
    :ok
  end

  @doc """
  Returns and forgets a credential handed over to the calling process. Without
  a handoff (direct VM invocation) the variable is read once and deleted from
  the VM environment.
  """
  @spec take(String.t()) :: String.t() | nil
  def take(name) when name in @names do
    credentials = Process.get(@key, %{})
    env_value = System.get_env(name)
    System.delete_env(name)

    case Map.pop(credentials, name) do
      {nil, _} ->
        env_value

      {value, rest} ->
        Process.put(@key, rest)
        value
    end
  end

  @doc false
  # Drains the inherited descriptor to EOF; fails closed otherwise.
  def read_pipe!(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        try do
          case IO.binread(device, :eof) do
            data when is_binary(data) -> data
            :eof -> ""
            {:error, reason} -> raise "node credential handoff unreadable: #{inspect(reason)}"
          end
        after
          File.close(device)
        end

      {:error, reason} ->
        raise "node credential handoff unreadable: #{inspect(reason)}"
    end
  end

  defp parse(contents) do
    contents
    |> String.split(<<0>>)
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.flat_map(fn
      [name, value] when name in @names and value != "" -> [{name, value}]
      _ -> []
    end)
    |> Map.new()
  end
end
