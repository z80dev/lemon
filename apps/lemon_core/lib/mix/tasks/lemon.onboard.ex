defmodule Mix.Tasks.Lemon.Onboard do
  use Mix.Task

  alias LemonCore.Onboarding.LogSilencer
  alias LemonCore.Onboarding.Providers
  alias LemonCore.Onboarding.Runner

  @shortdoc "Top-level interactive provider onboarding"
  @moduledoc """
  Top-level provider onboarding flow.

  If no provider is passed, this task shows a provider picker and then walks
  through the appropriate OAuth or API-key flow for the selected provider.

  Usage:
      mix lemon.onboard
      mix lemon.onboard codex
      mix lemon.onboard --provider copilot
      mix lemon.onboard anthropic --set-default
      mix lemon.onboard codex --auth api_key
  """

  @impl true
  def run(args) do
    run_with_io(args, Runner.default_io())
  end

  @doc false
  def run_with_io(args, io) when is_list(args) and is_map(io) do
    LogSilencer.with_quiet_logs(interactive_tui_session?(io), fn ->
      {provider_name, remaining_args} = extract_provider_arg(args)

      provider =
        case provider_name do
          nil -> choose_provider!(remaining_args, io)
          value -> Providers.fetch!(value)
        end

      Runner.run(remaining_args, provider, io: io)
    end)
  end

  defp choose_provider!(args, io) do
    config_path = extract_config_path(args)
    providers = Providers.list()
    default_index = default_provider_index(providers, config_path)

    options =
      providers
      |> Enum.with_index()
      |> Enum.map(fn {provider, idx} ->
        default_marker = if idx == default_index, do: "   [default]", else: ""
        auth = Providers.auth_summary(provider)
        status = Providers.menu_status(provider, config_path)

        %{
          label:
            String.pad_trailing(provider.display_name, 24) <>
              String.pad_trailing(auth, 14) <> status <> default_marker,
          value: provider
        }
      end)

    case select_value(io, %{
           title: "Choose Lemon Provider",
           subtitle: "Config: #{config_path}",
           options: options
         }) do
      {:ok, %{} = provider} ->
        provider

      :cancel ->
        Mix.raise("Onboarding cancelled.")

      :fallback ->
        io.info.("")
        io.info.("Lemon Provider Onboarding")
        io.info.("Config: #{config_path}")
        io.info.("")
        io.info.("Choose a provider:")

        providers
        |> Enum.with_index(1)
        |> Enum.each(fn {provider, idx} ->
          default_marker = if idx == default_index + 1, do: " (default)", else: ""

          left =
            "#{idx}. #{provider.display_name}"
            |> String.pad_trailing(26)

          auth = Providers.auth_summary(provider) |> String.pad_trailing(14)
          status = Providers.menu_status(provider, config_path)

          io.info.("  #{left}#{auth}#{status}#{default_marker}")
        end)

        choice = io.prompt.("Choose provider [default: #{default_index + 1}]: ")
        parse_provider_choice(choice, providers, default_index, io)
    end
  end

  defp parse_provider_choice(choice, providers, default_index, io) do
    trimmed = normalize_input(choice)

    cond do
      trimmed == "" ->
        Enum.at(providers, default_index)

      String.match?(trimmed, ~r/^\d+$/) ->
        idx = String.to_integer(trimmed)

        case Enum.at(providers, idx - 1) do
          nil ->
            io.error.("Invalid index #{idx}.")
            parse_provider_choice(io.prompt.("Choose provider: "), providers, default_index, io)

          provider ->
            provider
        end

      true ->
        case Providers.find(trimmed) do
          nil ->
            io.error.("Unknown provider #{inspect(trimmed)}.")
            parse_provider_choice(io.prompt.("Choose provider: "), providers, default_index, io)

          provider ->
            provider
        end
    end
  end

  defp default_provider_index(providers, config_path) do
    config =
      config_path
      |> Path.expand()
      |> read_config()

    default_provider = get_in(config, ["defaults", "provider"])

    Enum.find_index(providers, &(&1.id == default_provider)) || 0
  end

  defp read_config(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Toml.decode(content) do
      decoded
    else
      _ -> %{}
    end
  end

  defp extract_provider_arg(args) do
    do_extract_provider_arg(args, nil, [])
  end

  defp do_extract_provider_arg([], provider, acc), do: {provider, Enum.reverse(acc)}

  defp do_extract_provider_arg(["--provider", value | rest], _provider, acc) do
    do_extract_provider_arg(rest, value, acc)
  end

  defp do_extract_provider_arg(["-p", value | rest], _provider, acc) do
    do_extract_provider_arg(rest, value, acc)
  end

  defp do_extract_provider_arg([flag, value | rest], nil, acc)
       when flag in [
              "--config-path",
              "--token",
              "--secret-name",
              "--model",
              "--auth",
              "--enterprise-domain",
              "--project-id"
            ] do
    do_extract_provider_arg(rest, nil, [value, flag | acc])
  end

  defp do_extract_provider_arg([value | rest], nil, acc) do
    if String.starts_with?(value, "-") do
      do_extract_provider_arg(rest, nil, [value | acc])
    else
      do_extract_provider_arg(rest, value, acc)
    end
  end

  defp do_extract_provider_arg([value | rest], provider, acc) do
    do_extract_provider_arg(rest, provider, [value | acc])
  end

  defp extract_config_path(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--config-path", value] -> value
      _ -> nil
    end) || LemonCore.Config.global_path()
  end

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()

  defp select_value(io, params) do
    case Map.get(io, :select) do
      select when is_function(select, 1) ->
        case select.(params) do
          {:ok, value} ->
            {:ok, value}

          :cancel ->
            :cancel

          {:error, reason} ->
            io.error.(
              "Interactive onboarding UI unavailable (#{format_selector_error(reason)}). Falling back to prompt mode."
            )

            :fallback

          value ->
            {:ok, value}
        end

      _ ->
        :fallback
    end
  end

  defp interactive_tui_session?(io) when is_map(io) do
    is_function(Map.get(io, :select), 1) and LemonCore.Onboarding.TerminalUI.available?()
  end

  defp format_selector_error(:not_available), do: "no interactive terminal detected"
  defp format_selector_error(:no_selection), do: "selector exited before a choice was made"
  defp format_selector_error(:invalid_selector_params), do: "invalid selector parameters"
  defp format_selector_error(reason), do: inspect(reason)
end
