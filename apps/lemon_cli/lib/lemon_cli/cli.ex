defmodule LemonCli.CLI do
  @moduledoc """
  Runtime command-line entrypoint for Lemon.

  `main/1` is the single halting boundary: the packaged launcher invokes it
  through the selected release executable's `eval` with the forwarded
  `System.argv()` and it converts the dispatch result into a process exit
  code (`0` success, `1` failure, `2` usage error). Everything underneath —
  `run/1` and the per-command handlers — is reusable and never halts, so
  `Mix.Tasks.Lemon.Setup` and tests exercise exactly the same code paths
  without Mix being available.

  ## Commands

      setup [provider|runtime|gateway|doctor] [--non-interactive] [--config-path PATH]
      model [--provider P] [--token T] [--auth oauth|api_key] [--model M] [--set-default]
      gateway setup [transport] [--transport NAME] [--non-interactive]
      doctor [--verbose] [--json] [--bundle [PATH]] [--bundle-path PATH] [--project-dir PATH]
      config [validate|show] [--verbose] [--project-dir PATH]
      secrets <status|init|set|list|delete|check|import-env>
      channels [--project-dir PATH] [--json]

  `model` delegates to provider onboarding; `gateway setup` delegates to the
  gateway setup adapters.
  """

  alias LemonCore.Config.Modular
  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.{Gateway, Provider, Verification, Wizard}
  alias LemonCore.Doctor
  alias LemonCore.Doctor.{Check, Report, SupportBundle}
  alias LemonCore.Secrets
  alias LemonCore.Secrets.MasterKey

  defmodule Error do
    @moduledoc """
    Runtime error with a user-readable message and a CLI exit code.

    The setup/onboarding runtime raises this instead of `Mix.Error` when Mix
    is unavailable (packaged releases). The CLI boundary renders the message
    on stderr and exits with `exit_code`.
    """

    defexception [:message, exit_code: 1]
  end

  @commands ~w(setup model gateway doctor config secrets channels)

  @exit_ok 0
  @exit_error 1
  @exit_usage 2

  # Mirrors `Mix.Tasks.Lemon.Secrets.Check` / `Lemon.Secrets.ImportEnv`, the
  # canonical list of env-var secret names. Kept here so `lemon secrets`
  # works from packaged releases, where Mix task modules do not exist.
  @known_secrets [
    # AI providers
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_CODEX_API_KEY",
    "CHATGPT_TOKEN",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AZURE_OPENAI_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "XAI_API_KEY",
    "CEREBRAS_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "OPENCODE_API_KEY",
    # Coding agent tools
    "PERPLEXITY_API_KEY",
    "OPENROUTER_API_KEY",
    "FIRECRAWL_API_KEY",
    "BRAVE_API_KEY",
    "GITHUB_TOKEN",
    # X/Twitter API
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET",
    # Market intel
    "MARKET_INTEL_BASESCAN_KEY",
    "MARKET_INTEL_DEXSCREENER_KEY",
    "MARKET_INTEL_OPENAI_KEY",
    "MARKET_INTEL_ANTHROPIC_KEY"
  ]

  @doc """
  Returns whether interactive setup is still required.

  Setup derives the same state as the idempotent setup wizard. Configuration,
  secret, and provider resolution failures intentionally fail closed. This is
  Mix-free so packaged launchers can call it before starting the daemon.
  """
  @spec setup_required?() :: boolean()
  def setup_required? do
    case ensure_lemon_core_started() do
      :ok ->
        (Verification.setup_state()
         |> Verification.pending_steps()) != []

      :error ->
        true
    end
  rescue
    _ -> true
  catch
    _, _ -> true
  end

  @doc """
  Halting entry point. Exits `0` on success, `1` on failure, `2` on usage
  errors. User-readable error messages are printed on stderr.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    System.halt(run(argv))
  end

  @doc """
  Non-halting dispatch over `argv` (command word included). Returns the
  process exit code. Reusable from Mix tasks and tests.
  """
  @spec run([String.t()]) :: 0 | 1 | 2
  def run(argv) when is_list(argv) do
    argv
    |> List.wrap()
    |> dispatch()
  rescue
    error in Error ->
      IO.puts(:stderr, "Error: #{error.message}")
      error.exit_code

    # Source checkouts still surface Mix errors (e.g. from task-owned code
    # this CLI delegates to); render them the same user-readable way.
    error in Mix.Error ->
      IO.puts(:stderr, "Error: #{Exception.message(error)}")
      @exit_error
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Dispatch
  # ──────────────────────────────────────────────────────────────────────────

  defp dispatch([]) do
    print_usage(:stderr)
    @exit_usage
  end

  defp dispatch([flag]) when flag in ["--help", "-h", "help"] do
    print_usage()
    @exit_ok
  end

  defp dispatch([command | rest]) when command in @commands do
    # Intercept help anywhere in the command's arguments — including after
    # subcommand words like `gateway setup --help` — so nothing downstream
    # (wizard, provider picker, gateway adapters, prompts on EOF) ever runs.
    if help_requested?(rest) do
      print_command_usage(command)
      @exit_ok
    else
      run_command(command, rest)
    end
  end

  defp dispatch([command | _rest]) do
    IO.puts(:stderr, "Unknown command: #{command}")
    IO.puts(:stderr, "")
    print_usage(:stderr)
    @exit_usage
  end

  defp help_requested?(args), do: Enum.any?(args, &(&1 in ["--help", "-h", "help"]))

  defp run_command("setup", args), do: run_setup(args)
  defp run_command("model", args), do: run_model(args)
  defp run_command("gateway", args), do: run_gateway(args)
  defp run_command("doctor", args), do: doctor(args)
  defp run_command("config", args), do: run_config(args)
  defp run_command("secrets", args), do: run_secrets(args)
  defp run_command("channels", args), do: run_channels(args)

  # ──────────────────────────────────────────────────────────────────────────
  # setup / model / gateway
  # ──────────────────────────────────────────────────────────────────────────

  defp run_setup(args) do
    case Wizard.run(args, Runner.default_io(), usage_command: "lemon setup") do
      :ok -> @exit_ok
      {:error, reason} -> exit_code_for(reason)
    end
  end

  defp run_model(args) do
    # Pre-check failures print their own guidance through the io callbacks;
    # hard failures surface as raised errors handled by run/1.
    case Provider.run(args, Runner.default_io()) do
      :ok -> @exit_ok
      {:error, _reason} -> @exit_error
    end
  end

  defp run_gateway(args) do
    # The launcher contract is `gateway setup <transport>`; the bare
    # `gateway <transport>` form forwards identically.
    forwarded =
      case args do
        ["setup" | rest] -> rest
        rest -> rest
      end

    case Gateway.run(forwarded, Runner.default_io()) do
      :ok -> @exit_ok
      {:error, reason} -> exit_code_for(reason)
    end
  end

  defp exit_code_for(reason) when reason in [:unknown_subcommand, :unknown_transport],
    do: @exit_usage

  defp exit_code_for(_reason), do: @exit_error

  # ──────────────────────────────────────────────────────────────────────────
  # doctor
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Runs diagnostics and prints a report without halting.

  Returns `0` when no checks fail, `1` when diagnostics fail, and `2` for
  invalid command arguments. Reused by `LemonCli.Setup.Wizard` for the
  `setup doctor` subcommand.
  """
  @spec doctor([String.t()]) :: 0 | 1 | 2
  def doctor(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          verbose: :boolean,
          json: :boolean,
          project_dir: :string,
          bundle: :boolean,
          bundle_path: :string
        ],
        aliases: [v: :verbose]
      )

    cond do
      invalid != [] ->
        print_usage_error("Invalid options: #{inspect(invalid)}", &print_doctor_usage/1)

      not valid_doctor_positionals?(opts, positional) ->
        print_usage_error(
          "Unsupported arguments: #{Enum.map_join(positional, " ", &inspect/1)}",
          &print_doctor_usage/1
        )

      true ->
        ensure_apps_started!([:lemon_core])

        report = Doctor.report(Keyword.take(opts, [:project_dir]))

        if opts[:json] do
          IO.puts(Report.to_json(report))
        else
          print_report(report, opts[:verbose] || false)
        end

        maybe_write_bundle(report, opts, positional)

        if Report.ok?(report) do
          @exit_ok
        else
          IO.puts(:stderr, "Diagnostics failed: #{report.fail} check(s) failed.")
          @exit_error
        end
    end
  end

  defp valid_doctor_positionals?(_opts, []), do: true

  defp valid_doctor_positionals?(opts, [path]) when is_binary(path) and path != "",
    do: opts[:bundle] == true

  defp valid_doctor_positionals?(_opts, _positional), do: false

  defp maybe_write_bundle(report, opts, positional) do
    if opts[:bundle] do
      bundle_opts =
        opts
        |> Keyword.take([:project_dir, :bundle_path])
        |> maybe_default_bundle_path(positional)

      case SupportBundle.write(report, bundle_opts) do
        {:ok, path} ->
          message = "Support bundle written: #{path}"

          if opts[:json] do
            IO.puts(:stderr, message)
          else
            IO.puts(message)
          end

        {:error, reason} ->
          raise Error, message: "Failed to write support bundle: #{inspect(reason)}"
      end
    end
  end

  defp maybe_default_bundle_path(keyword, [path | _]) when is_binary(path) and path != "",
    do: Keyword.put_new(keyword, :bundle_path, path)

  defp maybe_default_bundle_path(keyword, _positional), do: keyword

  # Mirrors LemonCore.Doctor.Report.print/2, which routes through Mix.shell()
  # and therefore cannot run from packaged releases.
  defp print_report(%Report{} = report, verbose?) do
    IO.puts("")
    IO.puts("Lemon Doctor")
    IO.puts("────────────")

    Enum.each(report.checks, fn check ->
      if verbose? or check.status in [:warn, :fail] do
        status_label = String.pad_trailing("[#{Check.label(check.status)}]", 7)

        IO.puts(
          IO.ANSI.format([Check.color(check.status), status_label, :reset, " #{check.name}"])
        )

        if check.message && check.message != "OK" do
          IO.puts("        #{check.message}")
        end

        if check.remediation do
          IO.puts(IO.ANSI.format([:cyan, "        → #{check.remediation}", :reset]))
        end
      end
    end)

    IO.puts("")

    IO.puts(
      IO.ANSI.format([
        Check.color(Report.overall(report)),
        "#{report.pass} passed  #{report.warn} warnings  #{report.fail} failed  #{report.skip} skipped",
        :reset
      ])
    )

    IO.puts("")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # config
  # ──────────────────────────────────────────────────────────────────────────

  defp run_config(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [verbose: :boolean, project_dir: :string],
        aliases: [v: :verbose, p: :project_dir]
      )

    case {invalid, positional} do
      {[_ | _], _} ->
        print_usage_error("Invalid options: #{inspect(invalid)}", &print_config_usage/1)

      {[], ["validate"]} ->
        validate_config(opts)

      {[], ["show"]} ->
        show_config(opts)

      {[], []} ->
        print_usage_error(
          "Missing config command. Expected `validate` or `show`.",
          &print_config_usage/1
        )

      {[], _} ->
        print_usage_error(
          "Unsupported arguments: #{Enum.map_join(positional, " ", &inspect/1)}",
          &print_config_usage/1
        )
    end
  end

  defp validate_config(opts) do
    ensure_apps_started!([:lemon_core])

    project_dir = opts[:project_dir]
    verbose? = opts[:verbose] || false
    load_opts = if project_dir, do: [project_dir: project_dir], else: []

    IO.puts("Validating Lemon configuration...")

    if project_dir do
      IO.puts("  Project directory: #{project_dir}")
    end

    case Modular.load_with_validation(load_opts) do
      {:ok, config} ->
        IO.puts(IO.ANSI.format([:green, "✓ Configuration is valid", :reset]))

        if verbose? do
          print_config_summary(config)
        end

        @exit_ok

      {:error, errors} ->
        IO.puts(:stderr, IO.ANSI.format([:red, "✗ Configuration has errors:", :reset]))

        Enum.each(errors, fn error ->
          IO.puts(:stderr, "  • #{error}")
        end)

        if verbose? do
          IO.puts("")
          IO.puts("Configuration files checked:")
          IO.puts("  Global: #{Modular.global_path()}")
          IO.puts("  Project: #{Modular.project_path(project_dir || File.cwd!())}")
        end

        IO.puts(:stderr, "Configuration validation failed")
        @exit_error
    end
  end

  defp show_config(opts) do
    ensure_apps_started!([:lemon_core])

    project_dir = opts[:project_dir]
    load_opts = if project_dir, do: [project_dir: project_dir], else: []

    config = Modular.load(load_opts)

    IO.puts("Current Lemon Configuration")
    IO.puts("===========================")
    IO.puts("")

    print_config_summary(config)

    IO.puts("")
    IO.puts("Configuration sources:")
    IO.puts("  Global: #{Modular.global_path()}")
    IO.puts("  Project: #{Modular.project_path(project_dir || File.cwd!())}")

    @exit_ok
  end

  defp print_config_summary(config) do
    IO.puts("")
    IO.puts("Agent:")
    IO.puts("  Default model: #{config.agent.default_model || "(not set)"}")
    IO.puts("  Default provider: #{config.agent.default_provider || "(not set)"}")
    IO.puts("  Thinking level: #{config.agent.default_thinking_level || "(not set)"}")

    IO.puts("")
    IO.puts("Gateway:")
    IO.puts("  Max concurrent runs: #{config.gateway.max_concurrent_runs || "(not set)"}")
    IO.puts("  Auto resume: #{config.gateway.auto_resume || "(not set)"}")
    IO.puts("  Channels enabled: #{enabled_channels(config.gateway)}")

    IO.puts("")
    IO.puts("Logging:")
    IO.puts("  Level: #{config.logging.level || "(not set)"}")
    IO.puts("  File: #{config.logging.file || "(not set)"}")

    IO.puts("")
    IO.puts("TUI:")
    IO.puts("  Theme: #{config.tui.theme || "(not set)"}")
    IO.puts("  Debug: #{config.tui.debug || "(not set)"}")

    IO.puts("")
    IO.puts("Providers:")

    if config.providers.providers && map_size(config.providers.providers) > 0 do
      Enum.each(config.providers.providers, fn {name, provider_config} ->
        has_key = if provider_config.api_key, do: "✓", else: "✗"
        IO.puts("  #{name}: API key #{has_key}")
      end)
    else
      IO.puts("  (none configured)")
    end
  end

  defp enabled_channels(gateway) do
    gateway
    |> Map.get(:enabled_channels, %{})
    |> Enum.filter(fn {_id, enabled?} -> enabled? end)
    |> Enum.map(fn {id, _enabled?} -> to_string(id) end)
    |> Enum.sort()
    |> case do
      [] -> "(none)"
      ids -> Enum.join(ids, ", ")
    end
  end

  defp print_config_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon config [validate|show] [options]

    Commands:
      validate   Validate the current configuration
      show       Show the current configuration

    Options:
      --verbose, -v           Verbose output
      --project-dir, -p PATH  Project directory for project-config checks
    """)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # secrets
  # ──────────────────────────────────────────────────────────────────────────

  defp run_secrets(["status" | _rest]), do: secrets_status()
  defp run_secrets(["init" | rest]), do: secrets_init(rest)
  defp run_secrets(["set" | rest]), do: secrets_set(rest)
  defp run_secrets(["list" | _rest]), do: secrets_list()
  defp run_secrets(["delete" | rest]), do: secrets_delete(rest)
  defp run_secrets(["check" | _rest]), do: secrets_check()
  defp run_secrets(["import-env" | rest]), do: secrets_import_env(rest)

  defp run_secrets(_other) do
    print_secrets_usage()
    @exit_usage
  end

  defp secrets_status do
    ensure_apps_started!([:lemon_core])

    status = Secrets.status()

    IO.puts("configured: #{status.configured}")
    IO.puts("source: #{status.source || "none"}")
    IO.puts("keychain_available: #{status.keychain_available}")
    IO.puts("env_fallback: #{status.env_fallback}")

    if status.keychain_error do
      IO.puts("keychain_error: #{inspect(status.keychain_error)}")
    end

    IO.puts("owner: #{status.owner}")
    IO.puts("count: #{status.count}")

    @exit_ok
  end

  defp secrets_init(args) do
    ensure_apps_started!([:lemon_core])

    {parsed, _rest, _invalid} =
      OptionParser.parse(args, strict: [target: :string, force: :boolean])

    case MasterKey.init(init_opts(parsed)) do
      {:ok, %{source: :file, key_file: path}} ->
        IO.puts("Secrets master key written to #{path} (0600)")
        @exit_ok

      {:ok, %{source: source}} ->
        IO.puts("Secrets master key initialized in #{source}")
        @exit_ok

      {:error, :keychain_unavailable} ->
        IO.puts(
          :stderr,
          "Keychain is unavailable on this system and no key file location could be " <>
            "determined. Set #{MasterKey.env_var()}, or configure " <>
            "`config :lemon_core, LemonCore.Secrets, key_file: ...`."
        )

        @exit_error

      {:error, {:key_file_exists, path}} ->
        IO.puts(
          :stderr,
          "A secrets master key already exists at #{path}. Re-run with --force to " <>
            "replace it — every secret encrypted under the old key becomes unreadable."
        )

        @exit_error

      {:error, reason} ->
        IO.puts(:stderr, "Failed to initialize secrets master key: #{inspect(reason)}")
        @exit_error
    end
  end

  defp init_opts(parsed) do
    opts = if parsed[:force], do: [force: true], else: []

    case parsed[:target] do
      nil -> opts
      target -> [{:target, String.to_atom(target)} | opts]
    end
  end

  defp secrets_set(args) do
    ensure_apps_started!([:lemon_core])

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [name: :string, value: :string, provider: :string, expires_at: :integer],
        aliases: [n: :name, v: :value]
      )

    case parse_name_and_value(opts, positional) do
      {:ok, name, value} ->
        secrets_opts =
          []
          |> maybe_put(:provider, opts[:provider])
          |> maybe_put(:expires_at, opts[:expires_at])

        case Secrets.set(name, value, secrets_opts) do
          {:ok, metadata} ->
            IO.puts("Stored secret #{metadata.name} (owner=#{metadata.owner})")
            @exit_ok

          {:error, :missing_master_key} ->
            IO.puts(
              :stderr,
              "Missing secrets master key. Run `lemon secrets init` or set #{MasterKey.env_var()}."
            )

            @exit_error

          {:error, :weak_master_key} ->
            IO.puts(
              :stderr,
              "Secrets master key is not base64-encoded 32-byte key material. " <>
                "Generate one with `lemon secrets init` or openssl rand -base64 32."
            )

            @exit_error

          {:error, {:keychain_failed, reason}} ->
            IO.puts(
              :stderr,
              "Failed to read secrets master key from keychain: #{inspect(reason)}. " <>
                "Run `lemon secrets status` for diagnostics, then re-run `lemon secrets init` " <>
                "or set #{MasterKey.env_var()}."
            )

            @exit_error

          {:error, reason} ->
            IO.puts(:stderr, "Failed to store secret: #{inspect(reason)}")
            @exit_error
        end

      {:error, :usage} ->
        IO.puts(:stderr, "Usage: lemon secrets set <name> <value>")
        @exit_usage
    end
  end

  defp parse_name_and_value(opts, positional) do
    case {opts[:name], opts[:value], positional} do
      {name, value, _} when is_binary(name) and is_binary(value) and name != "" and value != "" ->
        {:ok, name, value}

      {nil, nil, [name, value | _]} ->
        {:ok, name, value}

      _ ->
        {:error, :usage}
    end
  end

  defp secrets_list do
    ensure_apps_started!([:lemon_core])

    {:ok, entries} = Secrets.list()

    if entries == [] do
      IO.puts("No secrets configured")
    else
      Enum.each(entries, fn entry ->
        IO.puts(
          "#{entry.name} provider=#{entry.provider} usage=#{entry.usage_count} expires_at=#{format_optional(entry.expires_at)}"
        )
      end)
    end

    @exit_ok
  end

  defp secrets_delete(args) do
    ensure_apps_started!([:lemon_core])

    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [name: :string], aliases: [n: :name])

    name = opts[:name] || List.first(positional)

    if not is_binary(name) or String.trim(name) == "" do
      IO.puts(:stderr, "Usage: lemon secrets delete <name>")
      @exit_usage
    else
      case Secrets.delete(name) do
        :ok ->
          IO.puts("Deleted secret #{String.trim(name)}")
          @exit_ok

        {:error, reason} ->
          IO.puts(:stderr, "Failed to delete secret: #{inspect(reason)}")
          @exit_error
      end
    end
  end

  defp secrets_check do
    ensure_apps_started!([:lemon_core])

    max_name_len = @known_secrets |> Enum.map(&String.length/1) |> Enum.max()

    IO.puts(String.pad_trailing("NAME", max_name_len) <> "  SOURCE   VALUE")
    IO.puts(String.duplicate("-", max_name_len + 30))

    results = Enum.map(@known_secrets, &check_secret(&1, max_name_len))

    from_store = Enum.count(results, &(&1 == :store))
    from_env = Enum.count(results, &(&1 == :env))
    missing = Enum.count(results, &(&1 == :missing))

    IO.puts("")
    IO.puts("#{from_store} from store, #{from_env} from env, #{missing} missing")

    @exit_ok
  end

  defp check_secret(name, max_name_len) do
    case Secrets.resolve(name) do
      {:ok, value, source} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing(to_string(source), 7)
        IO.puts("#{padded_name}  #{padded_source}  #{mask(value)}")
        source

      {:error, _reason} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing("missing", 7)
        IO.puts("#{padded_name}  #{padded_source}  ---")
        :missing
    end
  end

  defp mask(value) when byte_size(value) > 8 do
    first = String.slice(value, 0, 4)
    last = String.slice(value, -4, 4)
    "#{first}...#{last}"
  end

  defp mask(_value), do: "***"

  defp secrets_import_env(args) do
    ensure_apps_started!([:lemon_core])

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, force: :boolean],
        aliases: [d: :dry_run, f: :force]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    if dry_run do
      IO.puts("Dry run mode — no changes will be made")
    end

    results = Enum.map(@known_secrets, &process_secret(&1, dry_run, force))

    imported = Enum.count(results, &(&1 == :imported))
    already = Enum.count(results, &(&1 == :already_in_store))
    not_set = Enum.count(results, &(&1 == :not_in_env))
    errors = Enum.count(results, &match?({:error, _}, &1))

    IO.puts("")

    summary = "#{imported} imported, #{already} already in store, #{not_set} not in env"

    summary =
      if errors > 0,
        do: summary <> ", #{errors} errors",
        else: summary

    IO.puts(summary)

    if errors > 0, do: @exit_error, else: @exit_ok
  end

  defp process_secret(name, dry_run, force) do
    env_value = System.get_env(name)

    cond do
      is_nil(env_value) or env_value == "" ->
        IO.puts("#{name}: not set in env")
        :not_in_env

      not force and in_store?(name) ->
        IO.puts("#{name}: already in store")
        :already_in_store

      dry_run ->
        IO.puts("#{name}: would import")
        :imported

      true ->
        import_secret(name, env_value)
    end
  end

  defp in_store?(name), do: match?({:ok, _}, Secrets.get(name))

  defp import_secret(name, value) do
    case Secrets.set(name, value, provider: "import_env") do
      {:ok, _metadata} ->
        IO.puts("#{name}: imported")
        :imported

      {:error, reason} ->
        IO.puts("#{name}: error — #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp format_optional(nil), do: "never"
  defp format_optional(value), do: to_string(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_secrets_usage do
    IO.puts("""
    Usage: lemon secrets <command> [args]

    Commands:
      status
      init [--target file|keychain] [--force]
      set <name> <value> [--provider P] [--expires-at N]
      list
      delete <name>
      check
      import-env [--dry-run] [--force]
    """)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # channels
  # ──────────────────────────────────────────────────────────────────────────

  defp run_channels(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args, strict: [project_dir: :string, json: :boolean])

    if invalid != [] do
      IO.puts(:stderr, "Invalid options: #{inspect(invalid)}")
      @exit_usage
    else
      ensure_apps_started!([:lemon_core])

      project_dir = opts[:project_dir] || File.cwd!()

      status =
        :channel_readiness
        |> LemonCore.Doctor.RuntimeModules.fetch()
        |> apply(:status, [[project_dir: project_dir]])

      if opts[:json] do
        IO.puts(Jason.encode!(status, pretty: true))
      else
        print_channels(status)
      end

      @exit_ok
    end
  end

  defp print_channels(status) do
    cleanup = Map.get(status, :cleanup, %{})

    IO.puts("Lemon Channels")
    IO.puts("Status: #{Map.get(status, :status, "unknown")}")
    IO.puts("Promoted platforms: #{Enum.join(Map.get(status, :promoted_platforms, []), ", ")}")
    IO.puts("Gates: #{Map.get(status, :gate_count, 0)}")
    IO.puts("Passed: #{Map.get(status, :passed_count, 0)}")
    IO.puts("Blocked: #{Map.get(status, :blocked_count, 0)}")
    IO.puts("Warnings: #{Map.get(status, :warning_count, 0)}")
    IO.puts("Skipped: #{Map.get(status, :skipped_count, 0)}")
    IO.puts("Includes raw bot tokens: #{truthy?(cleanup[:includes_raw_bot_tokens])}")
    IO.puts("Includes secret names: #{truthy?(cleanup[:includes_secret_names])}")
    IO.puts("Includes chat IDs: #{truthy?(cleanup[:includes_chat_ids])}")
    IO.puts("Includes channel IDs: #{truthy?(cleanup[:includes_channel_ids])}")
    IO.puts("Includes message bodies: #{truthy?(cleanup[:includes_message_bodies])}")
    IO.puts("Includes raw proof paths: #{truthy?(cleanup[:includes_raw_proof_paths])}")
    IO.puts("Includes raw proof details: #{truthy?(cleanup[:includes_raw_proof_details])}")

    IO.puts("")
    IO.puts("Launch Gates:")

    status
    |> Map.get(:gates, [])
    |> Enum.each(fn gate ->
      reason = if gate[:reason_kind], do: " reason=#{gate.reason_kind}", else: ""
      next_action = if gate[:next_action], do: " next=#{gate.next_action}", else: ""
      IO.puts("  #{gate.id}: #{gate.status} evidence=#{gate.evidence}#{reason}#{next_action}")
    end)
  end

  defp truthy?(value), do: if(value, do: "true", else: "false")

  # ──────────────────────────────────────────────────────────────────────────
  # Shared helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp ensure_apps_started!(apps) do
    Enum.each(apps, fn app ->
      case Application.ensure_all_started(app) do
        {:ok, _started} ->
          :ok

        {:error, reason} ->
          raise Error, message: "Failed to start #{inspect(app)}: #{inspect(reason)}"
      end
    end)
  end

  defp ensure_lemon_core_started do
    case Application.ensure_all_started(:lemon_core) do
      {:ok, _started} -> :ok
      {:error, _reason} -> :error
    end
  end


  # ──────────────────────────────────────────────────────────────────────────
  # Usage
  # ──────────────────────────────────────────────────────────────────────────

  defp print_usage_error(message, usage) do
    IO.puts(:stderr, message)
    IO.puts(:stderr, "")
    usage.(:stderr)
    @exit_usage
  end

  defp print_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon <command> [options]

    Commands:
      setup [provider|runtime|gateway|doctor]   First-time setup and configuration
      model [--provider P] [--token T] [flags]  Onboard an AI provider
      gateway setup [transport] [flags]         Configure gateway adapters
      doctor [--verbose] [--json] [--bundle]    Run diagnostics / write support bundle
      config [validate|show]                    Validate or show configuration
      secrets <status|init|set|list|delete|check|import-env>
      channels [--project-dir PATH] [--json]    Channel launch readiness

    Run `lemon <command> --help` for command options.
    """)
  end

  defp print_command_usage("setup") do
    IO.puts("""
    Usage: lemon setup [provider|runtime|gateway|doctor] [options]

    Subcommands:
      provider [args]   Configure an AI provider (same flags as `lemon model`)
      runtime [args]    Configure runtime profile and port bindings
      gateway [args]    Configure gateway adapters
      doctor [args]     Validate config and report health

    Options:
      --non-interactive, -n   Skip prompts, use defaults / CLI flags
      --config-path PATH      Config file to read/write (full wizard only)
    """)
  end

  defp print_command_usage("model") do
    IO.puts("""
    Usage: lemon model [provider] [options]

    Onboards an AI provider: OAuth or API-key credentials are stored in the
    encrypted secrets store and referenced from config.toml. Without a
    provider, an interactive picker is shown.

    Options:
      --provider P            Provider id (or pass it positionally)
      --token T               Non-interactive API key
      --auth oauth|api_key    Authentication mode
      --secret-name NAME      Secret name to store the credential under
      --model M               Default model when used with --set-default
      --set-default           Set the provider/model as default
      --config-path PATH      Config file to update
    """)
  end

  defp print_command_usage("gateway") do
    IO.puts("""
    Usage: lemon gateway setup [transport] [options]

    Options:
      --transport NAME, -t    Gateway adapter (e.g. telegram, discord)
      --non-interactive, -n   Skip prompts
    """)
  end

  defp print_command_usage("doctor"), do: print_doctor_usage()

  defp print_command_usage("config"), do: print_config_usage()

  defp print_command_usage("secrets"), do: print_secrets_usage()

  defp print_command_usage("channels") do
    IO.puts("""
    Usage: lemon channels [options]

    Options:
      --project-dir PATH  Project root to scan (defaults to the cwd)
      --json              Emit the raw redacted readiness JSON
    """)
  end

  defp print_doctor_usage(device \\ :stdio) do
    IO.puts(device, """
    Usage: lemon doctor [options]

    Options:
      --verbose, -v       Show all checks including passing and skipped ones
      --json              Output results as a JSON document (CI-friendly)
      --project-dir PATH  Use a specific project directory for checks
      --bundle [PATH]     Write a redacted support bundle zip
      --bundle-path PATH  Write the support bundle to a specific path
    """)
  end
end
