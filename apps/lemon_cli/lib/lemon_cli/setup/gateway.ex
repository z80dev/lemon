defmodule LemonCli.Setup.Gateway do
  import LemonCli.Onboarding.PromptUI, only: [normalize_input: 1]

  @moduledoc """
  Gateway setup dispatcher for `lemon gateway setup`.

  Routes to the correct transport-specific adapter based on the first
  positional argument or the `--transport` flag.  Without a transport
  specifier, lists the available adapters and (in interactive mode) prompts
  the user to choose one.

  ## Usage

      lemon gateway setup                    # interactive picker
      lemon gateway setup telegram           # pair a Telegram bot with your chat
      lemon gateway setup discord            # restrict a Discord bot to a channel
      lemon gateway setup --transport telegram  # equivalent flag form
      lemon gateway setup telegram --non-interactive --token <token> --chat-id <id>

  ## Adding new adapters

  Implement `LemonCli.Setup.Gateway.Adapter` and add the module to
  `@adapters` in this file.  No other wiring is required.
  """

  alias LemonCli.Setup.Gateway.{Discord, Telegram}

  @adapters [Telegram, Discord]

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
      io.info.("Specify a transport with: lemon gateway setup <transport>")
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
        io.info.("Usage: lemon gateway setup <transport>")
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
end
