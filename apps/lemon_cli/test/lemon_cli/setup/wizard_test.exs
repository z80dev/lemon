defmodule LemonCli.Setup.WizardTest.CountingKeychain do
  @moduledoc false
  # A keychain-named key provider that counts reads and can make each read
  # slow, so a wizard run can be measured without touching the real Keychain.
  @behaviour LemonCore.Secrets.KeyProvider

  @impl true
  def name, do: :keychain

  @impl true
  def available?(_opts), do: true

  @impl true
  def on_invalid, do: :continue

  @impl true
  def fetch(_opts) do
    %{key: key, delay: delay} =
      Agent.get_and_update(__MODULE__, fn state ->
        {state, %{state | count: state.count + 1}}
      end)

    if delay > 0, do: Process.sleep(delay)
    if key, do: {:ok, key}, else: {:error, :missing}
  end

  @impl true
  def put(encoded, _opts) do
    Agent.update(__MODULE__, &%{&1 | key: encoded})
    :ok
  end

  def start do
    case Agent.start_link(fn -> %{key: nil, delay: 0, count: 0} end, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def put_key(encoded, opts), do: put(encoded, opts)

  @doc "Starts counting from zero and applies a per-read delay in milliseconds."
  def reset(delay), do: Agent.update(__MODULE__, &%{&1 | delay: delay, count: 0})

  def count, do: Agent.get(__MODULE__, & &1.count)
end

defmodule LemonCli.Setup.WizardTest do
  # async: false because we manipulate Application env, HOME, and the secrets store
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.Wizard
  alias LemonCli.Setup.WizardTest.CountingKeychain
  alias LemonCore.Config.Modular
  alias LemonCore.Secrets
  alias LemonCore.Setup.Readiness

  # Minimal IO callbacks stub for testing non-interactive paths
  defp silent_io do
    %{
      info: fn _msg -> :ok end,
      error: fn _msg -> :ok end,
      prompt: fn _msg -> "" end,
      secret: fn _msg -> "" end
    }
  end

  @port_vars [
    "LEMON_CONTROL_PLANE_PORT",
    "LEMON_CONTROL_PLANE_NODE_PORT",
    "LEMON_WEB_PORT",
    "LEMON_SIM_UI_PORT"
  ]

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_setup_wizard_#{System.unique_integer([:positive])}")

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    Runner.ensure_required_apps!()

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_secrets_config = Application.get_env(:lemon_core, LemonCore.Secrets)

    System.put_env("HOME", home)
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    # Setup behavior is covered against deterministic providers. Exercising the
    # real macOS Keychain here can block on an OS prompt and leaves uncertainty
    # about whether a timed-out write succeeded.
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env, :file])
    clear_secrets_table()

    # Probes in the full wizard must not depend on what this machine listens on.
    original_ports = Map.new(@port_vars, &{&1, System.get_env(&1)})
    Enum.each(@port_vars, &System.put_env(&1, Integer.to_string(unused_port())))

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      if original_secrets_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_secrets_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      Enum.each(original_ports, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok,
     tmp_dir: tmp_dir,
     home: home,
     config_path: Path.join(tmp_dir, "config.toml"),
     key_file: Path.join(home, ".lemon/secrets_master_key")}
  end

  describe "run_runtime/3 — profile input safety" do
    test "invalid --profile fails without creating a new atom" do
      invalid_profile = "not_a_profile_#{System.unique_integer([:positive])}"

      assert {:error, :invalid_arguments} =
               Wizard.run_runtime(["--profile", invalid_profile], silent_io(),
                 non_interactive: true
               )

      assert_raise ArgumentError, fn -> String.to_existing_atom(invalid_profile) end
    end

    test "valid profile name is accepted without error" do
      io = silent_io()
      result = Wizard.run_runtime(["--profile", "runtime_full"], io, non_interactive: true)
      assert result == :ok
    end

    test "invalid port flags fail instead of silently using defaults" do
      for flag <- ["--control-port", "--web-port", "--sim-port"],
          value <- ["0", "-1", "65536", "abc"] do
        io = recording_io()

        assert {:error, :invalid_arguments} =
                 Wizard.run_runtime([flag, value, "--non-interactive"], io)

        events = drain_events([])
        assert error_event?(events, &String.contains?(&1, "1 to 65535"))
        assert prompt_events(events) == []
        refute File.exists?(Path.join(System.get_env("HOME"), ".lemon/ports.env"))
      end
    end

    test "interactive invalid profiles and ports re-prompt", %{home: home} do
      io = recording_io(["0", "typo", "999", "runtime_min", "abc", "0", "65536", "5050", "", ""])
      assert :ok = Wizard.run_runtime([], io)
      events = drain_events([])
      assert error_event?(events, &String.contains?(&1, "Invalid profile"))
      assert error_event?(events, &String.contains?(&1, "Invalid port"))
      assert info_event?(events, &String.contains?(&1, "Runtime profile: runtime_min"))
      assert File.read!(Path.join(home, ".lemon/ports.env")) =~ "LEMON_CONTROL_PLANE_PORT=5050\n"
      assert System.get_env("LEMON_CONTROL_PLANE_PORT") == "5050"
      assert Enum.count(prompt_events(events), &String.contains?(&1, "Choose profile")) == 4
      assert Enum.count(prompt_events(events), &String.contains?(&1, "control-plane port")) == 4
    end
  end

  describe "run_full/3 — ports" do
    setup %{config_path: path} do
      configure_ready_provider(path)
      System.put_env("LEMON_CONTROL_PLANE_PORT", "4040")
      System.put_env("LEMON_CONTROL_PLANE_NODE_PORT", "4044")
      System.put_env("LEMON_WEB_PORT", "4080")

      {:ok,
       opts: [
         config_path: path,
         verifier: fn _ -> {:ok, %{}} end,
         lemon_running?: fn _ -> false end
       ]}
    end

    test "an occupied port is replaced by the confirmed suggestion and saved", ctx do
      opts = [port_free?: &(&1 not in [4040, 4041]), launch: false] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io([""]), opts)

      events = drain_events([])

      assert "Port 4040 for the control plane is already in use. Use 4042 instead? [Y/n]: " in prompt_events(
               events
             )

      assert File.read!(Path.join(ctx.home, ".lemon/ports.env")) ==
               "LEMON_CONTROL_PLANE_PORT=4042\nLEMON_WEB_PORT=4080\nLEMON_SIM_UI_PORT=" <>
                 "#{System.get_env("LEMON_SIM_UI_PORT")}\n"

      assert System.get_env("LEMON_CONTROL_PLANE_PORT") == "4042"
    end

    test "declining the suggestion asks until a free port is entered", ctx do
      opts = [port_free?: &(&1 not in [4080, 5000]), launch: false] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io(["n", "4040", "5000", "x", "5001"]), opts)

      events = drain_events([])
      assert error_event?(events, &(&1 == "Port 4040 is also in use. Choose another port."))
      assert error_event?(events, &(&1 == "Port 5000 is also in use. Choose another port."))
      assert error_event?(events, &(&1 == "Enter a port from 1 to 65535."))
      assert System.get_env("LEMON_WEB_PORT") == "5001"
      assert System.get_env("LEMON_CONTROL_PLANE_PORT") == "4040"
    end

    test "non-interactive setup picks the suggestion without asking", ctx do
      opts = [port_free?: &(&1 != 4080), non_interactive: true] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io(), opts)

      events = drain_events([])
      assert prompt_events(events) == []

      assert info_event?(
               events,
               &(&1 == "Port 4080 for the web UI is in use; Lemon will use 4081.")
             )

      assert System.get_env("LEMON_WEB_PORT") == "4081"
    end

    test "an occupied node gateway port 4044 is detected, replaced, and saved", ctx do
      opts = [port_free?: &(&1 != 4044), launch: false] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io([""]), opts)

      events = drain_events([])

      assert "Port 4044 for the node gateway is already in use. Use 4045 instead? [Y/n]: " in prompt_events(
               events
             )

      env_file = File.read!(Path.join(ctx.home, ".lemon/ports.env"))
      assert env_file =~ "LEMON_CONTROL_PLANE_NODE_PORT=4045\n"
      assert System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") == "4045"
    end

    test "non-interactive setup replaces occupied node gateway port 4044 and persists it", ctx do
      opts = [port_free?: &(&1 != 4044), non_interactive: true] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io(), opts)

      events = drain_events([])
      assert prompt_events(events) == []

      assert info_event?(
               events,
               &(&1 == "Port 4044 for the node gateway is in use; Lemon will use 4045.")
             )

      env_file = File.read!(Path.join(ctx.home, ".lemon/ports.env"))
      assert env_file =~ "LEMON_CONTROL_PLANE_NODE_PORT=4045\n"
      assert System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") == "4045"
    end

    test "a node gateway disabled with LEMON_CONTROL_PLANE_NODE_PORT=0 is never reserved", ctx do
      System.put_env("LEMON_CONTROL_PLANE_NODE_PORT", "0")

      opts = [port_free?: &(&1 != 4044), non_interactive: true] ++ ctx.opts
      assert :ok = Wizard.run_full([], recording_io(), opts)

      events = drain_events([])
      refute info_event?(events, &String.contains?(&1, "node gateway"))
      assert System.get_env("LEMON_CONTROL_PLANE_NODE_PORT") == "0"
    end

    test "free ports, or ports owned by a running Lemon, are left alone", ctx do
      for opts <- [
            [port_free?: fn _ -> true end],
            [lemon_running?: fn 4040 -> true end, port_free?: fn _ -> flunk("probed") end]
          ] do
        assert :ok =
                 Wizard.run_full(
                   [],
                   recording_io(),
                   Keyword.merge(ctx.opts, [non_interactive: true] ++ opts)
                 )

        refute File.exists?(Path.join(ctx.home, ".lemon/ports.env"))
        assert System.get_env("LEMON_CONTROL_PLANE_PORT") == "4040"
      end
    end
  end

  describe "run_full/3 — fresh state" do
    test "no terminal fails before creating setup files", %{config_path: path, key_file: key_file} do
      io = Map.put(recording_io(), :interactive?, fn -> false end)

      assert_raise Mix.Error, ~r/No interactive terminal.*lemon setup --non-interactive/, fn ->
        Wizard.run_full([], io, config_path: path)
      end

      refute File.exists?(path)
      refute File.exists?(key_file)
      assert prompt_events(drain_events([])) == []
    end

    test "declining provider onboarding is unfinished, not failed", %{config_path: path} do
      io = recording_io(["n"])
      assert {:error, :setup_incomplete} = Wizard.run_full([], io, config_path: path)
      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup unfinished — pending steps"))
      refute info_event?(events, &String.contains?(&1, "Setup did not complete"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
      refute Enum.any?(prompt_events(events), &String.contains?(&1, "Open Lemon"))
      refute info_event?(events, &String.contains?(&1, "first prompt"))
      refute error_event?(events, fn _ -> true end)
    end

    test "bootstraps config, auto-initializes the master key, and defers the provider step", %{
      config_path: config_path,
      key_file: key_file
    } do
      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) ==
               {:error, :setup_incomplete}

      # Config scaffold was created.
      assert File.exists?(config_path)
      assert {:ok, %{}} = Toml.decode_file(config_path)

      # Master key was initialized automatically — no second command required.
      assert File.exists?(key_file)
      assert {:ok, encoded} = File.read(key_file)
      assert {:ok, decoded} = encoded |> String.trim() |> Base.decode64()
      assert byte_size(decoded) == 32
      assert file_mode(key_file) == 0o600

      events = drain_events([])

      # A first run has no step status to report.
      refute info_event?(events, &String.contains?(&1, "Setup status"))
      assert info_event?(events, &String.contains?(&1, "lemon setup provider"))
      assert info_event?(events, &String.contains?(&1, "Setup unfinished"))

      refute info_event?(events, &String.contains?(&1, "Setup complete"))
      # Non-interactive mode never prompts.
      assert prompt_events(events) == []
    end

    test "rerunning is safe and concise: config and master key are never replaced", %{
      config_path: config_path,
      key_file: key_file
    } do
      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) ==
               {:error, :setup_incomplete}

      drain_events([])

      {:ok, config_before} = File.read(config_path)
      {:ok, key_before} = File.read(key_file)

      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) ==
               {:error, :setup_incomplete}

      assert File.read!(config_path) == config_before
      assert File.read!(key_file) == key_before

      events = drain_events([])

      assert info_event?(events, &String.contains?(squish(&1), "[done] config"))
      assert info_event?(events, &String.contains?(squish(&1), "[done] secrets"))
      assert info_event?(events, &String.contains?(squish(&1), "[pending] provider"))
      assert info_event?(events, &String.contains?(&1, "Setup unfinished"))
    end
  end

  describe "run_full/3 — partial state" do
    test "existing config and configured secrets are kept; the provider step stays pending", %{
      config_path: config_path,
      key_file: key_file
    } do
      original_config = "# existing user config\n"
      File.write!(config_path, original_config)
      set_master_key_env()

      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) ==
               {:error, :setup_incomplete}

      # The user's config is never overwritten and no key is initialized.
      assert File.read!(config_path) == original_config
      refute File.exists?(key_file)

      events = drain_events([])

      assert info_event?(events, &String.contains?(squish(&1), "[done] config"))
      assert info_event?(events, &String.contains?(squish(&1), "[done] secrets"))
      assert info_event?(events, &String.contains?(squish(&1), "[pending] provider"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
    end
  end

  describe "run_full/3 — legacy config" do
    test "rewrites a TUI-written [agent] table to the current schema, keeping a backup", %{
      config_path: config_path
    } do
      legacy = """
      [agent]
      default_provider = "openai"
      default_model = "openai:gpt-5.1"

      [control_plane]

      [providers."anthropic"]
      api_key_secret = "anthropic_api_key"

      [providers."openai-codex"]
      oauth_secret = "llm_openai_codex_api_key"
      auth_source = "oauth"
      """

      File.write!(config_path, legacy)
      set_master_key_env()

      io = recording_io()
      Wizard.run_full([], io, non_interactive: true, config_path: config_path)

      settings = Toml.decode_file!(config_path)
      refute Map.has_key?(settings, "agent")
      assert settings["defaults"] == %{"provider" => "openai", "model" => "openai:gpt-5.1"}
      assert settings["providers"]["openai-codex"]["auth_source"] == "oauth"

      assert [backup] = Path.wildcard(config_path <> ".bak-*")
      assert File.read!(backup) == legacy

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "agent.default_model → defaults.model"))
      assert info_event?(events, &String.contains?(&1, "Backup: #{backup}"))
    end
  end

  describe "run_full/3 — complete state" do
    for {provider, model} <- [{"openai", "gpt-5"}, {"ollama", "qwen3"}] do
      test "#{provider} without secret refs stays ready after successful wizard completion", %{
        config_path: path
      } do
        previous = System.get_env("OPENAI_API_KEY")

        on_exit(fn ->
          if previous,
            do: System.put_env("OPENAI_API_KEY", previous),
            else: System.delete_env("OPENAI_API_KEY")
        end)

        System.put_env("OPENAI_API_KEY", "test-env-key")
        set_master_key_env()

        File.write!(path, """
        [defaults]
        provider = "#{unquote(provider)}"
        model = "#{unquote(model)}"
        """)

        opts = [config_path: path, non_interactive: true, verifier: fn _ -> {:ok, %{}} end]
        assert :ok = Wizard.run_full([], recording_io(), opts)
        assert Readiness.ready?(Readiness.status(config_path: path))
      end
    end

    test "configured users are not reprompted and the wizard stays concise", %{
      config_path: config_path
    } do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("wizard_openai_key", "sk-wizard-complete")

      File.write!(config_path, """
      [defaults]
        provider = "openai"
        model = "openai:gpt-5"

      [providers.openai]
        api_key_secret = "wizard_openai_key"
      """)

      io = recording_io()

      assert Wizard.run_full([], io, config_path: config_path, verifier: fn _ -> {:ok, %{}} end) ==
               :ok

      assert Readiness.ready?(Readiness.status(config_path: config_path))

      events = drain_events([])

      assert info_event?(events, &String.contains?(squish(&1), "[done] provider"))
      assert info_event?(events, &String.contains?(&1, "Provider already configured"))
      assert info_event?(events, &String.contains?(&1, "Setup complete"))

      # Provider onboarding, runtime profile, and ports are never asked.
      assert prompt_events(events) == []

      assert info_event?(events, &String.contains?(&1, "Verifying provider"))
      assert info_event?(events, &String.contains?(&1, "lemon doctor"))
      refute info_event?(events, &String.contains?(&1, "lemon setup doctor"))
    end

    test "finish screen shows the first prompt and success check", %{config_path: path} do
      configure_ready_provider(path)

      assert :ok =
               Wizard.run_full([], recording_io(),
                 config_path: path,
                 non_interactive: true,
                 verifier: fn _ -> {:ok, %{}} end
               )

      summary =
        drain_events([])
        |> Enum.flat_map(fn
          {:info, message} -> [message]
          _ -> []
        end)
        |> Enum.drop_while(&(not String.starts_with?(&1, "Setup complete.")))

      assert summary == [
               "Setup complete. Model: openai / openai:gpt-5 (verified with OpenAI; no message was sent).",
               "Success check: a reply arrives and `lemon doctor` shows no FAIL.",
               "Run `lemon` in your repository and try this first prompt:",
               "  Read the repository instructions. Find how to run the tests. Add the test command to README if missing, run the focused tests, and show the diff.",
               "Optional next steps: `lemon gateway setup telegram` for Telegram; `lemon web` for the Web UI.",
               ""
             ]
    end

    test "TTY finish offers an injected launcher, defaulting to yes", %{config_path: path} do
      configure_ready_provider(path)

      for answer <- ["", "yes", "n"] do
        # The first answer declines the Telegram/Discord question.
        io = Map.put(recording_io(["", answer]), :interactive?, fn -> true end)

        assert :ok =
                 Wizard.run_full([], io,
                   config_path: path,
                   verifier: fn _ -> {:ok, %{}} end,
                   launcher: fn ->
                     send(self(), :launched)
                     :ok
                   end
                 )

        if answer == "n", do: refute_received(:launched), else: assert_received(:launched)
        assert "Open Lemon now? [Y/n]: " in prompt_events(drain_events([]))
      end
    end

    test "launch is not offered without a TTY, in the launcher gate, or without verification", %{
      config_path: path
    } do
      configure_ready_provider(path)

      for opts <- [
            [],
            [launch: false, tty: true],
            [skip_verify: true, tty: true],
            [non_interactive: true, tty: true],
            [verifier: fn _ -> {:error, :unauthorized} end, tty: true]
          ] do
        io = recording_io()
        io = if opts[:tty], do: Map.put(io, :interactive?, fn -> true end), else: io

        Wizard.run_full(
          [],
          io,
          Keyword.merge(
            [
              config_path: path,
              verifier: fn _ -> {:ok, %{}} end,
              launcher: fn -> flunk("launcher must not run") end
            ],
            Keyword.delete(opts, :tty)
          )
        )

        refute Enum.any?(prompt_events(drain_events([])), &String.contains?(&1, "Open Lemon"))
      end
    end

    test "launcher failure keeps a manual try-it-now path", %{config_path: path} do
      configure_ready_provider(path)
      io = Map.put(recording_io(["n", "y"]), :interactive?, fn -> true end)

      assert :ok =
               Wizard.run_full([], io,
                 config_path: path,
                 verifier: fn _ -> {:ok, %{}} end,
                 launcher: fn -> {:error, :unavailable} end
               )

      assert error_event?(drain_events([]), &String.contains?(&1, "Run `lemon` to try again"))
    end

    test "rerunning a configured provider performs the live check and reports rejection", %{
      config_path: path
    } do
      configure_ready_provider(path)
      io = recording_io()

      assert {:error, :verification_failed} =
               Wizard.run_full([], io,
                 config_path: path,
                 non_interactive: true,
                 verifier: fn input ->
                   send(self(), {:checked_existing, input.api_key})
                   {:error, :unauthorized}
                 end
               )

      assert_received {:checked_existing, "sk-wizard-existing"}
      events = drain_events([])
      assert error_event?(events, &String.contains?(&1, "HTTP 401/403"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
    end

    test "explicitly deferred verification does not launch", %{config_path: path} do
      configure_ready_provider(path)
      io = Map.put(recording_io(), :interactive?, fn -> true end)

      assert :ok =
               Wizard.run_full([], io,
                 config_path: path,
                 skip_verify: true,
                 verifier: fn _ -> flunk("skipped check ran") end,
                 launcher: fn -> flunk("deferred verification must not launch") end
               )
    end

    test "an unavailable live check still offers launch", %{config_path: path} do
      configure_ready_provider(path)
      io = Map.put(recording_io([""]), :interactive?, fn -> true end)

      assert :ok =
               Wizard.run_full([], io,
                 config_path: path,
                 verifier: fn _ -> {:skip, :not_supported} end,
                 launcher: fn ->
                   send(self(), :launched)
                   :ok
                 end
               )

      assert_received :launched
    end
  end

  describe "run_full/3 — how Lemon is used" do
    # Every component seam fails loudly unless a test opts into it.
    defp component_opts(path, overrides) do
      Keyword.merge(
        [
          config_path: path,
          verifier: fn _ -> {:ok, %{}} end,
          packaged?: true,
          bot_installed?: false,
          install_bot: fn _ -> flunk("Lemon Bot must not be installed") end,
          bot_runner: fn _, _, _ -> flunk("lemon-bot must not run") end,
          install_service: fn -> flunk("no service must be installed") end,
          gateway_setup: fn _ -> flunk("gateway setup must not run") end,
          launcher: fn -> flunk("the TUI must not open") end
        ],
        overrides
      )
    end

    defp tty(io), do: Map.put(io, :interactive?, fn -> true end)

    defp installed_bot do
      fn [] ->
        send(self(), :bot_installed)
        {:ok, %{version: "2026.11.4", launcher: "/home/u/.local/bin/lemon-bot", installed: true}}
      end
    end

    defp bot_runner do
      fn launcher, args, interactive? ->
        send(self(), {:bot_up, launcher, args, interactive?})
        :ok
      end
    end

    test "Browser installs Lemon Bot, hands off to lemon-bot up, and never opens the TUI", %{
      config_path: path
    } do
      configure_ready_provider(path)
      io = tty(recording_io(["2", ""]))

      assert :ok =
               Wizard.run_full(
                 [],
                 io,
                 component_opts(path, install_bot: installed_bot(), bot_runner: bot_runner())
               )

      assert_received :bot_installed

      assert_received {:bot_up, "/home/u/.local/bin/lemon-bot", ["up", "--this-machine"], true}

      prompts = prompt_events(drain_events([]))
      assert "Connect Telegram or Discord now? [y/N]: " in prompts
      refute Enum.any?(prompts, &String.contains?(&1, "Open Lemon"))
      refute Enum.any?(prompts, &String.contains?(&1, "background"))
    end

    test "Both sets up Lemon Bot and still offers the TUI", %{config_path: path} do
      configure_ready_provider(path)
      io = tty(recording_io(["3", "", ""]))

      assert :ok =
               Wizard.run_full(
                 [],
                 io,
                 component_opts(path,
                   install_bot: installed_bot(),
                   bot_runner: bot_runner(),
                   launcher: fn ->
                     send(self(), :launched)
                     :ok
                   end
                 )
               )

      assert_received {:bot_up, _launcher, ["up", "--this-machine"], true}
      assert_received :launched
    end

    test "in a terminal, Bot setup and the TUI are handed to the launcher in order", %{
      config_path: path,
      tmp_dir: tmp_dir
    } do
      configure_ready_provider(path)
      handoff = Path.join(tmp_dir, "handoff")

      handed_off = fn answers, overrides ->
        File.rm(handoff)

        opts =
          path
          |> component_opts([install_bot: installed_bot(), handoff: handoff] ++ overrides)
          |> Keyword.drop([:bot_runner, :launcher])

        assert :ok = Wizard.run_full([], tty(recording_io(answers)), opts)
        File.read!(handoff)
      end

      # Both, no Telegram, open Lemon: the Bot first, then the TUI.
      assert handed_off.(["3", "", ""], []) == "bot-up\ntui\n"
      # An explicit --use makes the Bot step required; Browser never opens the TUI.
      assert handed_off.([""], use: "browser") == "bot-up required\n"

      assert info_event?(
               drain_events([]),
               &String.contains?(&1, "continues in this terminal after the last question")
             )
    end

    test "without the lemon launcher the TUI is not opened from setup's VM", %{
      config_path: path
    } do
      configure_ready_provider(path)
      opts = path |> component_opts(handoff: nil) |> Keyword.delete(:launcher)

      assert :ok = Wizard.run_full([], tty(recording_io(["1", "", "", ""])), opts)
      assert error_event?(drain_events([]), &String.contains?(&1, "Run `lemon` to try again"))
    end

    test "Terminal offers background services, defaulting to no", %{config_path: path} do
      configure_ready_provider(path)

      for {answer, installed?} <- [{"", false}, {"y", true}] do
        io = tty(recording_io(["1", answer, "", "n"]))

        assert :ok =
                 Wizard.run_full(
                   [],
                   io,
                   component_opts(path,
                     install_service: fn ->
                       send(self(), :service_installed)
                       0
                     end
                   )
                 )

        if installed?,
          do: assert_received(:service_installed),
          else: refute_received(:service_installed)

        assert "Keep Lemon running in the background? It starts when you log in. [y/N]: " in prompt_events(
                 drain_events([])
               )
      end
    end

    test "--use browser needs no prompts and keeps lemon-bot off the browser", %{
      config_path: path
    } do
      configure_ready_provider(path)

      assert :ok =
               Wizard.run_full(
                 [],
                 recording_io(),
                 component_opts(path,
                   non_interactive: true,
                   use: "browser",
                   install_bot: installed_bot(),
                   bot_runner: bot_runner()
                 )
               )

      assert_received {:bot_up, _launcher, ["up", "--this-machine", "--no-open"], false}
      assert prompt_events(drain_events([])) == []
    end

    test "a failed Lemon Bot install fails explicit --use but falls back to the TUI otherwise", %{
      config_path: path
    } do
      configure_ready_provider(path)
      failing = fn _ -> {:error, :missing_bot_artifact} end

      assert {:error, {:bot_install_failed, :missing_bot_artifact}} =
               Wizard.run_full(
                 [],
                 recording_io(),
                 component_opts(path, non_interactive: true, use: "browser", install_bot: failing)
               )

      assert error_event?(
               drain_events([]),
               &String.contains?(&1, "no Lemon Bot for this platform")
             )

      assert :ok =
               Wizard.run_full(
                 [],
                 tty(recording_io(["2", "", ""])),
                 component_opts(path,
                   install_bot: failing,
                   launcher: fn ->
                     send(self(), :launched)
                     :ok
                   end
                 )
               )

      assert_received :launched
      assert info_event?(drain_events([]), &String.contains?(&1, "lemon setup --use browser"))
    end

    test "an unfinished lemon-bot up fails only an explicit request", %{config_path: path} do
      configure_ready_provider(path)

      assert {:error, {:bot_setup_failed, {:exit_status, 1}}} =
               Wizard.run_full(
                 [],
                 recording_io(),
                 component_opts(path,
                   non_interactive: true,
                   use: "both",
                   install_bot: installed_bot(),
                   bot_runner: fn _, _, _ -> {:error, {:exit_status, 1}} end
                 )
               )

      assert error_event?(drain_events([]), &String.contains?(&1, "lemon-bot up"))
    end

    test "the question is skipped for the launcher gate, source checkouts and an installed Bot",
         %{config_path: path} do
      configure_ready_provider(path)

      for overrides <- [[launch: false], [packaged?: false], [bot_installed?: true]] do
        io = tty(recording_io(["", "n"]))
        Wizard.run_full([], io, component_opts(path, overrides))
        prompts = prompt_events(drain_events([]))
        refute Enum.any?(prompts, &String.starts_with?(&1, "Select"))
        refute Enum.any?(prompts, &String.contains?(&1, "background"))
      end
    end

    test "invalid or source-checkout Bot requests fail before installing anything", %{
      config_path: path
    } do
      configure_ready_provider(path)

      assert {:error, :invalid_arguments} =
               Wizard.run_full([], recording_io(), component_opts(path, use: "phone"))

      assert {:error, :bot_requires_packaged_install} =
               Wizard.run_full(
                 [],
                 recording_io(),
                 component_opts(path, non_interactive: true, use: "browser", packaged?: false)
               )
    end
  end

  describe "run/3 — full wizard flags" do
    test "top-level flags drive the non-interactive full wizard", %{config_path: config_path} do
      io = recording_io()

      assert Wizard.run(["--non-interactive", "--config-path", config_path], io) ==
               {:error, :setup_incomplete}

      assert File.exists?(config_path)

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup unfinished"))
    end

    test "full setup stores credentials and selects a default without prompts", %{
      config_path: path
    } do
      io = %{recording_io() | prompt: fn _ -> flunk("non-interactive setup prompted") end}

      assert :ok =
               Wizard.run(
                 [
                   "--non-interactive",
                   "--provider",
                   "openai",
                   "--token",
                   "wizard-test-token",
                   "--model",
                   "gpt-5",
                   "--set-default",
                   "--skip-verify",
                   "--config-path",
                   path
                 ],
                 io
               )

      settings = Toml.decode_file!(path)
      assert settings["defaults"]["provider"] == "openai"
      assert settings["defaults"]["model"] == "openai:gpt-5"

      assert {:ok, "wizard-test-token"} =
               Secrets.get(settings["providers"]["openai"]["api_key_secret"],
                 prefer_env: false,
                 env_fallback: false
               )

      assert Readiness.ready?(Readiness.status(config_path: path))

      events = drain_events([])

      assert info_event?(
               events,
               &(&1 ==
                   "Setup complete. Model: openai / openai:gpt-5 (saved; live check skipped by --skip-verify).")
             )
    end
  end

  describe "run/3 — fresh non-interactive setup" do
    test "writes a current-schema config whose default matches the onboarded provider", %{
      config_path: path
    } do
      assert :ok =
               Wizard.run(
                 [
                   "--non-interactive",
                   "--provider",
                   "openai",
                   "--token",
                   "wizard-test-token",
                   "--skip-verify",
                   "--config-path",
                   path
                 ],
                 recording_io()
               )

      settings = Toml.decode_file!(path)
      refute Map.has_key?(settings, "agent")
      assert settings["defaults"]["provider"] == "openai"
      assert "openai:" <> model = settings["defaults"]["model"]
      refute model == "fallback"
      assert Map.keys(settings["providers"]) == ["openai"]
      assert {:ok, _config} = Modular.validate_settings(settings)
      assert Readiness.ready?(Readiness.status(config_path: path))
    end
  end

  describe "run/3 — provider verification failure" do
    test "returns {:error, :verification_failed} with actionable recovery and no success claim",
         %{
           config_path: config_path
         } do
      set_master_key_env()

      io = recording_io()

      result =
        Wizard.run(
          [
            "provider",
            "--provider",
            "openai",
            "--token",
            "wizard-token",
            "--secret-name",
            "wizard_verify_key",
            "--set-default",
            "--model",
            "gpt-5",
            "--config-path",
            config_path
          ],
          io,
          verifier: fn input ->
            send(self(), {:live_check, input})
            {:error, :unauthorized}
          end
        )

      assert result == {:error, :verification_failed}

      assert_received {:live_check, %{provider: "openai", api_key: "wizard-token"}}

      events = drain_events([])

      assert error_event?(events, &String.contains?(&1, "Verification failed"))
      assert error_event?(events, &String.contains?(&1, "lemon setup provider"))
      assert error_event?(events, &String.contains?(&1, "--skip-verify"))

      refute info_event?(events, &String.contains?(&1, "Provider configuration verified"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
    end
  end

  describe "run_full/3 — Connect a model step" do
    test "offers a detected Codex CLI login first and never imports it without a choice", %{
      config_path: path,
      home: home
    } do
      write_codex_cli_login(home)
      set_master_key_env()

      io = recording_io(["s"])
      assert {:error, :setup_incomplete} = Wizard.run_full([], io, config_path: path)

      events = drain_events([])
      options = Enum.filter(info_messages(events), &String.match?(&1, ~r/^  \d+\. /))

      assert [first | _] = options
      assert first =~ "1. Copy your Codex CLI ChatGPT login into Lemon"
      assert List.last(options) =~ "Skip — finish later with `lemon setup model`"
      assert Enum.any?(options, &String.contains?(&1, "Sign in with ChatGPT (browser)"))
      messages = info_messages(events)
      warning = Enum.find_index(messages, &String.contains?(&1, "if either refreshes it"))
      choice = Enum.find_index(messages, &String.contains?(&1, "1. Copy your Codex"))
      assert is_integer(warning) and warning < choice
      refute first =~ "read-only copy"

      # The login is only read when a choice says so.
      settings = if File.exists?(path), do: Toml.decode_file!(path), else: %{}
      refute get_in(settings, ["providers", "openai-codex"])
      refute info_event?(events, &String.contains?(&1, "Importing your Codex"))
    end

    test "a detected shell key is offered as an explicit save, not used silently", %{
      config_path: path
    } do
      previous = System.get_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-shell")

      on_exit(fn ->
        if previous,
          do: System.put_env("ANTHROPIC_API_KEY", previous),
          else: System.delete_env("ANTHROPIC_API_KEY")
      end)

      set_master_key_env()
      io = recording_io(["s"])
      assert {:error, :setup_incomplete} = Wizard.run_full([], io, config_path: path)

      events = drain_events([])

      assert info_event?(
               events,
               &String.contains?(
                 &1,
                 "Save ANTHROPIC_API_KEY from this shell into Lemon's encrypted store"
               )
             )

      settings = if File.exists?(path), do: Toml.decode_file!(path), else: %{}
      refute get_in(settings, ["defaults", "provider"])
    end

    test "end of input in the model step fails instead of choosing", %{config_path: path} do
      set_master_key_env()
      io = %{recording_io() | prompt: fn _ -> :eof end}

      assert_raise Mix.Error, ~r/No interactive terminal/, fn ->
        Wizard.run_full([], io, config_path: path)
      end
    end

    test "--model-optional Skip completes setup with the provider step pending", %{
      config_path: path
    } do
      set_master_key_env()
      io = recording_io(["s"])

      assert :ok = Wizard.run_full([], io, config_path: path, model_optional: true)

      state = Readiness.status(config_path: path)
      assert Readiness.pending_steps(state) == [:provider]

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Skip — set it up in the browser"))
      assert info_event?(events, &String.contains?(&1, "Setup complete. Model setup deferred"))
    end

    test "--use browser lets Skip defer the model and still sets up Lemon Bot", %{
      config_path: path
    } do
      set_master_key_env()

      assert :ok =
               Wizard.run_full(
                 [],
                 recording_io(["s"]),
                 component_opts(path,
                   use: "browser",
                   install_bot: installed_bot(),
                   bot_runner: bot_runner()
                 )
               )

      assert_received {:bot_up, _launcher, ["up", "--this-machine", "--no-open"], false}
      assert Readiness.pending_steps(Readiness.status(config_path: path)) == [:provider]
    end

    test "without --model-optional a Skip leaves setup unfinished", %{config_path: path} do
      set_master_key_env()
      io = recording_io(["s"])

      assert {:error, :setup_incomplete} = Wizard.run_full([], io, config_path: path)

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup unfinished — pending steps"))
      assert info_event?(events, &String.contains?(&1, "provider: run `lemon setup model`"))
    end
  end

  describe "run_full/3 — truthful summaries" do
    test "a provider without a quick live check is saved, not mislabelled", %{config_path: path} do
      configure_ready_provider(path)
      io = Map.put(recording_io([""]), :interactive?, fn -> true end)

      assert :ok =
               Wizard.run_full([], io,
                 config_path: path,
                 verifier: fn _ -> {:skip, {:unsupported_api, :oauth}} end,
                 launcher: fn ->
                   send(self(), :launched)
                   :ok
                 end
               )

      events = drain_events([])

      assert info_event?(
               events,
               &(&1 ==
                   "Setup complete. Model: openai / openai:gpt-5 (saved; Lemon checks it on your first message).")
             )

      refute info_event?(events, &String.contains?(&1, "--skip-verify"))
      assert :launched in events
    end

    test "an unreachable provider is saved with its reason and still offers launch", %{
      config_path: path
    } do
      configure_ready_provider(path)
      io = Map.put(recording_io([""]), :interactive?, fn -> true end)

      assert :ok =
               Wizard.run_full([], io,
                 config_path: path,
                 verifier: fn _ -> {:error, :unreachable} end,
                 launcher: fn ->
                   send(self(), :launched)
                   :ok
                 end
               )

      events = drain_events([])

      assert info_event?(
               events,
               &(&1 ==
                   "Setup complete. Model: openai / openai:gpt-5 (saved; Lemon checks it on your first message).")
             )

      assert info_event?(events, &String.contains?(&1, "Provider unreachable"))
      assert :launched in events
    end

    test "a rejected credential never claims completion", %{config_path: path} do
      configure_ready_provider(path)
      io = recording_io()

      assert {:error, :verification_failed} =
               Wizard.run_full([], io,
                 config_path: path,
                 non_interactive: true,
                 verifier: fn _ -> {:error, :unauthorized} end
               )

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup did not complete"))
      refute info_event?(events, &String.contains?(&1, "Setup complete."))
    end
  end

  describe "run_full/3 — progress and keychain cost" do
    setup do
      previous = Application.get_env(:lemon_core, LemonCore.Secrets)
      {:ok, _agent} = CountingKeychain.start()

      Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [CountingKeychain])
      System.delete_env("LEMON_SECRETS_MASTER_KEY")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:lemon_core, LemonCore.Secrets, previous),
          else: Application.delete_env(:lemon_core, LemonCore.Secrets)
      end)

      :ok
    end

    @keychain_delay_ms 5_000
    @boundary_budget_ms 1_000

    test "a 5s keychain costs at most two reads and leaves no reported gap above 1s", %{
      config_path: path,
      home: home
    } do
      CountingKeychain.put_key(Base.encode64(:crypto.strong_rand_bytes(32)), [])
      write_codex_cli_login(home)
      CountingKeychain.reset(@keychain_delay_ms)

      # Scripted answers: the detected Codex login, then the offered default model.
      io = timed_io(["1", ""])

      assert :ok =
               Wizard.run([], io,
                 config_path: path,
                 verifier: fn _ -> {:ok, %{}} end,
                 codex_discover: fn _opts -> {:ok, ["gpt-6.1-sol", "gpt-6-sol"]} end,
                 launch: false
               )

      assert CountingKeychain.count() <= 2

      events = drain_events([])
      timeline = timed_timeline(events)
      [{_, :info, first_message} | _] = timeline
      assert first_message == "Starting Lemon setup…"

      assert Enum.count(timeline, fn
               {_, :info, message} -> String.starts_with?(message, "Importing your Codex")
               _ -> false
             end) == 1

      # Obs 1's two reported pauses: the answered Connect-a-model choice to the
      # next visible line, and the import summary to "Verifying…".
      assert boundary_ms(timeline, {:prompt, "Select [default: 1, q to cancel]: "}) <=
               @boundary_budget_ms

      assert boundary_ms(timeline, {:info, "OpenAI Codex onboarding complete."}) <=
               @boundary_budget_ms

      assert info_event?(events, &String.contains?(&1, "Verifying provider configuration"))

      # The discovered model is a real catalog id, so the live check resolves it
      # and this run proves the verified path, not a skipped one.
      assert info_event?(
               events,
               &(&1 ==
                   "Setup complete. Model: openai-codex / openai-codex:gpt-6.1-sol " <>
                     "(verified with OpenAI Codex; no message was sent).")
             )

      refute info_event?(events, &String.contains?(&1, "live check not available"))

      # Any remaining wait is announced: it follows a progress line.
      timeline
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{before_at, kind, before_message}, {after_at, _kind, after_message}] ->
        if after_at - before_at >= @keychain_delay_ms do
          assert kind == :info and progress_line?(before_message),
                 "silent #{after_at - before_at}ms gap between " <>
                   "#{inspect(before_message)} and #{inspect(after_message)}"
        end
      end)
    end
  end

  describe "run_model/3 — readiness exit result" do
    for {state, check_result, expected} <- [
          {:verified, {:ok, %{}}, :ok},
          {:saved, {:error, :unreachable}, :ok},
          {:action_required, {:error, :unauthorized}, {:error, :not_ready}}
        ] do
      test "JSON mode returns #{inspect(expected)} for #{state} readiness", %{config_path: path} do
        configure_ready_provider(path)

        output =
          ExUnit.CaptureIO.capture_io(fn ->
            assert unquote(Macro.escape(expected)) ==
                     Wizard.run_model(["--json"], silent_io(),
                       config_path: path,
                       cwd: Path.dirname(path),
                       verifier: fn _ -> unquote(Macro.escape(check_result)) end
                     )
          end)

        assert %{"state" => unquote(Atom.to_string(state))} = Jason.decode!(output)
      end
    end

    test "offline JSON mode accepts saved atom readiness without a live check", %{
      config_path: path
    } do
      configure_ready_provider(path)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok =
                   Wizard.run_model(["--json", "--offline"], silent_io(),
                     config_path: path,
                     cwd: Path.dirname(path),
                     verifier: fn _ -> flunk("offline readiness must not make a live check") end
                   )
        end)

      assert %{"state" => "saved"} = Jason.decode!(output)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp configure_ready_provider(path) do
    set_master_key_env()
    assert {:ok, _} = Secrets.set("wizard_existing", "sk-wizard-existing")

    File.write!(path, """
    [defaults]
    provider = "openai"
    model = "openai:gpt-5"
    [providers.openai]
    api_key_secret = "wizard_existing"
    """)
  end

  defp set_master_key_env do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
  end

  defp recording_io(prompts \\ []) do
    pid = self()
    prompt_agent = start_agent(prompts)

    %{
      info: fn message -> send(pid, {:info, message}) end,
      error: fn message -> send(pid, {:error, message}) end,
      prompt: fn message ->
        send(pid, {:prompt, message})
        pop_response(prompt_agent)
      end,
      secret: fn message ->
        send(pid, {:secret, message})
        ""
      end
    }
  end

  # Records monotonic timestamps for every user-visible event (including the
  # moment a prompt is answered), so a test can prove no step blocks silently.
  defp timed_io(prompts) do
    pid = self()
    prompt_agent = start_agent(prompts)

    stamp = fn kind, message ->
      send(pid, {:timed, System.monotonic_time(:millisecond), kind, message})
    end

    %{
      info: fn message -> stamp.(:info, message) end,
      error: fn message -> stamp.(:error, message) end,
      prompt: fn message ->
        answer = pop_response(prompt_agent)
        # Stamped after the answer: the clock starts when the user replies.
        stamp.(:prompt, message)
        answer
      end,
      secret: fn _message -> "" end
    }
  end

  defp timed_timeline(events) do
    Enum.flat_map(events, fn
      {:timed, at, kind, message} -> [{at, kind, message}]
      _other -> []
    end)
  end

  # Milliseconds between the named event and the next visible line.
  defp boundary_ms(timeline, {kind, message}) do
    index =
      Enum.find_index(timeline, fn {_at, event_kind, event_message} ->
        event_kind == kind and event_message == message
      end)

    assert is_integer(index), "event #{inspect(message)} never happened"

    {at, _kind, _message} = Enum.at(timeline, index)
    next = Enum.at(timeline, index + 1)
    assert next, "no line followed #{inspect(message)}"
    {next_at, _next_kind, _next_message} = next

    next_at - at
  end

  defp progress_line?(message) do
    String.starts_with?(message, "Starting Lemon setup") or
      String.starts_with?(message, "Checking ") or
      String.starts_with?(message, "Verifying provider configuration") or
      String.starts_with?(message, "Importing your Codex") or
      String.starts_with?(message, "Saving ")
  end

  defp info_messages(events) do
    Enum.flat_map(events, fn
      {:info, message} -> [message]
      _other -> []
    end)
  end

  defp write_codex_cli_login(home) do
    claims = %{
      "exp" => System.system_time(:second) + 3_600,
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => "wizard-account"}
    }

    token = "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"

    auth_path = Path.join([home, ".codex", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))

    File.write!(
      auth_path,
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{
          "access_token" => token,
          "refresh_token" => "wizard-refresh",
          "account_id" => "wizard-account",
          "id_token" => token
        }
      })
    )

    auth_path
  end

  defp info_event?(events, predicate) do
    Enum.any?(events, fn
      {:info, message} -> predicate.(message)
      {:timed, _at, :info, message} -> predicate.(message)
      _other -> false
    end)
  end

  defp error_event?(events, predicate) do
    Enum.any?(events, fn
      {:error, message} -> predicate.(message)
      _other -> false
    end)
  end

  defp prompt_events(events),
    do:
      events
      |> Enum.filter(&match?({:prompt, _}, &1))
      |> Enum.map(fn {:prompt, message} -> message end)

  # Status lines pad their markers to a fixed column; assertions match on
  # squished text so they survive padding changes.
  defp squish(message) when is_binary(message),
    do: message |> String.split() |> Enum.join(" ")

  defp pop_response(agent) do
    Agent.get_and_update(agent, fn
      [next | rest] -> {next, rest}
      [] -> {"", []}
    end)
  end

  defp start_agent(values) do
    start_supervised!(%{id: make_ref(), start: {Agent, :start_link, [fn -> values end]}})
  end

  defp drain_events(acc) do
    receive do
      message -> drain_events([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp file_mode(path) do
    path |> File.stat!() |> Map.get(:mode) |> Bitwise.band(0o777)
  end

  defp unused_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
