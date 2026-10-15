defmodule LemonCli.Setup.Wizard do
  @moduledoc """
  Interactive setup wizard for `mix lemon.setup` and the packaged `lemon setup`
  command.

  Handles:
  - Subcommand dispatch (`run/3`) — the Mix task and the release CLI share it
  - Full setup wizard (`run_full/3`) — an idempotent state machine over the
    config, secrets, and provider steps
  - Runtime profile and port configuration (`run_runtime/3`)

  All modes support interactive (TUI/prompt) and non-interactive
  (flag-driven, CI-friendly) operation through the shared `io_callbacks` map.
  """

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.{Gateway, Provider, Scaffold, Verification}
  alias LemonCore.Config.{Automation, Modular, TomlPatch}
  alias LemonCore.Runtime.{Env, Profile}
  alias LemonCore.Secrets
  alias LemonCore.Secrets.MasterKey
  alias LemonCore.Update.ConfigMigrator

  @type io_callbacks :: %{
          required(:info) => (String.t() -> any()),
          required(:error) => (String.t() -> any()),
          required(:prompt) => (String.t() -> String.t() | charlist() | nil),
          required(:secret) => (String.t() -> String.t() | charlist() | nil),
          optional(:select) => (map() -> any()),
          optional(:interactive?) => (-> boolean())
        }

  @doc """
  Dispatches `setup` subcommands.

  Runtime-only (no Mix): `Mix.Tasks.Lemon.Setup` and `LemonCli.CLI` both
  delegate here. Options:

    * `:usage_command` - command shown in usage errors (default
      `"mix lemon.setup"`); the packaged CLI passes `"lemon setup"`.
  """
  @spec run([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run(args, io, opts \\ []) when is_list(args) and is_map(io) do
    usage_command = Keyword.get(opts, :usage_command, "mix lemon.setup")

    # parse_head stops at the first non-flag argument (the subcommand name),
    # leaving subcommand-specific flags untouched so subcommand parsers get them.
    {parsed, rest, invalid} =
      OptionParser.parse_head(args,
        strict: [
          non_interactive: :boolean,
          config_path: :string,
          provider: :string,
          skip_verify: :boolean,
          daily_brief: :string,
          set_default: :boolean,
          token: :string,
          auth: :string,
          codex_auth_path: :string,
          model: :string
        ],
        aliases: [n: :non_interactive]
      )

    case {invalid, rest} do
      {[_ | _], _} ->
        io.error.("Unknown or invalid setup options. Run `#{usage_command} --help`.")
        {:error, :invalid_arguments}

      {[], ["provider" | provider_args]} ->
        Provider.run(provider_args, io, setup_verify_opts(opts))

      {[], ["runtime" | runtime_args]} ->
        run_runtime(runtime_args, io, parsed)

      {[], ["gateway" | gateway_args]} ->
        Gateway.run(gateway_args, io)

      {[], ["doctor" | doctor_args]} ->
        case LemonCli.CLI.doctor(doctor_args) do
          0 -> :ok
          _ -> {:error, :doctor_failed}
        end

      {[], []} ->
        run_full([], io, Keyword.merge(opts, parsed))

      {[], [_subcommand | _]} ->
        io.error.("Unknown setup subcommand. Run `#{usage_command} --help` to list subcommands.")
        io.info.("")
        io.info.("Usage: #{usage_command} [provider|runtime|gateway|doctor] [options]")
        print_help_hint(io, usage_command)
        {:error, :unknown_subcommand}
    end
  end

  defp print_help_hint(io, "mix lemon.setup"),
    do: io.info.("Run `mix help lemon.setup` for full documentation.")

  defp print_help_hint(io, usage_command),
    do: io.info.("Run `#{usage_command} --help` for full documentation.")

  @doc """
  Runs the full setup wizard as an idempotent state machine.

  Each pass derives the completed/pending state of the config, secrets, and
  provider steps (`LemonCli.Setup.Verification.setup_state/1`), performs only
  the pending work, and re-derives the state for the final summary:

  1. Greet and show the current step status.
  2. Bootstrap the global config scaffold when none exists yet (never
     replaces an existing file).
  3. Initialize the secrets master key when absent — automatically, never
     by replacing an existing key.
  4. Onboard an AI provider unless the configured one is already usable.
     An explicit `:provider` forces reconfiguration.
  5. Verify the resulting provider/model/credential (offline checks always;
     live check unless `:skip_verify`).
  6. Offer an opt-in daily brief (default off; `--daily-brief HH:MM` in
     non-interactive mode).
  7. Offer to configure the runtime profile (optional).
  8. Print a summary that only claims completion after a passing live check.

  ## Options

    * `:non_interactive` - skip interactive prompts (default: false)
    * `:config_path` - override config path
    * `:provider` - force provider onboarding even when one is usable
    * `:skip_verify` - skip the post-onboarding live provider check
    * `:verifier` - injectable live-check function (testing; no network)
    * `:daily_brief` - `HH:MM` server-local time for the opt-in daily brief
  """
  @spec run_full([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run_full(_args, io, opts \\ []) do
    non_interactive? = Keyword.get(opts, :non_interactive, false)
    config_path = Keyword.get(opts, :config_path) || Modular.global_path()
    unless non_interactive?, do: Runner.ensure_interactive!(io)
    Runner.ensure_required_apps!()

    print_banner(io)
    print_status(io, Verification.setup_state(config_path: config_path))

    result =
      with :ok <- ensure_config(config_path, io),
           :ok <- ensure_secrets(io) do
        ensure_provider(config_path, io, non_interactive?, opts)
      end

    if result == :ok or match?({:ok, _}, result) do
      step_offer_daily_brief(config_path, io, non_interactive?, opts)
      step_offer_runtime(io, non_interactive?)
    end

    state = Verification.setup_state(config_path: config_path)

    result =
      if (result == :ok or match?({:ok, _}, result)) and
           not LemonCore.Setup.Readiness.ready?(state),
         do: {:error, :setup_incomplete},
         else: result

    print_summary(io, state, result)

    case result do
      {:ok, _verification} -> :ok
      other -> other
    end
  end

  @doc """
  Runs the runtime configuration wizard.

  Lets the user choose a runtime profile (`runtime_min` or `runtime_full`)
  and optionally set custom port values. Prints the env-var snippet to apply
  them, rather than writing to config.toml (ports are best set in the shell
  or a .env file).

  ## Options

    * `:non_interactive` - skip interactive prompts, print defaults (default: false)
  """
  @spec run_runtime([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run_runtime(args, io, opts \\ []) do
    {cli_opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          profile: :string,
          control_port: :integer,
          web_port: :integer,
          sim_port: :integer,
          non_interactive: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    non_interactive? = cli_opts[:non_interactive] || Keyword.get(opts, :non_interactive, false)

    if rest != [] or invalid != [] do
      io.error.(
        "Invalid runtime options. Use ports from 1 to 65535; run `lemon setup --help` for options."
      )

      {:error, :invalid_arguments}
    else
      unless non_interactive?, do: Runner.ensure_interactive!(io)
      io.info.("")
      io.info.("Runtime Configuration")
      io.info.("─────────────────────")

      with {:ok, profile_name} <- resolve_profile(cli_opts, io, non_interactive?),
           {:ok, ports} <- resolve_ports(cli_opts, Env.resolve(), io, non_interactive?) do
        print_runtime_summary(profile_name, ports, io)
        :ok
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Full wizard steps
  # ──────────────────────────────────────────────────────────────────────────

  defp print_banner(io) do
    io.info.("")
    io.info.("Welcome to Lemon setup!")
    io.info.("This wizard will walk you through first-time configuration.")
    io.info.("")
  end

  defp print_status(io, state) do
    io.info.("Setup status:")

    io.info.("  #{step_marker(state.config.complete)} config    #{state.config.path}")

    io.info.(
      "  #{step_marker(state.secrets.complete)} secrets   #{secrets_detail(state.secrets)}"
    )

    io.info.(
      "  #{step_marker(state.provider.complete)} provider  #{provider_detail(state.provider)}"
    )

    io.info.("")
  end

  defp step_marker(true), do: String.pad_trailing("[done]", 10)
  defp step_marker(false), do: String.pad_trailing("[pending]", 10)

  defp secrets_detail(%{complete: true, source: source}) when not is_nil(source),
    do: "master key via #{source}"

  defp secrets_detail(%{complete: true}),
    do: "master key configured"

  defp secrets_detail(%{complete: false}),
    do: "master key not initialized"

  defp provider_detail(%{complete: true, provider: provider, model: model}),
    do: "#{provider} / #{model}"

  defp provider_detail(%{reason: :model_provider_mismatch, provider: provider, model: model}),
    do: "#{provider} / #{model} (model does not match provider)"

  defp provider_detail(%{provider: nil, model: nil}),
    do: "no default provider/model configured"

  defp provider_detail(%{provider: nil}),
    do: "no default provider configured"

  defp provider_detail(%{provider: provider, model: nil}),
    do: "#{provider} has no default model"

  defp provider_detail(%{provider: provider}),
    do: "#{provider} credentials not usable"

  defp ensure_config(config_path, io) do
    expanded = Path.expand(config_path)

    if File.exists?(expanded) do
      io.info.("Config: #{expanded} (already exists)")
      migrate_deprecated_config(expanded, io)
      :ok
    else
      io.info.("Creating minimal config at #{expanded} ...")

      case Scaffold.write_unless_exists(expanded, Scaffold.generate()) do
        {:ok, path} ->
          io.info.("Created: #{path}")
          :ok

        {:exists, _path} ->
          :ok

        {:error, reason} ->
          io.error.(
            "Could not create the config scaffold. Check permissions, then run `lemon setup`."
          )

          {:error, {:scaffold_failed, reason}}
      end
    end
  end

  # A config written by an older Lemon (for example an `[agent]` table from a
  # previous terminal client) is rewritten to the current schema, keeping a
  # backup. Settings that cannot be moved automatically are reported, not fatal.
  defp migrate_deprecated_config(path, io) do
    with {:needs_migration, _issues} <- ConfigMigrator.check(path),
         {:ok, %{backup: backup, changes: changes}} <- ConfigMigrator.migrate!(path) do
      io.info.("Migrated deprecated config settings:")
      Enum.each(changes, &io.info.("  #{&1}"))
      io.info.("  Backup: #{backup}")
    else
      :ok ->
        :ok

      {:error, {:manual_steps_required, errors}} ->
        io.error.("Config uses settings that need a manual edit:")
        Enum.each(errors, &io.error.("  • #{&1}"))

      {:error, _reason} ->
        io.error.(
          "Could not migrate deprecated config settings. Run `lemon config migrate` for guidance."
        )
    end
  end

  # Drive the master-key API directly in both source and packaged setup.
  # Initialization is automatic on every path because
  # stopping to ask the user to run a second command before setup can proceed
  # is exactly the dead end first-run onboarding must avoid.
  defp ensure_secrets(io) do
    if Secrets.status().configured do
      :ok
    else
      io.info.("")
      io.info.("Secrets master key not found — initializing one now.")

      case MasterKey.init() do
        {:ok, %{source: :file, key_file: path}} ->
          io.info.("Secrets master key written to #{path} (0600)")
          :ok

        {:ok, %{source: source}} ->
          io.info.("Secrets master key initialized in #{source}")
          :ok

        {:error, :keychain_unavailable} ->
          io.error.(
            "The system keychain and key file are unavailable. Run `lemon secrets init --target file`, then run `lemon setup`."
          )

          {:error, :secrets_init_failed}

        {:error, {:key_file_exists, _path}} ->
          io.error.(
            "An existing secrets master key could not be loaded and will not be replaced. Restore access to the original key, then run `lemon secrets status`."
          )

          {:error, :secrets_init_failed}

        {:error, reason} ->
          io.error.(
            "Could not initialize the secrets master key. Run `lemon secrets init` for guidance."
          )

          {:error, {:secrets_init_failed, reason}}
      end
    end
  end

  defp ensure_provider(config_path, io, non_interactive?, opts) do
    provider_state = Verification.setup_state(config_path: config_path).provider
    forced = Keyword.get(opts, :provider)

    cond do
      provider_state.complete and is_nil(forced) ->
        io.info.(
          "Provider already configured: #{provider_state.provider} / #{provider_state.model}"
        )

        io.info.("Skipping onboarding. Run `lemon setup provider` to change it.")
        Provider.verify_config(config_path, io, setup_verify_opts(opts))

      non_interactive? and is_nil(forced) ->
        io.info.(
          "Skipping provider setup (non-interactive). Run `lemon setup provider` to onboard a provider."
        )

        :ok

      true ->
        answer =
          if non_interactive? or forced do
            true
          else
            prompt_yes_no?("Onboard an AI provider now?", true, io)
          end

        if answer do
          provider_args =
            ["--config-path", config_path, "--set-default"] ++
              if(forced, do: ["--provider", forced], else: []) ++
              if(non_interactive?, do: ["--non-interactive"], else: []) ++
              Enum.flat_map([:token, :auth, :model, :codex_auth_path], fn key ->
                flag = key |> Atom.to_string() |> String.replace("_", "-")
                if value = opts[key], do: ["--#{flag}", value], else: []
              end) ++
              if(Keyword.get(opts, :skip_verify, false), do: ["--skip-verify"], else: [])

          Provider.configure(provider_args, io, setup_verify_opts(opts))
        else
          io.info.("Skipped. Run `lemon setup provider` when ready.")
          :ok
        end
    end
  end

  # Setup-journey callers opt into the live credential check; direct
  # `lemon model` onboarding (LemonCli.CLI) stays offline-strong only.
  defp setup_verify_opts(opts) do
    opts
    |> Keyword.take([:verifier, :skip_verify, :config, :verification_model, :cwd])
    |> Keyword.put(:live_verify, true)
  end

  # The daily brief is one heartbeat cron job that `LemonAutomation.Heartbeat`
  # reconciles from `[automation] daily_brief` when the runtime boots, so setup
  # only has to record the choice - the runtime does not need to be running.
  defp step_offer_daily_brief(config_path, io, non_interactive?, opts) do
    path = Path.expand(config_path)
    content = read_config_content(path)

    case existing_daily_brief(content) do
      time when is_binary(time) ->
        io.info.("")
        io.info.("Daily brief: scheduled at #{time} (edit [automation] daily_brief to change).")

      nil ->
        case requested_daily_brief(io, non_interactive?, Keyword.get(opts, :daily_brief)) do
          {:ok, time} -> write_daily_brief(path, content, time, io)
          :skip -> :ok
        end
    end
  end

  defp requested_daily_brief(io, _non_interactive?, flag) when is_binary(flag) do
    case normalize_brief_time(flag) do
      {:ok, time} ->
        {:ok, time}

      :error ->
        io.error.(
          "Ignoring the invalid daily brief time. Run `lemon setup --daily-brief HH:MM` with a 24-hour time."
        )

        :skip
    end
  end

  defp requested_daily_brief(_io, true, nil), do: :skip

  defp requested_daily_brief(io, false, nil) do
    io.info.("")

    if prompt_yes_no?(
         "Get a short daily brief on your phone each morning? " <>
           "(Needs a paired Telegram chat: `lemon gateway setup telegram`.)",
         false,
         io
       ) do
      prompt_brief_time(io)
    else
      io.info.("Skipped. Add `daily_brief = \"08:00\"` under [automation] to enable it later.")
      :skip
    end
  end

  defp prompt_brief_time(io) do
    case normalize_input(io.prompt.("Daily brief time (HH:MM, this machine's time) [08:00]: ")) do
      "" ->
        {:ok, "08:00"}

      raw ->
        case normalize_brief_time(raw) do
          {:ok, time} ->
            {:ok, time}

          :error ->
            io.error.("Expected a 24-hour time such as 07:30.")
            prompt_brief_time(io)
        end
    end
  end

  defp normalize_brief_time(raw) do
    case Automation.parse_time(raw) do
      {:ok, {hour, minute}} ->
        {:ok, "#{pad2(hour)}:#{pad2(minute)}"}

      :error ->
        :error
    end
  end

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp write_daily_brief(path, content, time, io) do
    patched = TomlPatch.upsert_string(content, "automation", "daily_brief", time)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, patched) do
      io.info.("Daily brief scheduled for #{time} every day (written to #{path}).")
      io.info.("It starts when Lemon (re)starts and is sent to your paired Telegram chat;")
      io.info.("run `lemon gateway setup telegram` if you have not paired one yet.")
      :ok
    else
      {:error, _reason} ->
        io.error.(
          "Could not save the daily brief. Check config permissions, then run `lemon setup`."
        )

        :ok
    end
  end

  defp read_config_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> ""
    end
  end

  defp existing_daily_brief(content) do
    with {:ok, decoded} <- Toml.decode(content),
         %{"automation" => %{"daily_brief" => time}} when is_binary(time) <- decoded,
         {:ok, _} <- Automation.parse_time(time) do
      String.trim(time)
    else
      _ -> nil
    end
  end

  defp step_offer_runtime(io, non_interactive?) do
    io.info.("")

    if non_interactive? do
      io.info.(
        "Skipping runtime configuration (non-interactive). Run `lemon setup runtime` to configure."
      )
    else
      answer = prompt_yes_no?("Configure runtime profile now?", false, io)

      if answer do
        run_runtime([], io, non_interactive: false)
      else
        io.info.("Skipped. Run `lemon setup runtime` when ready.")
      end
    end
  end

  defp print_summary(io, state, result) do
    io.info.("")

    case {Verification.pending_steps(state), result} do
      {[], {:ok, %{live: :ok}}} ->
        io.info.("Setup complete. Next steps:")
        io.info.("  lemon                        — start coding in this directory")
        io.info.("  lemon config validate        — verify configuration")
        io.info.("  lemon setup provider         — onboard another AI provider")
        io.info.("  lemon setup runtime          — change runtime profile / ports")
        io.info.("  lemon doctor                 — run diagnostics")
        io.info.("")

      {[], result} when result == :ok or elem(result, 0) == :ok ->
        io.info.("Configuration saved, but the provider was not live-verified.")

        io.info.(
          "Run `lemon setup` without --skip-verify to check it, or `lemon doctor` for diagnostics."
        )

        io.info.("")

      {[], _result} ->
        # Verification (or another step) failed even though every step is
        # configured; never claim completion after a failure.
        io.info.("Setup did not complete. Resolve the errors above, then run `lemon setup`.")
        io.info.("")

      {pending, _result} ->
        io.info.("Setup unfinished — pending steps:")
        print_pending(pending, state, io)

        if result not in [:ok, {:error, :setup_incomplete}] and not match?({:ok, _}, result) do
          io.info.("")
          io.info.("Setup did not complete. Resolve the errors above, then run `lemon setup`.")
        end

        io.info.("")
    end
  end

  defp print_pending(pending, state, io) do
    Enum.each(pending, fn
      :config -> io.info.("  config:   re-run `lemon setup` or create #{state.config.path}")
      :secrets -> io.info.("  secrets:  re-run `lemon setup` (or run `lemon secrets init`)")
      :provider -> io.info.("  provider: run `lemon setup provider`")
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Runtime subcommand helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp resolve_profile(cli_opts, io, non_interactive?) do
    names = Profile.names()
    default = :runtime_full

    case cli_opts[:profile] do
      nil when non_interactive? ->
        {:ok, default}

      nil ->
        io.info.("")
        io.info.("Available runtime profiles:")

        names
        |> Enum.with_index(1)
        |> Enum.each(fn {name, index} ->
          io.info.("  #{index}. #{name} — #{Profile.get(name).description}")
        end)

        prompt_profile(names, default, io)

      value ->
        case Enum.find(names, &(Atom.to_string(&1) == value)) do
          nil ->
            io.error.(
              "Invalid runtime profile. Use --profile #{Enum.join(names, " or ")} with `lemon setup runtime`."
            )

            {:error, :invalid_arguments}

          profile ->
            {:ok, profile}
        end
    end
  end

  defp prompt_profile(names, default, io) do
    choice = normalize_input(io.prompt.("Choose profile [default: #{default}]: "))

    profile =
      case Integer.parse(choice) do
        {index, ""} when index > 0 -> Enum.at(names, index - 1)
        _ -> Enum.find(names, &(Atom.to_string(&1) == choice))
      end

    cond do
      choice == "" ->
        {:ok, default}

      profile ->
        {:ok, profile}

      true ->
        io.error.("Invalid profile. Enter 1–#{length(names)} or #{Enum.join(names, ", ")}.")
        prompt_profile(names, default, io)
    end
  end

  defp resolve_ports(cli_opts, env, io, non_interactive?) do
    current = %{control: env.control_port, web: env.web_port, sim: env.sim_port}
    flags = [control_port: :control, web_port: :web, sim_port: :sim]

    invalid =
      Enum.find(flags, fn {flag, _key} ->
        Keyword.has_key?(cli_opts, flag) and not valid_port?(cli_opts[flag])
      end)

    cond do
      invalid ->
        {flag, _key} = invalid
        flag = flag |> Atom.to_string() |> String.replace("_", "-")
        io.error.("Invalid --#{flag}. Use a port from 1 to 65535 with `lemon setup runtime`.")
        {:error, :invalid_arguments}

      non_interactive? or Enum.any?(flags, fn {flag, _} -> Keyword.has_key?(cli_opts, flag) end) ->
        ports =
          Enum.reduce(flags, current, fn {flag, key}, ports ->
            Map.put(ports, key, Keyword.get(cli_opts, flag, ports[key]))
          end)

        {:ok, ports}

      true ->
        io.info.("")
        io.info.("Press Enter to keep each port, or enter a port from 1 to 65535.")

        {:ok,
         %{
           control: prompt_port("control-plane", current.control, io),
           web: prompt_port("web", current.web, io),
           sim: prompt_port("sim-ui", current.sim, io)
         }}
    end
  end

  defp prompt_port(label, default, io) do
    case normalize_input(io.prompt.("#{label} port [#{default}]: ")) do
      "" ->
        default

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 and port <= 65_535 ->
            port

          _ ->
            io.error.("Invalid port. Enter a number from 1 to 65535.")
            prompt_port(label, default, io)
        end
    end
  end

  defp valid_port?(port), do: is_integer(port) and port > 0 and port <= 65_535

  defp print_runtime_summary(profile_name, ports, io) do
    profile = Profile.get(profile_name)

    io.info.("")
    io.info.("Runtime profile: #{profile_name}")
    io.info.("  Apps: #{Enum.join(profile.apps, ", ")}")
    io.info.("")
    io.info.("Ports:")
    io.info.("  control-plane : #{ports.control}")
    io.info.("  web           : #{ports.web}")
    io.info.("  sim-ui        : #{ports.sim}")
    io.info.("")
    io.info.("To persist these settings, add to your shell profile or .env file:")
    io.info.("  export LEMON_CONTROL_PLANE_PORT=#{ports.control}")
    io.info.("  export LEMON_WEB_PORT=#{ports.web}")
    io.info.("  export LEMON_SIM_UI_PORT=#{ports.sim}")
    io.info.("")
    io.info.("To launch this profile:")
    io.info.("  MIX_ENV=prod mix release #{release_name(profile_name)}")
    io.info.("  # or in dev:")
    io.info.("  ./bin/lemon start")
  end

  defp release_name(:runtime_min), do: "lemon_runtime_min"
  defp release_name(:runtime_full), do: "lemon_runtime_full"

  # ──────────────────────────────────────────────────────────────────────────
  # IO helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp prompt_yes_no?(message, default, io) do
    suffix = if default, do: " [Y/n]: ", else: " [y/N]: "

    answer =
      io.prompt.(message <> suffix)
      |> normalize_input()
      |> String.downcase()

    case answer do
      "" -> default
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> prompt_yes_no?(message, default, io)
    end
  end

  defp normalize_input(nil), do: Runner.no_terminal!()
  defp normalize_input(:eof), do: Runner.no_terminal!()
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end
