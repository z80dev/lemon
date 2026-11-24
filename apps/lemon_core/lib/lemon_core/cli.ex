defmodule LemonCore.CLI do
  @moduledoc """
  Mix-free terminal IO and operational errors shared by runtime commands.

  Commands never halt the VM. The invoking CLI or Mix task owns the exit boundary.
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

  @spec fail!(String.t()) :: no_return()
  @spec fail!(String.t(), non_neg_integer()) :: no_return()
  def fail!(message, exit_code \\ 1), do: raise(Error, message: message, exit_code: exit_code)

  def start!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} -> :ok
      {:error, reason} -> fail!("Could not start #{app}: #{inspect(reason)}")
    end
  end
end
