defmodule LemonCli.Setup.Omp do
  @moduledoc """
  `lemon setup omp`: use the provider logins and API keys omp already holds.

  Lemon reads omp's credentials through omp's auth broker
  (`auth_source = "omp_broker"`, see `LemonAgent.ModelRuntime.OmpBroker`). This
  command does every step a user would otherwise do by hand:

    1. finds the broker (`OMP_AUTH_BROKER_URL`, default `http://127.0.0.1:8765`);
       when the default one is not running it installs the `omp-broker`
       background service (`LemonCore.Service`), which runs
       `omp auth-broker serve` against omp's own credential store;
    2. lists the providers omp holds credentials for and maps each to its Lemon
       provider (`OmpBroker.omp_provider/2`);
    3. checks each selected credential through the broker before saving;
    4. sets `auth_source = "omp_broker"` on those `[providers.*]` tables and,
       optionally, the default provider/model, in one locked atomic config write;
    5. live-checks the default provider unless `--skip-verify`.

  `status` reports the same state without changing anything; `disconnect`
  removes the broker setting again (restoring `auth_source = "oauth"` when the
  table still names a Lemon login). Output never contains credentials, account
  identities, broker URLs or token paths.

  Test seams (keyword options, never CLI flags): `:omp_bin`, `:service_install`
  and `:service_status` (functions with `LemonCore.Service.install/2` and
  `status/2` shapes), `:verifier`.
  """

  alias LemonAgent.ModelRuntime.{ModelCatalog, OmpAuthBroker, OmpBroker, OmpConfig, ProviderNames}
  alias LemonCli.Onboarding.{PromptUI, Providers, Runner}
  alias LemonCli.Setup.{Provider, ProviderManagement}
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Service.Role

  @connect_switches [
    config_path: :string,
    provider: :keep,
    all: :boolean,
    model: :string,
    non_interactive: :boolean,
    skip_verify: :boolean,
    service: :boolean,
    port: :integer
  ]
  @status_switches [config_path: :string, json: :boolean]
  @disconnect_switches [config_path: :string, provider: :keep, all: :boolean]

  @service_wait_seconds 30

  @type io :: Runner.io_callbacks()

  @doc "Runs `lemon setup omp [status|disconnect] [options]`."
  @spec run([String.t()], io(), keyword()) :: :ok | {:error, atom()}
  def run(args, io, opts \\ [])
  def run(["status" | args], io, opts), do: status(args, io, opts)
  def run(["disconnect" | args], io, opts), do: disconnect(args, io, opts)
  def run(args, io, opts), do: connect(args, io, opts)

  @doc """
  Whether omp looks set up on this machine: an `omp` executable plus omp's
  credential store or broker token. Pure file checks; no process or network.
  """
  @spec detected?(keyword()) :: boolean()
  def detected?(opts \\ []) do
    omp_executable(opts) != nil and
      (File.regular?(Path.join(omp_agent_dir(), "agent.db")) or
         File.regular?(OmpConfig.token_path(:broker)))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # connect
  # ──────────────────────────────────────────────────────────────────────────

  defp connect(args, io, opts) do
    parsed = parse!(args, @connect_switches, "lemon setup omp")
    interactive? = parsed[:non_interactive] != true
    if interactive?, do: Runner.ensure_interactive!(io)
    Runner.ensure_required_apps!()
    config_path = parsed[:config_path] || LemonCore.Config.global_path()

    endpoint = ensure_broker!(io, parsed, interactive?, opts)
    config = read_config!(config_path)
    rows = broker_rows!(endpoint, config)

    io.info.("")
    io.info.("omp holds credentials for:")
    Enum.each(rows, &io.info.("  " <> row_line(&1)))

    chosen = choose_providers!(rows, parsed, interactive?, io)
    usable = check_credentials!(chosen, config, io)
    default = choose_default!(usable, parsed, interactive?, io, config)

    case ProviderManagement.persist(config_path, [], &connect_patch(&1, usable, default)) do
      :ok -> :ok
      {:error, _} -> Runner.fail!("Could not save the config. Run `lemon config validate`.")
    end

    io.info.("")
    io.info.("Lemon now uses omp's credentials for: #{Enum.map_join(usable, ", ", &label/1)}.")

    io.info.(
      "Logins stay in omp: sign in or out there and Lemon follows. " <>
        "Undo with `lemon setup omp disconnect --all`."
    )

    verify(config_path, parsed, io, opts)
  end

  defp ensure_broker!(io, parsed, interactive?, opts) do
    url = OmpBroker.url()

    case OmpAuthBroker.healthz(url) do
      {:ok, %{version: version}} ->
        io.info.("omp auth broker is running#{if version, do: " (omp #{version})", else: ""}.")

      {:error, _} ->
        case local_port(url) do
          nil ->
            Runner.fail!(
              "The omp auth broker set by OMP_AUTH_BROKER_URL is unreachable. Start it on that " <>
                "host, or unset OMP_AUTH_BROKER_URL to run one on this machine."
            )

          port ->
            start_broker!(io, parsed, interactive?, opts, url, port)
        end
    end

    case OmpBroker.endpoint() do
      {:ok, endpoint} -> endpoint
      {:error, reason} -> Runner.fail!(OmpAuthBroker.error_message(reason))
    end
  end

  defp start_broker!(io, parsed, interactive?, opts, url, configured_port) do
    omp = omp_executable(opts)
    manual = "Start it with `omp auth-broker serve`, then rerun `lemon setup omp`."
    secrets = Keyword.get(opts, :secrets, LemonCore.Secrets)
    port_free? = Keyword.get(opts, :port_free?, &port_free?/1)

    if is_nil(omp) do
      Runner.fail!(
        "omp is not installed (no `omp` on PATH). Install omp or set LEMON_OMP_BIN, " <>
          "then rerun `lemon setup omp`."
      )
    end

    if parsed[:service] == false,
      do: Runner.fail!("The omp auth broker is not running. " <> manual)

    # Another program on the default port moves the broker to a free one; an
    # explicitly chosen address (--port or OMP_AUTH_BROKER_URL) never moves.
    port =
      cond do
        port_free?.(parsed[:port] || configured_port) ->
          parsed[:port] || configured_port

        parsed[:port] || url != OmpBroker.default_url() ->
          Runner.fail!(
            "127.0.0.1:#{parsed[:port] || configured_port} is in use by another program. " <>
              "Free it or choose another --port."
          )

        true ->
          port = free_port()

          io.info.(
            "127.0.0.1:#{configured_port} is in use by another program; " <>
              "omp's broker will listen on 127.0.0.1:#{port} instead."
          )

          port
      end

    broker_url = "http://127.0.0.1:#{port}"
    save_url? = port != configured_port

    if save_url? and not match?(%{configured: true}, secrets.status()) do
      Runner.fail!(
        "Lemon must remember the broker's address (127.0.0.1:#{port}) in its encrypted " <>
          "secrets. Run `lemon secrets init`, then rerun `lemon setup omp`."
      )
    end

    if interactive? and
         not PromptUI.select_yes_no(
           "omp's auth broker is not running. Run it as a background service " <>
             "(starts at login, listens on 127.0.0.1:#{port} only)?",
           true,
           io
         ) do
      Runner.fail!("The omp auth broker is not running. " <> manual)
    end

    io.info.("Starting the omp-broker service…")
    install = Keyword.get(opts, :service_install, &LemonCore.Service.install/2)

    case install.(["omp-broker"], omp_bin: omp, port: port, wait: @service_wait_seconds) do
      {:ok, %{units: [%{state: "ready"}]}} ->
        io.info.("omp auth broker service is running (`lemon service status omp-broker`).")

      {:ok, %{units: [unit]}} ->
        Runner.fail!(
          "The omp-broker service did not become ready (#{unit_state(unit)}). " <>
            "Check `lemon service status omp-broker` and its log."
        )

      {:error, reason} ->
        Runner.fail!("Could not install the omp-broker service (#{reason}). " <> manual)
    end

    # Lemon resolves OMP_AUTH_BROKER_URL from its secrets when the environment
    # does not set it, so the runtime and later commands find the moved broker.
    if save_url? do
      case secrets.set("OMP_AUTH_BROKER_URL", broker_url) do
        {:ok, _} -> :ok
        _ -> Runner.fail!("Could not save the broker address to Lemon's secrets.")
      end
    end
  end

  # The port of a loopback broker URL this machine can serve, or nil for another host.
  defp local_port(url) do
    case URI.parse(url) do
      %URI{scheme: "http", host: host, port: port} when host in ["127.0.0.1", "localhost"] ->
        port

      _ ->
        nil
    end
  end

  defp port_free?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        false

      {:error, _} ->
        true
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp unit_state(%{state: state, detail: detail}) when is_binary(detail),
    do: "#{state}: #{detail}"

  defp unit_state(%{state: state}), do: state

  defp choose_providers!(rows, parsed, interactive?, io) do
    supported = for %{lemon: lemon} when is_binary(lemon) <- rows, do: lemon
    requested = Keyword.get_values(parsed, :provider)

    cond do
      parsed[:all] == true and requested != [] ->
        Runner.fail!("Use either --all or --provider, not both.")

      parsed[:all] == true ->
        nonempty!(supported)

      requested != [] ->
        Enum.map(requested, &requested_provider!(&1, rows))

      not interactive? ->
        Runner.fail!("Pass --all or --provider NAME to choose which omp credentials Lemon uses.")

      true ->
        supported = nonempty!(supported)

        case choose(io, "Use omp's credentials in Lemon", [
               %{label: "All #{length(supported)} providers listed above", value: :all},
               %{label: "Choose providers one by one", value: :each}
             ]) do
          {:ok, :all} ->
            supported

          {:ok, :each} ->
            Enum.filter(supported, fn provider ->
              PromptUI.select_yes_no("Use omp's #{label(provider)} credential?", true, io)
            end)
            |> case do
              [] -> Runner.fail!("No providers selected; nothing changed.")
              picked -> picked
            end

          :cancel ->
            Runner.fail!("Cancelled; nothing changed.")
        end
    end
  end

  defp nonempty!([]) do
    Runner.fail!(
      "omp has no credentials for providers Lemon supports. Sign in from omp first " <>
        "(`/login` in omp, or `omp auth-broker login PROVIDER`), then rerun `lemon setup omp`."
    )
  end

  defp nonempty!(providers), do: providers

  defp requested_provider!(name, rows) do
    canonical =
      ProviderNames.canonical_name(name) ||
        Enum.find_value(rows, fn row -> if row.omp == name, do: row.lemon end)

    if canonical && Enum.any?(rows, &(&1.lemon == canonical)) do
      canonical
    else
      Runner.fail!("omp holds no credential Lemon can use for `#{name}`.")
    end
  end

  # Only credentials the broker actually serves (and Lemon can shape) are saved.
  defp check_credentials!(providers, config, io) do
    {usable, failed} =
      providers
      |> Enum.uniq()
      |> Enum.map(fn provider ->
        {provider, OmpBroker.api_key(provider, broker_cfg(config, provider))}
      end)
      |> Enum.split_with(&match?({_, {:ok, _}}, &1))

    Enum.each(failed, fn {provider, {:error, reason}} ->
      io.error.("Skipping #{label(provider)}: #{OmpBroker.error_message(reason)}")
    end)

    case Enum.map(usable, &elem(&1, 0)) do
      [] -> Runner.fail!("None of the selected omp credentials can be used; nothing changed.")
      usable -> usable
    end
  end

  defp choose_default!(usable, parsed, interactive?, io, config) do
    cond do
      is_binary(parsed[:model]) ->
        default_from_flag!(parsed[:model], usable)

      not interactive? ->
        nil

      true ->
        current = current_default(config)

        keep =
          case current do
            {provider, model} ->
              [%{label: "Keep the current default (#{provider} / #{model})", value: :keep}]

            nil ->
              []
          end

        options =
          keep ++
            Enum.map(usable, &%{label: "Make #{label(&1)} the default", value: &1}) ++
            if(keep == [], do: [%{label: "Don't set a default now", value: :keep}], else: [])

        case choose(io, "Default model", options) do
          {:ok, :keep} -> nil
          {:ok, provider} -> {provider, choose_model!(provider, io)}
          :cancel -> nil
        end
    end
  end

  defp default_from_flag!(value, usable) do
    {provider, model} =
      case String.split(value, ":", parts: 2) do
        [provider, model] when model != "" ->
          {ProviderNames.canonical_name(provider), model}

        [model] when length(usable) == 1 ->
          {hd(usable), model}

        _ ->
          Runner.fail!(
            "Qualify --model with its provider (for example anthropic:MODEL) when connecting several providers."
          )
      end

    unless provider in usable do
      Runner.fail!("--model must name one of the providers being connected.")
    end

    case catalog_models(provider) do
      [] ->
        {provider, model}

      models ->
        if model in models,
          do: {provider, model},
          else:
            Runner.fail!(
              "Unknown model for #{label(provider)}. For example: #{Enum.join(Enum.take(models, 3), ", ")}."
            )
    end
  end

  defp choose_model!(provider, io) do
    case catalog_models(provider) do
      [] ->
        Runner.fail!(
          "No catalog models for #{label(provider)}. Rerun with --model #{config_name(provider)}:MODEL."
        )

      models ->
        preferred =
          case Providers.find(config_name(provider)) do
            %{preferred_models: preferred} -> Enum.find(preferred, &(&1 in models))
            _ -> nil
          end

        default_index = Enum.find_index(models, &(&1 == preferred)) || 0
        options = Enum.map(models, &%{label: &1, value: &1})

        case choose(io, "Choose #{label(provider)} Model", options, default_index) do
          {:ok, model} -> model
          :cancel -> Runner.fail!("Cancelled; nothing changed.")
        end
    end
  end

  defp connect_patch(content, providers, default) do
    tables = provider_tables(content)

    content =
      Enum.reduce(providers, content, fn provider, acc ->
        table = "providers." <> Map.get(tables, provider, config_name(provider))

        acc
        |> TomlPatch.upsert_string(table, "auth_source", "omp_broker")
        # Kimi Code's direct omp token path means nothing under the broker.
        |> TomlPatch.delete_key(table, "omp_path")
      end)

    case default do
      nil ->
        content

      {provider, model} ->
        id = config_name(provider)

        content
        |> TomlPatch.upsert_string("defaults", "provider", id)
        |> TomlPatch.upsert_string("defaults", "model", "#{id}:#{model}")
    end
  end

  defp verify(config_path, parsed, io, opts) do
    verify_opts =
      opts
      |> Keyword.take([:verifier])
      |> Keyword.put(:skip_verify, parsed[:skip_verify] == true)

    if current_default(read_config!(config_path)) do
      case Provider.verify_config(config_path, io, verify_opts) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      io.info.(
        "No default model is set yet. Pick one with `lemon setup omp --model PROVIDER:MODEL`."
      )

      :ok
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # status
  # ──────────────────────────────────────────────────────────────────────────

  defp status(args, io, opts) do
    parsed = parse!(args, @status_switches, "lemon setup omp status")
    Runner.ensure_required_apps!()
    config = read_config!(parsed[:config_path] || LemonCore.Config.global_path())
    url = OmpBroker.url()

    {reachable, version} =
      case OmpAuthBroker.healthz(url) do
        {:ok, %{version: version}} -> {true, version}
        {:error, _} -> {false, nil}
      end

    endpoint = OmpBroker.endpoint()

    {rows, broker_error} =
      with true <- reachable,
           {:ok, endpoint} <- endpoint,
           {:ok, %{entries: entries}} <- OmpAuthBroker.snapshot(endpoint, fresh: true) do
        {rows(entries, config), nil}
      else
        false -> {[], :broker_unreachable}
        {:error, reason} -> {[], reason}
      end

    connected =
      config
      |> connected_providers()
      |> Enum.map(fn provider ->
        result = if reachable, do: OmpBroker.api_key(provider, broker_cfg(config, provider))
        %{provider: config_name(provider), usable: match?({:ok, _}, result)}
      end)

    service = service_state(opts)

    doc = %{
      omp: %{installed: omp_executable(opts) != nil},
      broker: %{
        # A loopback address is shown; another host stays behind its env name.
        endpoint:
          case local_port(url) do
            nil -> "remote"
            port -> "127.0.0.1:#{port}"
          end,
        reachable: reachable,
        version: version,
        token: match?({:ok, _}, endpoint),
        service: service,
        error: broker_error && Atom.to_string(broker_error)
      },
      providers:
        Enum.map(rows, fn row ->
          %{
            omp: row.omp,
            lemon: row.lemon && config_name(row.lemon),
            oauth: row.oauth,
            apiKeys: row.api_key,
            connected: row.connected
          }
        end),
      connected: connected
    }

    if parsed[:json] do
      IO.puts(Jason.encode!(doc))
    else
      print_status(io, doc, rows, broker_error)
    end

    if reachable and Enum.all?(connected, & &1.usable), do: :ok, else: {:error, :not_ready}
  end

  defp print_status(io, doc, rows, broker_error) do
    broker = doc.broker
    io.info.("omp:     #{if doc.omp.installed, do: "installed", else: "not found on PATH"}")

    io.info.(
      "Broker:  " <>
        if(broker.reachable,
          do: "running#{if broker.version, do: " (omp #{broker.version})", else: ""}",
          else: "not running"
        ) <>
        if(broker.endpoint == "remote",
          do: " at OMP_AUTH_BROKER_URL",
          else: " on #{broker.endpoint}"
        ) <>
        "; service #{broker.service}"
    )

    unless broker.token, do: io.info.("Token:   missing (`omp auth-broker token` creates it)")

    cond do
      rows != [] ->
        io.info.("")
        io.info.("omp holds credentials for:")
        Enum.each(rows, &io.info.("  " <> row_line(&1)))

      broker_error && broker_error != :broker_unreachable ->
        io.info.("Broker:  " <> OmpAuthBroker.error_message(broker_error))

      true ->
        :ok
    end

    io.info.("")

    case doc.connected do
      [] ->
        io.info.("No Lemon provider uses omp's credentials yet. Run `lemon setup omp`.")

      connected ->
        io.info.("Lemon providers using omp:")

        Enum.each(connected, fn %{provider: provider, usable: usable} ->
          io.info.("  #{provider}: #{if usable, do: "ready", else: "no usable credential"}")
        end)
    end
  end

  defp service_state(opts) do
    status = Keyword.get(opts, :service_status, &LemonCore.Service.status/2)

    case status.(["omp-broker"], []) do
      {:ok, %{units: [%{state: state} | _]}} -> state
      _ -> "unknown"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # disconnect
  # ──────────────────────────────────────────────────────────────────────────

  defp disconnect(args, io, _opts) do
    parsed = parse!(args, @disconnect_switches, "lemon setup omp disconnect")
    Runner.ensure_required_apps!()
    config_path = parsed[:config_path] || LemonCore.Config.global_path()
    config = read_config!(config_path)
    connected = connected_providers(config)
    requested = Keyword.get_values(parsed, :provider)

    providers =
      cond do
        parsed[:all] == true and requested != [] ->
          Runner.fail!("Use either --all or --provider, not both.")

        parsed[:all] == true ->
          connected

        requested != [] ->
          Enum.map(requested, fn name ->
            canonical = ProviderNames.canonical_name(name)

            if canonical in connected,
              do: canonical,
              else: Runner.fail!("`#{name}` does not use omp's credentials.")
          end)

        true ->
          Runner.fail!("Pass --all or --provider NAME.")
      end

    if providers == [] do
      io.info.("No Lemon provider uses omp's credentials; nothing changed.")
      :ok
    else
      case ProviderManagement.persist(config_path, [], &disconnect_patch(&1, providers)) do
        :ok ->
          io.info.(
            "Lemon no longer uses omp's credentials for: #{Enum.map_join(providers, ", ", &label/1)}."
          )

          io.info.(
            "omp's logins are unchanged. Stop the broker service with " <>
              "`lemon service uninstall omp-broker` when nothing else uses it."
          )

          with {provider, _model} <- current_default(config),
               canonical when is_binary(canonical) <- ProviderNames.canonical_name(provider),
               true <- canonical in providers,
               cfg =
                 config |> Map.get("providers", %{}) |> ProviderNames.provider_config(canonical),
               false <-
                 Enum.any?(
                   ~w(oauth_secret api_key api_key_secret api_key_env),
                   &is_binary((cfg || %{})[&1])
                 ) do
            io.info.(
              "#{label(canonical)} is still the default provider; give it a Lemon login or key " <>
                "with `lemon setup provider`, or choose another default."
            )
          end

          :ok

        {:error, _} ->
          Runner.fail!("Could not save the config. Run `lemon config validate`.")
      end
    end
  end

  defp disconnect_patch(content, providers) do
    tables = provider_tables(content)
    decoded = decode(content)

    Enum.reduce(providers, content, fn provider, acc ->
      name = Map.get(tables, provider, config_name(provider))
      table = "providers." <> name
      cfg = get_in(decoded, ["providers", name]) || %{}

      acc =
        Enum.reduce(~w(auth_source omp_provider omp_account), acc, fn key, patched ->
          TomlPatch.delete_key(patched, table, key)
        end)

      # A Lemon login or key still named in the table becomes active again; a
      # table that only selected the broker goes away with it.
      cond do
        is_binary(cfg["oauth_secret"]) ->
          TomlPatch.upsert_string(acc, table, "auth_source", "oauth")

        provider == "openai_codex" and
            Enum.any?(~w(api_key api_key_secret api_key_env), &is_binary(cfg[&1])) ->
          TomlPatch.upsert_string(acc, table, "auth_source", "api_key")

        Map.keys(cfg) -- ~w(auth_source omp_provider omp_account omp_path) == [] ->
          TomlPatch.delete_table_tree(acc, table)

        true ->
          acc
      end
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp broker_rows!(endpoint, config) do
    case OmpAuthBroker.snapshot(endpoint, fresh: true) do
      {:ok, %{entries: []}} ->
        Runner.fail!(
          "omp's auth broker holds no credentials. Sign in from omp first " <>
            "(`/login` in omp, or `omp auth-broker login PROVIDER`), then rerun `lemon setup omp`."
        )

      {:ok, %{entries: entries}} ->
        rows(entries, config)

      {:error, reason} ->
        Runner.fail!(OmpAuthBroker.error_message(reason))
    end
  end

  defp rows(entries, config) do
    lemon_by_omp = lemon_providers_by_omp_id()
    connected = MapSet.new(connected_providers(config))

    entries
    |> Enum.group_by(& &1.provider)
    |> Enum.sort_by(fn {omp, _} -> omp end)
    |> Enum.map(fn {omp, list} ->
      lemon = Map.get(lemon_by_omp, omp)

      %{
        omp: omp,
        lemon: lemon,
        oauth: Enum.count(list, &(&1.credential.type == :oauth)),
        api_key: Enum.count(list, &(&1.credential.type == :api_key)),
        connected: lemon != nil and MapSet.member?(connected, lemon)
      }
    end)
  end

  defp row_line(row) do
    counts =
      [{row.oauth, "login"}, {row.api_key, "API key"}]
      |> Enum.reject(fn {count, _} -> count == 0 end)
      |> Enum.map_join(", ", fn {count, noun} ->
        "#{count} #{noun}#{if count > 1, do: "s", else: ""}"
      end)

    target =
      cond do
        is_nil(row.lemon) -> "no matching Lemon provider"
        row.connected -> "Lemon #{config_name(row.lemon)} (already using omp)"
        true -> "Lemon #{config_name(row.lemon)}"
      end

    String.pad_trailing(row.omp, 22) <> String.pad_trailing(counts, 18) <> " → " <> target
  end

  # Inverse of `OmpBroker.omp_provider/2` over Lemon's built-in providers.
  defp lemon_providers_by_omp_id do
    Enum.reduce(ProviderNames.all_canonical_names(), %{}, fn canonical, acc ->
      case OmpBroker.omp_provider(canonical, nil) do
        nil -> acc
        omp -> Map.put_new(acc, omp, canonical)
      end
    end)
  end

  defp connected_providers(config) do
    config
    |> Map.get("providers", %{})
    |> Enum.flat_map(fn {name, cfg} ->
      with true <- is_map(cfg),
           "omp_broker" <- LemonCore.Config.Providers.normalize_auth_source(cfg["auth_source"]),
           canonical when is_binary(canonical) <- ProviderNames.canonical_name(name) do
        [canonical]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The config table each canonical provider already uses (`[providers.codex]`
  # stays `codex`), so a provider never ends up with two tables.
  defp provider_tables(content) do
    content
    |> decode()
    |> Map.get("providers", %{})
    |> Enum.reduce(%{}, fn {name, _cfg}, acc ->
      case ProviderNames.canonical_name(name) do
        nil -> acc
        canonical -> Map.put_new(acc, canonical, name)
      end
    end)
  end

  defp broker_cfg(config, provider) do
    config
    |> Map.get("providers", %{})
    |> ProviderNames.provider_config(provider)
    |> Kernel.||(%{})
    |> Map.put("auth_source", "omp_broker")
  end

  defp current_default(config) do
    case Map.get(config, "defaults") do
      %{"provider" => provider, "model" => model} when is_binary(provider) and is_binary(model) ->
        {provider, model |> String.split(":", parts: 2) |> List.last()}

      _ ->
        nil
    end
  end

  defp catalog_models(provider) do
    atom = ProviderNames.provider_atom(provider)

    if atom in LemonAi.Models.get_providers() do
      atom
      |> LemonAi.Models.get_models()
      |> Enum.map(&%{provider: to_string(&1.provider), id: &1.id, name: &1.name})
      |> ModelCatalog.sort_for_picker()
      |> Enum.map(& &1.id)
      |> Enum.uniq()
    else
      []
    end
  end

  defp label(provider) do
    case Providers.find(config_name(provider)) do
      %{display_name: name} -> name
      _ -> config_name(provider)
    end
  end

  defp config_name(provider), do: ProviderNames.config_name(provider) || to_string(provider)

  defp omp_executable(opts) do
    case Keyword.get(opts, :omp_bin) do
      nil -> Role.omp_executable([])
      path -> path
    end
  end

  # omp's agent directory: `PI_CODING_AGENT_DIR`, else `<config root>/agent`.
  defp omp_agent_dir do
    case System.get_env("PI_CODING_AGENT_DIR") do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _ -> Path.join(OmpConfig.config_root(), "agent")
    end
  end

  defp read_config!(config_path) do
    case File.read(config_path) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, decoded} ->
            decoded

          {:error, _} ->
            Runner.fail!("The config file is not valid TOML. Run `lemon config validate`.")
        end

      {:error, :enoent} ->
        %{}

      {:error, _} ->
        Runner.fail!("Could not read the config file. Check its permissions.")
    end
  end

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp parse!(args, switches, command) do
    case OptionParser.parse(args, strict: switches, aliases: [n: :non_interactive]) do
      {parsed, [], []} -> parsed
      _ -> Runner.fail!("Invalid options. Run `#{command} --help`.")
    end
  end

  defp choose(io, title, options, default_index \\ 0) do
    case PromptUI.select_value(io, %{title: title, options: options, default_index: default_index}) do
      {:ok, value} ->
        {:ok, value}

      :cancel ->
        :cancel

      :fallback ->
        io.info.("")
        io.info.(title)

        options
        |> Enum.with_index(1)
        |> Enum.each(fn {option, number} ->
          marker = if number == default_index + 1, do: " (default)", else: ""
          io.info.("  #{number}. #{option.label}#{marker}")
        end)

        prompt_choice(io, options, default_index)
    end
  end

  defp prompt_choice(io, options, default_index) do
    input =
      io.prompt.("Select [default: #{default_index + 1}, q to cancel]: ")
      |> PromptUI.normalize_input!()

    number =
      case Integer.parse(input) do
        {n, ""} when n >= 1 and n <= length(options) -> n
        _ -> nil
      end

    cond do
      input == "" ->
        {:ok, Enum.at(options, default_index).value}

      input in ["q", "quit", "cancel"] ->
        :cancel

      number ->
        {:ok, Enum.at(options, number - 1).value}

      true ->
        io.error.("Enter a number from the list.")
        prompt_choice(io, options, default_index)
    end
  end
end
