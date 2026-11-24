defmodule LemonCore.CLI do
  @moduledoc """
  Mix-free terminal IO and operational errors shared by runtime commands.

  Commands never halt the VM. The invoking CLI or Mix task owns the exit boundary.

  One-shot commands start their applications with `start/2`, which boots
  `:lemon_core` in client mode (see `LemonCore.Application`): the VM never
  reconciles, sweeps or reloads state owned by a running daemon.
  """

  defmodule Error do
    @moduledoc false
    defexception [:message, exit_code: 1]
  end

  def info(message), do: IO.puts(IO.ANSI.format(message))
  def error(message), do: IO.puts(:stderr, IO.ANSI.format(message))

  def prompt(message) do
    case IO.gets(message) do
      answer when is_binary(answer) -> answer
      _eof -> ""
    end
  end

  def fail!(message, exit_code \\ 1), do: raise(Error, message: message, exit_code: exit_code)

  @doc """
  Start `app` (and its dependencies) for a one-shot command.

  When `:lemon_core` is not running yet it boots in `:client` mode, or in
  `:read_only_client` mode with `store: :read_only` for commands that only
  read. A VM whose `:lemon_core` already runs (a daemon-hosted Mix task, tests)
  keeps its mode.
  """
  @spec start(atom(), keyword()) :: :ok | {:error, term()}
  def start(app, opts \\ []) when is_atom(app) and is_list(opts) do
    unless List.keymember?(Application.started_applications(), :lemon_core, 0) do
      mode = if Keyword.get(opts, :store) == :read_only, do: :read_only_client, else: :client
      Application.put_env(:lemon_core, :boot_mode, mode)
    end

    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "`start/2`, raising `LemonCore.CLI.Error` when the application cannot start."
  def start!(app, opts \\ []) do
    case start(app, opts) do
      :ok -> :ok
      {:error, reason} -> fail!("Could not start #{app}: #{inspect(reason)}")
    end
  end
end
