defmodule LemonCli.ProvidersCommand do
  @moduledoc """
  Unified packaged/source provider readiness and routing configuration CLI.

  Text output is concise and always redacted. `--json` writes one stable JSON
  document to stdout on success or stderr on failure. Exit codes follow the
  runtime CLI contract: 0 success, 1 operational/configuration failure, and 2
  invalid arguments.
  """

  alias LemonAgent.ModelRuntime.{ProviderConfiguration, ProviderStatus}
  alias LemonCli.Onboarding.LogSilencer

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  @switches [
    provider: :keep,
    include_catalog: :boolean,
    project_dir: :string,
    config_path: :string,
    scope: :string,
    json: :boolean,
    dry_run: :boolean,
    strategy: :string,
    activate: :boolean,
    confirm: :string,
    help: :boolean
  ]

  @aliases [p: :provider, h: :help]

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) when is_list(args) do
    run_guarded(args, "--json" in args)
  end

  defp run_guarded(args, json?) do
    case parse(args) do
      {:ok, :help, _opts} ->
        print_usage()
        @exit_ok

      {:ok, :status, opts} ->
        run_status(opts)

      {:ok, {:configure, action, attrs}, opts} ->
        run_configure(action, attrs, opts)

      {:error, message} ->
        render_error(:invalid_arguments, message, json?, @exit_usage)
    end
  rescue
    _ -> render_error(:provider_command_failed, "Provider command failed", json?, @exit_error)
  catch
    :exit, _ ->
      render_error(:provider_command_failed, "Provider command failed", json?, @exit_error)
  end

  defp parse(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      invalid != [] ->
        {:error, "Invalid provider options"}

      opts[:help] ->
        {:ok, :help, opts}

      positional in [[], ["status"], ["list"]] ->
        {:ok, :status, opts}

      positional == ["fallback", "list"] ->
        {:ok, :status, opts}

      match?(["fallback", "add", _], positional) ->
        [_, _, provider] = positional
        {:ok, {:configure, "fallback.add", %{"provider" => provider}}, opts}

      match?(["fallback", "remove", _], positional) ->
        [_, _, provider] = positional
        {:ok, {:configure, "fallback.remove", %{"provider" => provider}}, opts}

      positional == ["fallback", "clear"] ->
        {:ok, {:configure, "fallback.clear", %{}}, opts}

      positional == ["pool", "list"] ->
        {:ok, :status, opts}

      match?(["pool", "set", _], positional) ->
        [_, _, pool] = positional
        providers = Keyword.get_values(opts, :provider)

        if providers == [] do
          {:error, "pool set requires at least one --provider"}
        else
          {:ok,
           {:configure, "pool.upsert",
            %{
              "pool" => pool,
              "providers" => providers,
              "strategy" => opts[:strategy] || "priority",
              "activate" => opts[:activate] == true
            }}, opts}
        end

      match?(["pool", "delete", _], positional) ->
        [_, _, pool] = positional
        {:ok, {:configure, "pool.delete", %{"pool" => pool}}, opts}

      match?(["pool", "credential", "add", _, _, _], positional) ->
        [_, _, _, pool, provider, credential_ref] = positional

        {:ok,
         {:configure, "pool.credential.add",
          %{"pool" => pool, "provider" => provider, "credentialRef" => credential_ref}}, opts}

      match?(["pool", "credential", "remove", _, _, _], positional) ->
        [_, _, _, pool, provider, credential_ref] = positional

        {:ok,
         {:configure, "pool.credential.remove",
          %{"pool" => pool, "provider" => provider, "credentialRef" => credential_ref}}, opts}

      match?(["pool", "credential", "clear", _, _], positional) ->
        [_, _, _, pool, provider] = positional

        {:ok, {:configure, "pool.credential.clear", %{"pool" => pool, "provider" => provider}},
         opts}

      true ->
        {:error, "Unsupported providers command"}
    end
  end

  defp run_status(opts) do
    if opts[:help] do
      print_usage()
      @exit_ok
    else
      json? = opts[:json] == true

      status =
        LogSilencer.with_quiet_logs(json?, fn ->
          ensure_started!()
          ProviderStatus.snapshot(status_params(opts))
        end)

      render_success(status, json?, &render_status/1)
    end
  end

  defp run_configure(action, attrs, opts) do
    if opts[:help] do
      print_usage()
      @exit_ok
    else
      json? = opts[:json] == true

      params =
        attrs
        |> Map.put("action", action)
        |> Map.put("apply", opts[:dry_run] != true)
        |> maybe_put("confirm", opts[:confirm])
        |> maybe_put("scope", opts[:scope])
        |> maybe_put("projectDir", opts[:project_dir])
        |> maybe_put("configPath", opts[:config_path])

      result =
        LogSilencer.with_quiet_logs(json?, fn ->
          ensure_started!()
          ProviderConfiguration.configure(params)
        end)

      case result do
        {:ok, result} ->
          render_success(result, json?, &render_configuration/1)

        {:error, code, message} ->
          render_error(code, message, json?, @exit_error)
      end
    end
  end

  defp status_params(opts) do
    providers = Keyword.get_values(opts, :provider)

    %{}
    |> maybe_put("provider", if(length(providers) == 1, do: hd(providers)))
    |> maybe_put("providers", if(length(providers) > 1, do: providers))
    |> maybe_put("includeCatalog", opts[:include_catalog])
    |> maybe_put("projectDir", opts[:project_dir])
  end

  defp render_success(result, true, _renderer) do
    IO.puts(Jason.encode!(%{"ok" => true, "result" => result}))
    @exit_ok
  end

  defp render_success(result, false, renderer) do
    renderer.(result)
    @exit_ok
  end

  defp render_error(code, message, true, exit_code) do
    IO.puts(
      :stderr,
      Jason.encode!(%{
        "ok" => false,
        "error" => %{"code" => to_string(code), "message" => message}
      })
    )

    exit_code
  end

  defp render_error(code, message, false, exit_code) do
    IO.puts(:stderr, "Error (#{code}): #{message}")
    IO.puts(:stderr, "Run `lemon providers --help` for usage.")
    exit_code
  end

  defp render_status(status) do
    routing = Map.get(status, "routing", %{})
    config = Map.get(status, "routingConfig", %{})

    IO.puts("Lemon Providers")
    IO.puts("Ready: #{Map.get(status, "readyCount", 0)}/#{Map.get(status, "count", 0)}")
    IO.puts("Default provider: #{Map.get(status, "defaultProvider") || "(none)"}")
    IO.puts("Default model: #{Map.get(status, "defaultModel") || "(none)"}")
    IO.puts("Routing decision: #{Map.get(routing, "decision") || "(none)"}")
    IO.puts("Selected provider: #{Map.get(routing, "selectedProvider") || "(none)"}")
    render_routing_config(config)
    IO.puts("")

    status
    |> Map.get("providers", [])
    |> Enum.each(fn provider ->
      IO.puts(
        "#{provider["provider"]}: configured=#{provider["configured"] == true} " <>
          "credential_ready=#{provider["credentialReady"] == true}"
      )
    end)
  end

  defp render_configuration(result) do
    mode = if result["applied"], do: "applied", else: "preview"
    IO.puts("Provider configuration #{mode}: #{result["action"]}")
    IO.puts("Changed: #{result["changed"] == true}")
    IO.puts("Target scope: #{result["targetScope"]}")
    render_routing_config(result["proposedRoutingConfig"] || result["routingConfig"] || %{})

    case get_in(result, ["confirmation", "required"]) do
      true ->
        IO.puts("Confirmation required: --confirm #{result["confirmation"]["value"]}")

      _ ->
        :ok
    end
  end

  defp render_routing_config(config) do
    fallbacks = Map.get(config, "fallbackProviders", [])
    IO.puts("Fallbacks: #{if fallbacks == [], do: "(none)", else: Enum.join(fallbacks, ", ")}")
    IO.puts("Default pool: #{Map.get(config, "defaultPool") || "(none)"}")

    config
    |> Map.get("credentialPools", [])
    |> Enum.each(fn pool ->
      IO.puts(
        "Pool #{pool["name"]}: strategy=#{pool["strategy"]} " <>
          "providers=#{Enum.join(pool["providers"], ",")} " <>
          "credential_refs=#{pool["credentialReferenceCount"]}"
      )
    end)
  end

  defp ensure_started! do
    case Application.ensure_all_started(:lemon_agent) do
      {:ok, _} -> :ok
      {:error, _} -> raise "provider runtime unavailable"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def print_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon providers [status] [options]
           lemon providers fallback <list|add|remove|clear> [provider] [options]
           lemon providers pool <list|set|delete> [pool] [options]
           lemon providers pool credential <add|remove|clear> <pool> <provider> [ref] [options]

    Status options:
      --provider P              Filter or repeat for multiple providers
      --include-catalog         Include every known provider
      --project-dir PATH        Resolve project configuration from PATH
      --json                    Emit one stable redacted JSON document

    Mutation options:
      --scope global|project    Target global config (default) or project config
      --config-path PATH        Explicit config path for local CLI use
      --project-dir PATH        Project root when --scope project is selected
      --dry-run                 Preview without writing
      --confirm VALUE           Confirm a destructive remove/clear/update

    Pool set options:
      --provider P              Pool provider; repeat for additional providers
      --strategy priority|round_robin
      --activate                Set this pool as the default pool

    Credential refs must be `secret:NAME` or `env:NAME`. Values remain in the
    existing encrypted secret store/environment and are never copied into TOML.
    """)
  end
end
