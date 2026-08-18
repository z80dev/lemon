defmodule LemonCli.Setup.Wizard do
  @moduledoc """
  Interactive setup wizard for `mix lemon.setup` and the packaged `lemon setup`
  command.

  Handles:
  - Subcommand dispatch (`run/3`) — the Mix task and the release CLI share it
  - Full first-time wizard (`run_full/3`)
  - Runtime profile and port configuration (`run_runtime/3`)

  All modes support interactive (TUI/prompt) and non-interactive
  (flag-driven, CI-friendly) operation through the shared `io_callbacks` map.
  """

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.{Gateway, Provider, Scaffold}
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
        switches: [non_interactive: :boolean, config_path: :string],
        aliases: [n: :non_interactive]
      )

    case rest do
      ["provider" | provider_args] ->
        Provider.run(provider_args, io)

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
        run_full([], io, parsed)

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
  Runs the full interactive first-time setup wizard.

  Steps:
  1. Greet and explain what will happen.
  2. Bootstrap the global config scaffold when none exists yet.
  3. Check secrets initialization, guide through init if needed.
  4. Offer to onboard an AI provider.
  5. Offer to configure runtime profile.
  6. Print next steps.

  ## Options

    * `:non_interactive` - skip interactive prompts (default: false)
    * `:config_path` - override config path
  """
  @spec run_full([String.t()], io_callbacks(), keyword()) :: :ok
  def run_full(_args, io, opts \\ []) do
    non_interactive? = Keyword.get(opts, :non_interactive, false)

    print_banner(io)

    config_path = Keyword.get(opts, :config_path) || Modular.global_path()

    step_bootstrap_config(config_path, io, non_interactive?)
    step_check_secrets(io, non_interactive?)
    step_offer_provider(io, non_interactive?)
    step_offer_runtime(io, non_interactive?)
    print_next_steps(io)

    :ok
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

  defp step_bootstrap_config(config_path, io, _non_interactive?) do
    unless Scaffold.global_config_exists?() do
      io.info.("Creating minimal config at #{config_path} ...")

      case Scaffold.write_unless_exists(config_path, Scaffold.generate()) do
        {:ok, path} ->
          io.info.("Created: #{path}")

        {:exists, _path} ->
          :ok

        {:error, reason} ->
          io.error.("Could not create config scaffold: #{inspect(reason)}")
      end
    end
  end

  defp step_check_secrets(io, non_interactive?) do
    status = Secrets.status()

    unless status.configured do
      io.info.("")
      io.info.("Encrypted secrets are not yet initialized.")

      if non_interactive? do
        io.info.("Run `lemon secrets init` to set up secrets, then re-run setup.")
      else
        answer = prompt_yes_no?("Initialize secrets now?", true, io)

        if answer do
          init_secrets_now(io)
        else
          io.info.("Skipped. Run `lemon secrets init` before onboarding a provider.")
        end
      end
    end
  end

  # Runtime equivalent of `lemon secrets init`: the Mix task is not available
  # from packaged releases, so drive the master-key API directly.
  defp init_secrets_now(io) do
    case MasterKey.init() do
      {:ok, %{source: :file, key_file: path}} ->
        io.info.("Secrets master key written to #{path} (0600)")

      {:ok, %{source: source}} ->
        io.info.("Secrets master key initialized in #{source}")

      {:error, :keychain_unavailable} ->
        Runner.fail!(
          "Keychain is unavailable on this system and no key file location could be " <>
            "determined. Set #{MasterKey.env_var()}, or configure " <>
            "`config :lemon_core, LemonCore.Secrets, key_file: ...`."
        )

      {:error, {:key_file_exists, path}} ->
        Runner.fail!(
          "A secrets master key already exists at #{path}. Every secret encrypted " <>
            "under the old key becomes unreadable when it is replaced."
        )

      {:error, reason} ->
        Runner.fail!("Failed to initialize secrets master key: #{inspect(reason)}")
    end
  end

  defp step_offer_provider(io, non_interactive?) do
    io.info.("")

    if non_interactive? do
      io.info.(
        "Skipping provider setup (non-interactive). Run `lemon setup provider` to onboard a provider."
      )
    else
      answer = prompt_yes_no?("Onboard an AI provider now?", true, io)

      if answer do
        Provider.run([], io)
      else
        io.info.("Skipped. Run `lemon setup provider` when ready.")
      end
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

  defp print_next_steps(io) do
    io.info.("")
    io.info.("Setup complete. Next steps:")
    io.info.("  lemon config validate        — verify configuration")
    io.info.("  lemon setup provider         — onboard another AI provider")
    io.info.("  lemon setup runtime          — change runtime profile / ports")
    io.info.("  lemon setup doctor           — run diagnostics")
    io.info.("")
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
