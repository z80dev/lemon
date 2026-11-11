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

  alias LemonCli.Onboarding.{PromptUI, Providers, Runner}
  alias LemonCli.Setup.{Gateway, ModelReadiness, Ports, Provider, Scaffold, Verification}
  alias LemonCore.Config.Modular
  alias LemonCore.Runtime.{Env, Health, Profile}
  alias LemonCore.Secrets
  alias LemonCore.Secrets.MasterKey
  alias LemonCore.Setup.Readiness
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
    MasterKey.scoped(fn ->
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
            set_default: :boolean,
            token: :string,
            auth: :string,
            codex_auth_path: :string,
            model: :string,
            model_optional: :boolean
          ],
          aliases: [n: :non_interactive]
        )

      case {invalid, rest} do
        {[_ | _], _} ->
          io.error.("Unknown or invalid setup options. Run `#{usage_command} --help`.")
          {:error, :invalid_arguments}

        {[], ["provider" | provider_args]} ->
          Provider.run(provider_args, io, setup_verify_opts(opts))

        {[], ["model" | model_args]} ->
          run_model(model_args, io, Keyword.merge(opts, parsed))

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
          io.error.(
            "Unknown setup subcommand. Run `#{usage_command} --help` to list subcommands."
          )

          io.info.("")
          io.info.("Usage: #{usage_command} [provider|model|runtime|gateway|doctor] [options]")
          print_help_hint(io, usage_command)
          {:error, :unknown_subcommand}
      end
    end)
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
  6. Check the ports the runtime will bind. A port held by another program is
     replaced by the next free one after a `[Y/n]` confirmation (automatically
     in non-interactive mode) and saved to `~/.lemon/ports.env`. Ports owned
     by an already running Lemon are left alone.
  7. Print completion after a passing live check or a saved provider without a live check.

  The runtime profile is not part of first-run setup: the installer chooses it.

  ## Options

    * `:non_interactive` - skip interactive prompts (default: false)
    * `:config_path` - override config path
    * `:provider` - force provider onboarding even when one is usable
    * `:skip_verify` - skip the post-onboarding live provider check
    * `:verifier` - injectable live-check function (testing; no network)
    * `:launcher` - injectable zero-arity TUI launcher (testing)
    * `:port_free?`, `:lemon_running?`, `:ports_path` - injectable port probes
      and port file (testing)
    * `:launch` - offer to open Lemon (default: true; false for the launcher's setup gate)
  """
  @spec run_full([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run_full(_args, io, opts \\ []) do
    non_interactive? = Keyword.get(opts, :non_interactive, false)
    config_path = Keyword.get(opts, :config_path) || Modular.global_path()
    unless non_interactive?, do: Runner.ensure_interactive!(io)
    io.info.("Starting Lemon setup…")
    Runner.ensure_required_apps!()
    # Derived under the progress line above: probing config and secrets can
    # block on a slow keychain, and that wait must never look like a freeze
    # behind an already-painted banner.
    initial_state = Verification.setup_state(config_path: config_path)

    print_banner(io)
    print_status(io, initial_state)

    result =
      with :ok <- ensure_config(config_path, io),
           :ok <- ensure_secrets(io) do
        ensure_provider(config_path, io, non_interactive?, opts)
      end

    ensure_ports(io, non_interactive?, opts)

    state = Verification.setup_state(config_path: config_path)
    model_optional? = Keyword.get(opts, :model_optional, false)

    incomplete? =
      if model_optional?,
        do: Verification.pending_steps(state) -- [:provider] != [],
        else: not Readiness.ready?(state)

    result =
      if (result == :ok or match?({:ok, _}, result)) and incomplete?,
        do: {:error, :setup_incomplete},
        else: result

    print_summary(io, state, result, opts)
    step_offer_launch(io, state, result, non_interactive?, opts)

    case result do
      {:ok, _verification} -> :ok
      other -> other
    end
  end

  @doc """
  Runs the runtime configuration wizard.

  Lets the user choose a runtime profile (`runtime_min` or `runtime_full`)
  and optionally set custom port values, then saves the ports to
  `~/.lemon/ports.env` (see `LemonCli.Setup.Ports`), which the launchers load.

  ## Options

    * `:non_interactive` - skip interactive prompts, keep current ports (default: false)
    * `:ports_path` - override the persisted port file (testing)
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
        print_runtime_summary(profile_name, ports, io, opts)
        :ok
      end
    end
  end

  @doc """
  Runs the Connect-a-model step alone (`lemon setup model`).

  `--json` prints one `LemonCli.Setup.ModelReadiness` wire document plus the
  detected logins and never prompts; `--offline` reports the static state
  without a live check. Without `--json` it runs the interactive step.
  """
  @spec run_model([String.t()], io_callbacks(), keyword()) :: :ok | {:error, term()}
  def run_model(args, io, opts \\ []) do
    usage_command = Keyword.get(opts, :usage_command, "lemon setup")

    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          offline: :boolean,
          provider: :string,
          config_path: :string,
          cwd: :string,
          non_interactive: :boolean,
          help: :boolean
        ],
        aliases: [h: :help, n: :non_interactive]
      )

    if invalid != [] or rest != [] or parsed[:help] do
      io.error.("Usage: #{usage_command} model [--json] [--offline] [--provider NAME]")
      {:error, :usage}
    else
      effective_opts = Keyword.merge(opts, parsed)
      config_path = effective_opts[:config_path] || Modular.global_path()

      if effective_opts[:json] do
        Runner.ensure_required_apps!()

        readiness_opts =
          effective_opts
          |> Keyword.take([:provider, :cwd, :verifier, :codex_discover])
          |> Keyword.put(:config_path, config_path)

        readiness =
          if effective_opts[:offline] do
            ModelReadiness.status(readiness_opts)
          else
            ModelReadiness.check(readiness_opts)
          end

        detected = ModelReadiness.to_wire(ModelReadiness.detect(readiness_opts))

        wire_map =
          readiness
          |> ModelReadiness.to_wire()
          |> Map.put("detected", detected)

        IO.puts(Jason.encode!(wire_map))

        if ready_state?(readiness.state), do: :ok, else: {:error, :not_ready}
      else
        non_interactive? = effective_opts[:non_interactive] || false
        unless non_interactive?, do: Runner.ensure_interactive!(io)
        io.info.("Starting Lemon setup…")
        Runner.ensure_required_apps!()

        with :ok <- ensure_config(config_path, io),
             :ok <- ensure_secrets(io) do
          case connect_model_step(config_path, io, non_interactive?, effective_opts) do
            {:ok, _verification} ->
              :ok

            :ok ->
              readiness = ModelReadiness.status(config_path: config_path)
              if ready_state?(readiness.state), do: :ok, else: {:error, :not_ready}

            {:error, _reason} = error ->
              error
          end
        end
      end
    end
  end

  # `verified` and `saved` both count as ready: the credential resolves, and
  # Lemon re-checks a `saved` provider on the first message.
  defp ready_state?(state), do: state in [:verified, :saved, "verified", "saved"]

  # ──────────────────────────────────────────────────────────────────────────
  # Full wizard steps
  # ──────────────────────────────────────────────────────────────────────────

  defp print_banner(io) do
    io.info.("")
    io.info.("Welcome to Lemon!")
    io.info.("")
  end

  # A first run has nothing to report; a rerun shows what is already done.
  defp print_status(io, state) do
    if Verification.pending_steps(state) != [:config, :secrets, :provider] do
      print_step_status(io, state)
    end
  end

  defp print_step_status(io, state) do
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
      migrate_deprecated_config(expanded, io)
      :ok
    else
      case Scaffold.write_unless_exists(expanded, Scaffold.generate()) do
        {:ok, _path} ->
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
      case MasterKey.init() do
        {:ok, %{source: :file, key_file: path}} ->
          io.info.("Created a secrets key at #{path} (0600).")
          :ok

        {:ok, _keychain} ->
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
        connect_model_step(config_path, io, non_interactive?, opts)
    end
  end

  # The Connect-a-model step: detected logins first, then the provider picker,
  # then Skip. Nothing is copied or saved without an explicit choice.
  defp connect_model_step(config_path, io, non_interactive?, opts) do
    forced = Keyword.get(opts, :provider)

    cond do
      forced ->
        choose_and_configure_provider(config_path, io, non_interactive?, opts)

      non_interactive? ->
        io.info.(
          "Skipping provider setup (non-interactive). Run `lemon setup model` to onboard a provider."
        )

        :ok

      true ->
        detected_logins = ModelReadiness.detect(config_path: config_path)

        options = build_connect_model_options(detected_logins, opts)

        case select_connect_model(options, io) do
          {:ok, {:codex_cli, _detected}} ->
            io.info.("Importing your Codex CLI login and loading models…")

            provider_args =
              [
                "--config-path",
                config_path,
                "--provider",
                "openai-codex",
                "--auth",
                "codex-cli",
                "--set-default"
              ] ++
                if(Keyword.get(opts, :skip_verify, false), do: ["--skip-verify"], else: []) ++
                if(opts[:codex_auth_path],
                  do: ["--codex-auth-path", opts[:codex_auth_path]],
                  else: []
                )

            Provider.configure(provider_args, io, setup_verify_opts(opts))

          {:ok, {:environment, detected}} ->
            var_name = detected.variable
            io.info.("Saving #{var_name} into Lemon's encrypted store…")

            provider_args =
              [
                "--config-path",
                config_path,
                "--provider",
                detected.provider_id,
                "--auth",
                "api-key",
                "--set-default"
              ] ++
                if(Keyword.get(opts, :skip_verify, false), do: ["--skip-verify"], else: [])

            # The value never reaches argv: a shell key stays out of the
            # process list and out of any command echo.
            configure_opts =
              opts
              |> setup_verify_opts()
              |> Keyword.put(:token, System.get_env(var_name))

            Provider.configure(provider_args, io, configure_opts)

          {:ok, :choose_provider} ->
            choose_and_configure_provider(config_path, io, non_interactive?, opts)

          {:ok, :skip} ->
            if Keyword.get(opts, :model_optional, false) do
              io.info.("Skipped. Set up a model in the browser when Lemon is running.")
            else
              io.info.("Skipped. Run `lemon setup model` when ready.")
            end

            :ok

          :cancel ->
            io.info.("Skipped. Run `lemon setup model` when ready.")
            :ok
        end
    end
  end

  defp choose_and_configure_provider(config_path, io, non_interactive?, opts) do
    forced = Keyword.get(opts, :provider)
    io.info.("Checking available providers…")

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
  end

  defp build_connect_model_options(detected_logins, opts) do
    detected_options =
      Enum.map(detected_logins, fn
        %{source: :codex_cli} = detected ->
          %{
            label:
              "Copy your Codex CLI ChatGPT login into Lemon (read-only copy of ~/.codex/auth.json)",
            value: {:codex_cli, detected}
          }

        %{source: :environment, variable: var_name} = detected ->
          %{
            label:
              "Save #{var_name} from this shell into Lemon's encrypted store (the background service can't see your shell)",
            value: {:environment, detected}
          }
      end)

    skip_label =
      if Keyword.get(opts, :model_optional, false) do
        "Skip — set it up in the browser"
      else
        "Skip — finish later with `lemon setup model`"
      end

    detected_options ++
      [
        %{label: "Choose a provider…", value: :choose_provider},
        %{label: skip_label, value: :skip}
      ]
  end

  defp select_connect_model(options, io) do
    case select_value(io, %{
           title: "Connect a model",
           options: options,
           default_index: 0
         }) do
      {:ok, value} ->
        {:ok, value}

      :cancel ->
        :cancel

      :fallback ->
        io.info.("")
        io.info.("Connect a model")
        io.info.("")

        options
        |> Enum.with_index(1)
        |> Enum.each(fn {option, number} ->
          marker = if number == 1, do: " (default)", else: ""
          io.info.("  #{number}. #{option.label}#{marker}")
        end)

        prompt_connect_choice(options, 0, io)
    end
  end

  defp prompt_connect_choice(options, default_index, io) do
    case io.prompt.("Select [default: #{default_index + 1}, q to cancel]: ") do
      nil -> Runner.no_terminal!()
      :eof -> Runner.no_terminal!()
      input -> parse_connect_choice(normalize_input(input), options, default_index, io)
    end
  end

  defp parse_connect_choice(choice, options, default_index, io) do
    cond do
      choice == "" ->
        {:ok, options |> Enum.at(default_index) |> Map.fetch!(:value)}

      choice in ["q", "quit", "cancel"] ->
        :cancel

      choice in ["n", "no", "s", "skip"] ->
        case Enum.find(options, &(&1.value == :skip)) do
          %{value: val} -> {:ok, val}
          nil -> :cancel
        end

      choice in ["y", "yes"] ->
        {:ok, options |> Enum.at(default_index) |> Map.fetch!(:value)}

      String.match?(choice, ~r/^\d+$/) ->
        index = String.to_integer(choice) - 1

        if index >= 0 and index < length(options) do
          {:ok, options |> Enum.at(index) |> Map.fetch!(:value)}
        else
          io.error.("Invalid selection. Enter 1–#{length(options)}.")
          prompt_connect_choice(options, default_index, io)
        end

      true ->
        io.error.("Invalid selection. Enter 1–#{length(options)}.")
        prompt_connect_choice(options, default_index, io)
    end
  end

  defp select_value(io, params) do
    case Map.get(io, :select) do
      select when is_function(select, 1) ->
        case select.(params) do
          {:ok, value} ->
            {:ok, value}

          :cancel ->
            :cancel

          {:error, reason} ->
            if reason == :end_of_input, do: Runner.no_terminal!()

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

  defp format_selector_error(:no_selection), do: "selector exited before a choice was made"
  defp format_selector_error(:invalid_selector_params), do: "invalid selector parameters"
  defp format_selector_error(_reason), do: "the selector could not be started"

  # Setup-journey callers opt into the live credential check; direct
  # `lemon model` onboarding (LemonCli.CLI) stays offline-strong only.
  defp setup_verify_opts(opts) do
    opts
    |> Keyword.take([
      :verifier,
      :skip_verify,
      :config,
      :verification_model,
      :cwd,
      :discovery,
      :codex_discover
    ])
    |> Keyword.put(:live_verify, true)
  end

  # A runtime already answering on the control port owns its ports, so only a
  # stopped runtime's ports are checked. A port another program holds is
  # replaced by the next free one and saved for the launchers.
  defp ensure_ports(io, non_interactive?, opts) do
    env = Env.resolve()
    running? = Keyword.get(opts, :lemon_running?, &Health.running?(&1, timeout_ms: 500))

    unless running?.(env.control_port) do
      free? = Keyword.get(opts, :port_free?, &Ports.free?/1)

      current = %{
        control: env.control_port,
        node: resolve_node_port(),
        web: env.web_port,
        sim: env.sim_port
      }

      chosen =
        Enum.reduce(Ports.required(Profile.default_name()), current, fn key, ports ->
          port = ports[key]
          reserved = ports |> Map.delete(key) |> Map.values()

          # A node gateway explicitly disabled with port 0 binds nothing.
          cond do
            key == :node and port == 0 ->
              ports

            port not in reserved and free?.(port) ->
              ports

            true ->
              replacement = replacement_port(key, port, reserved, free?, io, non_interactive?)
              Map.put(ports, key, replacement)
          end
        end)

      if chosen != current, do: save_ports(chosen, io, opts)
    end

    :ok
  end

  defp replacement_port(key, port, reserved, free?, io, non_interactive?) do
    label = Ports.label(key)
    suggestion = Ports.suggest(port, reserved, free?)

    cond do
      non_interactive? and is_nil(suggestion) ->
        io.error.(
          "Port #{port} for the #{label} is in use and no nearby port is free. Run `lemon setup runtime` to choose one."
        )

        port

      non_interactive? ->
        io.info.("Port #{port} for the #{label} is in use; Lemon will use #{suggestion}.")
        suggestion

      suggestion &&
          prompt_yes?(
            "Port #{port} for the #{label} is already in use. Use #{suggestion} instead?",
            io
          ) ->
        suggestion

      true ->
        prompt_free_port(label, reserved, free?, io)
    end
  end

  defp prompt_free_port(label, reserved, free?, io) do
    case Integer.parse(normalize_input(io.prompt.("Port for the #{label}: "))) do
      {port, ""} when port > 0 and port <= 65_535 ->
        if port not in reserved and free?.(port) do
          port
        else
          io.error.("Port #{port} is also in use. Choose another port.")
          prompt_free_port(label, reserved, free?, io)
        end

      _ ->
        io.error.("Enter a port from 1 to 65535.")
        prompt_free_port(label, reserved, free?, io)
    end
  end

  defp save_ports(ports, io, opts) do
    case Ports.save(ports, opts) do
      {:ok, path} ->
        io.info.("Saved ports to #{path}.")

      {:error, _reason} ->
        io.error.(
          "Could not save the port settings. Check permissions on ~/.lemon, then run `lemon setup runtime`."
        )
    end
  end

  defp interactive?(io, non_interactive?) do
    not non_interactive? and
      Map.get(io, :interactive?, &PromptUI.terminal?/0).()
  end

  defp step_offer_launch(io, state, result, non_interactive?, opts) do
    if interactive?(io, non_interactive?) and Keyword.get(opts, :launch, true) and
         Verification.pending_steps(state) == [] and launch_ready?(result) and
         prompt_yes?("Open Lemon now?", io) do
      launcher = Keyword.get(opts, :launcher, &launch_tui/0)

      case launcher.() do
        :ok -> :ok
        {:error, _reason} -> io.error.("Could not open Lemon. Run `lemon` to try again.")
      end
    end
  end

  # `verified` and `saved` both open Lemon; an explicit `--skip-verify` keeps
  # today's behaviour of not offering the launch after a deferred check.
  defp launch_ready?({:ok, %{live: live}}), do: live in [:ok, :skipped, :saved]
  defp launch_ready?(_result), do: false

  defp launch_tui do
    case System.get_env("LEMON_LAUNCHER") || System.find_executable("lemon") do
      launcher when is_binary(launcher) and launcher != "" ->
        # System.cmd ports do not inherit stdin. Reattach the confirmed TTY
        # explicitly, passing the launcher as data rather than shell source.
        case System.cmd("/bin/sh", [
               "-c",
               "exec \"$1\" tui </dev/tty >/dev/tty 2>&1",
               "lemon-setup",
               launcher
             ]) do
          {_, 0} -> :ok
          _ -> {:error, :launch_failed}
        end

      _ ->
        {:error, :launcher_not_found}
    end
  rescue
    _error in ErlangError -> {:error, :launch_failed}
  end

  defp print_summary(io, state, result, opts) do
    io.info.("")
    pending = Verification.pending_steps(state)
    model_optional? = Keyword.get(opts, :model_optional, false)

    case {pending, result} do
      {[], {:ok, %{provider: provider, model: model, live: :ok}}} ->
        provider_label = provider_display_name(provider)

        io.info.(
          "Setup complete. Model: #{provider} / #{model} (verified with #{provider_label}; no message was sent)."
        )

        io.info.("Success check: a reply arrives and `lemon doctor` shows no FAIL.")
        io.info.("Run `lemon` in your repository and try this first prompt:")

        io.info.(
          "  Read the repository instructions. Find how to run the tests. Add the test command to README if missing, run the focused tests, and show the diff."
        )

        io.info.(
          "Optional next steps: `lemon gateway setup telegram` for Telegram; `lemon web` for the Web UI."
        )

        io.info.("")

      {[], {:ok, %{provider: provider, model: model, live: :disabled}}} ->
        io.info.(
          "Setup complete. Model: #{provider} / #{model} (saved; live check skipped by --skip-verify)."
        )

        io.info.("")

      {[], {:ok, %{provider: provider, model: model} = res}} ->
        io.info.(
          "Setup complete. Model: #{provider} / #{model} (saved; Lemon checks it on your first message)."
        )

        print_saved_reason(res, io)
        io.info.("")

      {[], result} when result == :ok or elem(result, 0) == :ok ->
        provider = state.provider.provider || "default"
        model = state.provider.model || "default"

        io.info.(
          "Setup complete. Model: #{provider} / #{model} (saved; Lemon checks it on your first message)."
        )

        io.info.("")

      {[], _result} ->
        # Verification (or another step) failed even though every step is
        # configured; never claim completion after a failure.
        io.info.("Setup did not complete. Resolve the errors above, then run `lemon setup`.")
        io.info.("")

      {[:provider], :ok} when model_optional? ->
        io.info.("Setup complete. Model setup deferred (set it up in the browser).")
        io.info.("")

      {pending, _result} ->
        io.info.("Setup unfinished — pending steps:")
        print_pending(pending, state, io)

        io.info.("")
    end
  end

  defp provider_display_name(provider_id) do
    case Providers.find(provider_id) do
      %{display_name: name} when is_binary(name) -> name
      _ -> provider_id
    end
  end

  defp print_saved_reason(%{reason: :provider_unreachable}, io) do
    io.info.("Provider unreachable; Lemon will retry on your first message.")
  end

  defp print_saved_reason(%{reason: :check_failed}, io) do
    io.info.("Quick live check failed; Lemon will retry on your first message.")
  end

  defp print_saved_reason(%{live_note: note}, io) when is_binary(note) do
    io.info.("Live check note: #{note}")
  end

  defp print_saved_reason(_res, _io), do: :ok

  defp print_pending(pending, state, io) do
    Enum.each(pending, fn
      :config -> io.info.("  config:   re-run `lemon setup` or create #{state.config.path}")
      :secrets -> io.info.("  secrets:  re-run `lemon setup` (or run `lemon secrets init`)")
      :provider -> io.info.("  provider: run `lemon setup model`")
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
    current = %{
      control: env.control_port,
      node: resolve_node_port(),
      web: env.web_port,
      sim: env.sim_port
    }

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
           node: current.node,
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

  # The node gateway port comes from the environment only; `0` disables it.
  defp resolve_node_port do
    case System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") do
      nil ->
        Ports.default_node_port()

      val ->
        case Integer.parse(String.trim(val)) do
          {port, ""} when port >= 0 and port <= 65_535 -> port
          _ -> Ports.default_node_port()
        end
    end
  end

  defp print_runtime_summary(profile_name, ports, io, opts) do
    profile = Profile.get(profile_name)

    io.info.("")
    io.info.("Runtime profile: #{profile_name}")
    io.info.("  Apps: #{Enum.join(profile.apps, ", ")}")
    io.info.("")
    io.info.("Ports:")
    io.info.("  control-plane : #{ports.control}")

    if ports[:node] && ports[:node] != Ports.default_node_port() do
      io.info.("  node-gateway  : #{ports.node}")
    end

    io.info.("  web           : #{ports.web}")
    io.info.("  sim-ui        : #{ports.sim}")
    io.info.("")
    save_ports(ports, io, opts)
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

  defp prompt_yes?(message, io) do
    suffix = " [Y/n]: "

    answer =
      io.prompt.(message <> suffix)
      |> normalize_input()
      |> String.downcase()

    case answer do
      "" -> true
      "y" -> true
      "yes" -> true
      "n" -> false
      "no" -> false
      _ -> prompt_yes?(message, io)
    end
  end

  defp normalize_input(nil), do: Runner.no_terminal!()
  defp normalize_input(:eof), do: Runner.no_terminal!()
  defp normalize_input(value) when is_binary(value), do: String.trim(value)
  defp normalize_input(value) when is_list(value), do: value |> List.to_string() |> String.trim()
  defp normalize_input(value), do: value |> to_string() |> String.trim()
end
