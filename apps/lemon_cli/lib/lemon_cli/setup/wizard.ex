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
  alias LemonCore.Config.Modular
  alias LemonCore.Runtime.{Env, Profile}
  alias LemonCore.Secrets
  alias LemonCore.Secrets.MasterKey

  @type io_callbacks :: %{
          required(:info) => (String.t() -> any()),
          required(:error) => (String.t() -> any()),
          required(:prompt) => (String.t() -> String.t() | charlist() | nil),
          required(:secret) => (String.t() -> String.t() | charlist() | nil),
          optional(:select) => (map() -> any())
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
    {parsed, rest, _invalid} =
      OptionParser.parse_head(args,
        switches: [
          non_interactive: :boolean,
          config_path: :string,
          provider: :string,
          skip_verify: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    case rest do
      ["provider" | provider_args] ->
        Provider.run(provider_args, io, setup_verify_opts(opts))


      ["runtime" | runtime_args] ->
        run_runtime(runtime_args, io, parsed)

      ["gateway" | gateway_args] ->
        Gateway.run(gateway_args, io)

      ["doctor" | doctor_args] ->
        case LemonCli.CLI.doctor(doctor_args) do
          0 -> :ok
          _ -> {:error, :doctor_failed}
        end

      [] ->
        Runner.ensure_required_apps!()
        run_full([], io, Keyword.merge(opts, parsed))

      [subcommand | _] ->
        io.error.("Unknown subcommand: #{inspect(subcommand)}")
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
  6. Offer to configure the runtime profile (optional).
  7. Print a summary that only claims completion when nothing is pending.

  ## Options

    * `:non_interactive` - skip interactive prompts (default: false)
    * `:config_path` - override config path
    * `:provider` - force provider onboarding even when one is usable
    * `:skip_verify` - skip the post-onboarding live provider check
    * `:verifier` - injectable live-check function (testing; no network)
  """
  @spec run_full([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run_full(_args, io, opts \\ []) do
    non_interactive? = Keyword.get(opts, :non_interactive, false)
    config_path = Keyword.get(opts, :config_path) || Modular.global_path()

    print_banner(io)
    print_status(io, Verification.setup_state(config_path: config_path))

    result =
      with :ok <- ensure_config(config_path, io),
           :ok <- ensure_secrets(io) do
        ensure_provider(config_path, io, non_interactive?, opts)
      end

    if result == :ok do
      step_offer_runtime(io, non_interactive?)
    end

    print_summary(io, Verification.setup_state(config_path: config_path), result)

    result
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
  @spec run_runtime([String.t()], io_callbacks(), keyword()) :: :ok
  def run_runtime(args, io, opts \\ []) do
    {cli_opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          profile: :string,
          control_port: :integer,
          web_port: :integer,
          sim_port: :integer,
          non_interactive: :boolean
        ],
        aliases: [n: :non_interactive]
      )

    non_interactive? = cli_opts[:non_interactive] || Keyword.get(opts, :non_interactive, false)

    io.info.("")
    io.info.("Runtime Configuration")
    io.info.("─────────────────────")

    profile_name = resolve_profile(cli_opts, io, non_interactive?)
    env = Env.resolve()
    ports = resolve_ports(cli_opts, env, io, non_interactive?)

    print_runtime_summary(profile_name, ports, io)

    :ok
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
    io.info.("  #{step_marker(state.secrets.complete)} secrets   #{secrets_detail(state.secrets)}")
    io.info.("  #{step_marker(state.provider.complete)} provider  #{provider_detail(state.provider)}")
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
          io.error.("Could not create config scaffold: #{inspect(reason)}")
          {:error, {:scaffold_failed, reason}}
      end
    end
  end

  # The Mix task for `lemon secrets init` is not available from packaged
  # releases, so drive the master-key API directly. Initialization is
  # automatic on every path — interactive and non-interactive alike — because
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
          io.error.("Could not initialize a secrets master key: the system keychain is")
          io.error.("unavailable and no key file location could be determined.")
          io.error.("Set #{MasterKey.env_var()} or configure")
          io.error.("`config :lemon_core, LemonCore.Secrets, key_file: ...`, then re-run setup.")
          {:error, :secrets_init_failed}

        {:error, {:key_file_exists, path}} ->
          io.error.("A secrets master key already exists at #{path}; it will not be replaced —")
          io.error.("every secret encrypted under the old key becomes unreadable when a key is")
          io.error.("replaced. Make the existing key resolvable (set #{MasterKey.env_var()} or")
          io.error.("restore #{path}), then re-run setup.")
          {:error, :secrets_init_failed}

        {:error, reason} ->
          io.error.("Failed to initialize secrets master key: #{inspect(reason)}")
          {:error, {:secrets_init_failed, reason}}
      end
    end
  end

  defp ensure_provider(config_path, io, non_interactive?, opts) do
    provider_state = Verification.setup_state(config_path: config_path).provider
    forced = Keyword.get(opts, :provider)

    cond do
      provider_state.complete and is_nil(forced) ->
        io.info.("Provider already configured: #{provider_state.provider} / #{provider_state.model}")
        io.info.("Skipping onboarding. Run `lemon setup provider` to change it.")
        :ok

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
            ["--config-path", config_path] ++
              if(forced, do: ["--provider", forced], else: [])

          Provider.run(provider_args, io, setup_verify_opts(opts))
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
    |> Keyword.take([:verifier, :skip_verify])
    |> Keyword.put(:live_verify, true)
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

    case Verification.pending_steps(state) do
      [] when result == :ok ->
        io.info.("Setup complete. Next steps:")
        io.info.("  lemon config validate        — verify configuration")
        io.info.("  lemon setup provider         — onboard another AI provider")
        io.info.("  lemon setup runtime          — change runtime profile / ports")
        io.info.("  lemon setup doctor           — run diagnostics")
        io.info.("")

      [] ->
        # Verification (or another step) failed even though every step is
        # configured; never claim completion after a failure.
        io.info.("Setup did not complete — resolve the errors above, then re-run.")
        io.info.("")

      pending ->
        io.info.("Setup unfinished — pending steps:")
        print_pending(pending, state, io)

        if result != :ok do
          io.info.("")
          io.info.("Setup did not complete — resolve the errors above, then re-run.")
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
    profile_names = Profile.names()
    default = :runtime_full

    case cli_opts[:profile] do
      nil when non_interactive? ->
        default

      nil ->
        io.info.("")
        io.info.("Available runtime profiles:")

        profile_names
        |> Enum.with_index(1)
        |> Enum.each(fn {name, idx} ->
          profile = Profile.get(name)
          marker = if name == default, do: " (default)", else: ""
          io.info.("  #{idx}. #{name}#{marker} — #{profile.description}")
        end)

        choice = normalize_input(io.prompt.("Choose profile [default: #{default}]: "))

        cond do
          choice == "" ->
            default

          String.match?(choice, ~r/^\d+$/) ->
            idx = String.to_integer(choice)
            Enum.at(profile_names, idx - 1) || default

          choice in Enum.map(profile_names, &Atom.to_string/1) ->
            String.to_atom(choice)

          true ->
            io.error.("Unknown profile #{inspect(choice)}, using #{default}.")
            default
        end

      profile_str ->
        # Validate as string first to avoid creating atoms for arbitrary user input.
        # Only convert to atom after confirming the name is a known profile.
        valid_strings = Enum.map(profile_names, &Atom.to_string/1)

        if profile_str in valid_strings do
          String.to_existing_atom(profile_str)
        else
          io.error.("Unknown profile #{inspect(profile_str)}, using #{default}.")
          default
        end
    end
  end

  defp resolve_ports(cli_opts, env, io, non_interactive?) do
    current = %{
      control: env.control_port,
      web: env.web_port,
      sim: env.sim_port
    }

    if non_interactive? or (cli_opts[:control_port] || cli_opts[:web_port] || cli_opts[:sim_port]) do
      %{
        control: cli_opts[:control_port] || current.control,
        web: cli_opts[:web_port] || current.web,
        sim: cli_opts[:sim_port] || current.sim
      }
    else
      io.info.("")
      io.info.("Current ports:")
      io.info.("  control-plane : #{current.control}  (LEMON_CONTROL_PLANE_PORT)")
      io.info.("  web           : #{current.web}  (LEMON_WEB_PORT)")
      io.info.("  sim-ui        : #{current.sim}  (LEMON_SIM_UI_PORT)")
      io.info.("")
      io.info.("Press Enter to keep each value, or type a new port number.")

      control =
        parse_port(io.prompt.("control-plane port [#{current.control}]: "), current.control)

      web = parse_port(io.prompt.("web port [#{current.web}]: "), current.web)
      sim = parse_port(io.prompt.("sim-ui port [#{current.sim}]: "), current.sim)

      %{control: control, web: web, sim: sim}
    end
  end

  defp parse_port(raw, default) do
    case normalize_input(raw) do
      "" ->
        default

      str ->
        case Integer.parse(str) do
          {port, ""} when port > 0 and port <= 65_535 -> port
          _ -> default
        end
    end
  end

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
    io.info.("  bin/lemon")
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

  defp normalize_input(nil), do: ""
  defp normalize_input(:eof), do: ""
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end
