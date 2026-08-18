defmodule LemonCli.Setup.Provider do
  @moduledoc """
  Provider setup for `mix lemon.setup provider` and the packaged `lemon model`
  command.

  Wraps provider onboarding with setup-context-aware pre-checks so the
  command can give a better first-time experience: secrets init guard and a
  config scaffold before the onboarding proper. The provider picker (shared
  with `Mix.Tasks.Lemon.Onboard`) and the onboarding execution both run
  without Mix, so packaged releases reuse this module directly.

  After a successful onboarding the resulting configuration is verified with
  `LemonCli.Setup.Verification`: the default provider/model must resolve and
  the referenced credential must be usable. When the provider exposes a
  lightweight models endpoint, a live request validates the credential;
  pass `--skip-verify` to defer it when offline. A failed verification
  returns `{:error, :verification_failed}` with actionable recovery text —
  it never reports setup as complete.
  """

  alias LemonCli.Onboarding.{LogSilencer, Providers, Runner, TerminalUI}
  alias LemonCli.Onboarding.Provider, as: ProviderSpec
  alias LemonCli.Setup.Verification
  alias LemonCore.Secrets
  alias LemonCli.Setup.Scaffold

  @doc """
  Runs provider onboarding within the setup context.

  Pre-checks:
  1. Required apps (`:lemon_core`, `:lemon_ai`) are started.
  2. Secrets must be initialized — if not, prints guidance and returns
     `{:error, :secrets_not_configured}`.
  3. Bootstraps the global config scaffold when none exists yet.

  Then resolves the provider (explicit `--provider`/positional argument or
  the interactive picker) and delegates to
  `LemonCli.Onboarding.Runner.run/3` for the actual onboarding flow
  (OAuth/API-key, secret storage, config update, default model).

  Finally verifies the resulting configuration with
  `Verification.verify_provider/1`: the offline strong checks (default
  provider/model resolvable, credential decryptable) always run. The live
  credential check runs only for setup-journey callers that pass
  `live_verify: true` (the wizard and `setup provider`); `lemon model`
  shares this module without a network round-trip. `--skip-verify` defers
  the live check when offline.

  ## Options

    * `:live_verify` - run the live credential check after onboarding
      (default: `false`; the setup wizard enables it)
    * `:verifier` - injectable live-check function, forwarded to
      `Verification.verify_provider/1` (used by tests to avoid network)
  """
  @spec run([String.t()], map(), keyword()) :: :ok | {:error, term()}
  def run(args, io, opts \\ []) when is_list(args) and is_map(io) do
    Runner.ensure_required_apps!()

    {skip_verify?, rest} = extract_skip_verify(args)
    live_verify? = Keyword.get(opts, :live_verify, false)

    with :ok <- ensure_secrets_ready(io),
         :ok <- maybe_bootstrap_config(io),
         :ok <- onboard(rest, io) do
      verify_onboarded_config(rest, skip_verify? or not live_verify?, io, opts)
    end
  end
  # ──────────────────────────────────────────────────────────────────────────
  # Post-onboarding verification
  # ──────────────────────────────────────────────────────────────────────────


  defp verify_onboarded_config(args, skip_verify?, io, opts) do
    config_path = extract_config_path(args)

    if Verification.setup_state(config_path: config_path).provider.complete do
      io.info.("")
      io.info.("Verifying provider configuration...")

      case Verification.verify_provider(
             config_path: config_path,
             verifier: Keyword.get(opts, :verifier),
             skip_verify: skip_verify?
           ) do
        {:ok, %{provider: provider, model: model, live: live} = result} ->
          io.info.(
            "Provider configuration verified: #{provider} / #{model} " <>
              "(credential usable#{live_detail(live, result)})."
          )

          :ok

        {:error, %{message: message}} ->
          io.error.("Verification failed — setup is not complete.")
          io.error.(message)
          {:error, :verification_failed}
      end
    else
      io.info.("")
      io.info.("Credentials stored, but no default provider/model was set.")
      io.info.("Run `lemon setup provider --set-default` to make this provider the default.")
      :ok
    end
  end

  defp live_detail(:ok, %{live_note: note}) when is_binary(note), do: ", #{note}"
  defp live_detail(:skipped, %{live_note: note}) when is_binary(note), do: "; #{note}"

  defp live_detail(:skipped, _result), do: "; live check not available"
  defp live_detail(:disabled, _result), do: "; live check skipped (--skip-verify)"
  defp live_detail(:ok, _result), do: ", live check passed"

  defp extract_skip_verify(args) do
    {"--skip-verify" in args, Enum.reject(args, &(&1 == "--skip-verify"))}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Pre-checks
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_secrets_ready(io) do
    status = Secrets.status()

    if status.configured do
      :ok
    else
      io.error.("Encrypted secrets are not configured.")
      io.info.("")
      io.info.("Run this first, then retry:")
      io.info.("  lemon secrets init")
      io.info.("")
      {:error, :secrets_not_configured}
    end
  end

  defp maybe_bootstrap_config(io) do
    if Scaffold.global_config_exists?() do
      :ok
    else
      result =
        try do
          Scaffold.bootstrap_global()
        rescue
          e -> {:error, Exception.message(e)}
        end

      case result do
        {:ok, path} ->
          io.info.("Created minimal config: #{path}")
          io.info.("Edit it to add your preferred defaults, then re-run this command.")
          io.info.("")
          :ok

        {:exists, _path} ->
          :ok

        {:error, reason} ->
          io.error.("Failed to create config scaffold: #{inspect(reason)}")
          {:error, {:scaffold_failed, reason}}
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Provider resolution
  # ──────────────────────────────────────────────────────────────────────────

  defp fetch_provider!(value) do
    case Providers.find(value) do
      %ProviderSpec{} = provider ->
        provider

      nil ->
        names =
          Providers.list()
          |> Enum.map(& &1.id)
          |> Enum.join(", ")

        Runner.fail!("Unknown provider #{inspect(value)}. Available providers: #{names}")
    end
  end

  defp choose_provider(args, io) do
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
      {:ok, %ProviderSpec{} = provider} ->
        provider

      :cancel ->
        Runner.fail!("Onboarding cancelled.")

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
      |> read_config

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

  # ──────────────────────────────────────────────────────────────────────────
  # IO helpers
  # ──────────────────────────────────────────────────────────────────────────

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
    is_function(Map.get(io, :select), 1) and TerminalUI.available?()
  end

  defp format_selector_error(:not_available), do: "no interactive terminal detected"
  defp format_selector_error(:no_selection), do: "selector exited before a choice was made"
  defp format_selector_error(:invalid_selector_params), do: "invalid selector parameters"
  defp format_selector_error(reason), do: inspect(reason)
end
