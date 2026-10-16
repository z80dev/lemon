defmodule LemonCli.ConnectCommand do
  @moduledoc """
  Forwards interactive iPhone pairing to Lemon Bot without starting a service.

  The Bot process owns authentication, preflight, and exact-request approval.
  Its real terminal descriptors are inherited, never piped through the BEAM.
  """

  @source_script Path.expand(
                   "../../../../products/lemon_bot/backend/src/cli/connect.ts",
                   __DIR__
                 )

  def run(args), do: run(args, [])

  @doc false
  def run(args, opts) do
    if valid_args?(args) do
      case executable(opts) do
        {:ok, executable, prefix} -> terminal(executable, prefix ++ args, opts)
        {:error, message} -> failure(message)
      end
    else
      IO.puts(:stderr, "Usage: lemon connect iphone --backend ORIGIN [--origin HTTPS_ORIGIN]")
      2
    end
  end

  defp valid_args?(["iphone" | args]), do: valid_options?(args, [])
  defp valid_args?(_args), do: false

  defp valid_options?([], seen), do: "--backend" in seen

  defp valid_options?([flag, value | rest], seen)
       when flag in ["--backend", "--origin"] and is_binary(value) do
    value != "" and not String.starts_with?(value, "-") and
      flag not in seen and valid_options?(rest, [flag | seen])
  end

  defp valid_options?(_args, _seen), do: false

  defp executable(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    source = Keyword.get_lazy(opts, :source_script, &source_script/0)

    if File.regular?(source) do
      case find.("bun") do
        nil ->
          {:error, "Install Bun and ensure `bun` is on PATH to pair from this source checkout."}

        bun ->
          {:ok, bun, [Path.expand(source)]}
      end
    else
      installed =
        Path.join([
          Keyword.get_lazy(opts, :home, &System.user_home!/0),
          ".lemon",
          "lemon_bot",
          "current",
          "bot",
          "bin",
          "lemon-bot"
        ])

      case find.(installed) || find.("lemon-bot") do
        nil ->
          {:error,
           "Install the standalone Lemon Bot package (lemon_bot profile), or put `lemon-bot` on PATH. Start/configure its backend separately before pairing."}

        bot ->
          {:ok, bot, ["connect"]}
      end
    end
  end

  defp source_script do
    case System.get_env("LEMON_LAUNCHER") do
      nil ->
        @source_script

      launcher ->
        candidate =
          Path.expand(
            "../products/lemon_bot/backend/src/cli/connect.ts",
            Path.dirname(launcher)
          )

        if File.regular?(candidate), do: candidate, else: @source_script
    end
  end

  defp terminal(executable, args, opts) do
    open_port = Keyword.get(opts, :open_port, &Port.open/2)

    try do
      port =
        open_port.({:spawn_executable, String.to_charlist(executable)}, [
          :nouse_stdio,
          :exit_status,
          :hide,
          args: Enum.map(args, &String.to_charlist/1)
        ])

      receive do
        {^port, {:exit_status, status}} -> status
      end
    rescue
      _error in [ArgumentError, ErlangError] ->
        failure(
          "Could not execute the pairing client. Check that Bun or lemon-bot is executable and installed correctly."
        )
    end
  end

  defp failure(message) do
    IO.puts(:stderr, "Error: " <> message)
    1
  end
end
