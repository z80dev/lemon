defmodule LemonCore.Setup.Gateway do
  @moduledoc """
  Gateway setup dispatcher for `mix lemon.setup gateway`.

  Routes to the correct transport-specific adapter based on the first
  positional argument or the `--transport` flag.  Without a transport
  specifier, lists the available adapters and (in interactive mode) prompts
  the user to choose one.

  ## Usage

      mix lemon.setup gateway                    # interactive picker
      mix lemon.setup gateway telegram           # directly run Telegram adapter
      mix lemon.setup gateway --transport telegram  # equivalent flag form
      mix lemon.setup gateway telegram --non-interactive

  ## Adding new adapters

  Implement `LemonCore.Setup.Gateway.Adapter` and add the module to
  `@adapters` in this file.  No other wiring is required.
  """

  alias LemonCore.Setup.Gateway.Telegram

  @adapters [Telegram]

  @doc """
  Dispatch gateway setup to a transport-specific adapter.

  `args` are the remaining CLI arguments after the `gateway` subcommand has
  been consumed.  `io` is the standard IO callbacks map.
  """
  @spec run([String.t()], map()) :: :ok | {:error, term()}
  def run(args, io) do
    {opts, rest, _invalid} =
      OptionParser.parse_head(args,
        switches: [
          transport: :string,
          non_interactive: :boolean
        ],
        aliases: [n: :non_interactive, t: :transport]
      )

    transport = opts[:transport] || List.first(rest)
    adapter_args = if transport && List.first(rest) == transport, do: tl(rest), else: rest

    dispatch(transport, adapter_args, opts, io)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private dispatch
  # ──────────────────────────────────────────────────────────────────────────

  defp dispatch(nil, _args, opts, io) do
    non_interactive? = opts[:non_interactive] || false

    if non_interactive? do
      list_adapters(io)
      io.info.("Specify a transport with: mix lemon.setup gateway <transport>")
      :ok
    else
      pick_adapter_interactively(@adapters, io)
    end
  end

  defp dispatch(transport, args, _opts, io) do
    case find_adapter(transport) do
      nil ->
        io.error.("Unknown gateway transport: #{inspect(transport)}")
        io.info.("")
        list_adapters(io)
        io.info.("Usage: mix lemon.setup gateway <transport>")
        {:error, :unknown_transport}

      adapter ->
        adapter.run(args, io)
    end
  end

  defp find_adapter(name) do
    Enum.find(@adapters, fn mod -> mod.name() == name end)
  end

  defp list_adapters(io) do
    io.info.("")
    io.info.("Available gateway transports:")
    io.info.("")

    Enum.each(@adapters, fn mod ->
      io.info.("  #{String.pad_trailing(mod.name(), 12)}  #{mod.description()}")
    end)

    io.info.("")
  end

  defp pick_adapter_interactively(adapters, io) do
    list_adapters(io)

    names = Enum.map(adapters, & &1.name())
    choice = normalize_input(io.prompt.("Choose a transport [#{Enum.join(names, "/")}]: "))

    case find_adapter(choice) do
      nil ->
        io.error.("Unknown transport #{inspect(choice)}. Try again or press Ctrl-C to exit.")
        pick_adapter_interactively(adapters, io)

      adapter ->
        adapter.run([], io)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # IO helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end
