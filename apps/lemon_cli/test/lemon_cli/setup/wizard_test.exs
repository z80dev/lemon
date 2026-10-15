defmodule LemonCli.Setup.WizardTest do
  # async: false because we manipulate Application env, HOME, and the secrets store
  use ExUnit.Case, async: false

  alias LemonCli.Setup.Wizard
  alias LemonCli.Onboarding.Runner
  alias LemonCore.Secrets

  # Minimal IO callbacks stub for testing non-interactive paths
  defp silent_io do
    %{
      info: fn _msg -> :ok end,
      error: fn _msg -> :ok end,
      prompt: fn _msg -> "" end,
      secret: fn _msg -> "" end
    }
  end

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

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      if original_secrets_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_secrets_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

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
        refute info_event?(events, &String.contains?(&1, "To persist"))
      end
    end

    test "interactive invalid profiles and ports re-prompt" do
      io = recording_io(["0", "typo", "999", "runtime_min", "abc", "0", "65536", "5050", "", ""])
      assert :ok = Wizard.run_runtime([], io)
      events = drain_events([])
      assert error_event?(events, &String.contains?(&1, "Invalid profile"))
      assert error_event?(events, &String.contains?(&1, "Invalid port"))
      assert info_event?(events, &String.contains?(&1, "Runtime profile: runtime_min"))
      assert info_event?(events, &String.contains?(&1, "LEMON_CONTROL_PLANE_PORT=5050"))
      assert Enum.count(prompt_events(events), &String.contains?(&1, "Choose profile")) == 4
      assert Enum.count(prompt_events(events), &String.contains?(&1, "control-plane port")) == 4
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
      io = recording_io(["n", "n", "n"])
      assert {:error, :setup_incomplete} = Wizard.run_full([], io, config_path: path)
      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup unfinished — pending steps"))
      refute info_event?(events, &String.contains?(&1, "Setup did not complete"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
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

      assert info_event?(events, &String.contains?(squish(&1), "[pending] provider"))
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
      refute info_event?(events, &String.contains?(&1, "initializing one now"))
      refute info_event?(events, &String.contains?(&1, "Creating minimal config"))
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

      # Scripted answers: decline the optional daily brief and runtime configuration.
      io = recording_io(["n", "n"])

      assert Wizard.run_full([], io, config_path: config_path, verifier: fn _ -> {:ok, %{}} end) ==
               :ok

      events = drain_events([])

      assert info_event?(events, &String.contains?(squish(&1), "[done] provider"))
      assert info_event?(events, &String.contains?(&1, "Provider already configured"))
      assert info_event?(events, &String.contains?(&1, "Setup complete"))

      # Provider onboarding is never asked for again; runtime stays optional.
      assert Enum.any?(prompt_events(events), &String.contains?(&1, "Configure runtime profile"))
      assert Enum.any?(prompt_events(events), &String.contains?(&1, "daily brief"))
      refute File.read!(config_path) =~ "[automation]"

      assert Enum.all?(
               prompt_events(events),
               &(not String.contains?(&1, "Onboard an AI provider"))
             )

      assert info_event?(events, &String.contains?(&1, "Verifying provider"))
      assert info_event?(events, &String.contains?(&1, "lemon doctor"))
      refute info_event?(events, &String.contains?(&1, "lemon setup doctor"))
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

    test "skipped or unavailable live verification never claims setup complete", %{
      config_path: path
    } do
      configure_ready_provider(path)

      for opts <- [
            [skip_verify: true, verifier: fn _ -> flunk("skipped check ran") end],
            [verifier: fn _ -> {:skip, :offline} end]
          ] do
        io = recording_io()
        assert :ok = Wizard.run_full([], io, [config_path: path, non_interactive: true] ++ opts)
        events = drain_events([])
        assert info_event?(events, &String.contains?(&1, "not live-verified"))
        refute info_event?(events, &String.contains?(&1, "Setup complete"))
      end
    end
  end

  describe "run_full/3 — daily brief" do
    test "opting in records the brief time; rerunning does not ask again", %{
      config_path: config_path
    } do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("wizard_openai_key", "sk-wizard-brief")

      File.write!(config_path, """
      [defaults]
        provider = "openai"
        model = "openai:gpt-5"

      [providers.openai]
        api_key_secret = "wizard_openai_key"
      """)

      # yes to the brief, an invalid time, then 7:30; decline runtime configuration.
      io = recording_io(["y", "7am", "7:30", "n"])

      assert Wizard.run_full([], io, config_path: config_path, verifier: fn _ -> {:ok, %{}} end) ==
               :ok

      assert %{"automation" => %{"daily_brief" => "07:30"}} =
               config_path |> File.read!() |> Toml.decode!()

      events = drain_events([])
      assert error_event?(events, &String.contains?(&1, "24-hour time"))

      assert Enum.any?(
               prompt_events(events),
               &String.contains?(&1, "lemon gateway setup telegram")
             )

      assert info_event?(events, &String.contains?(&1, "Daily brief scheduled for 07:30"))

      assert Wizard.run_full([], recording_io(["n"]),
               config_path: config_path,
               verifier: fn _ -> {:ok, %{}} end
             ) == :ok

      events = drain_events([])
      refute Enum.any?(prompt_events(events), &String.contains?(&1, "daily brief"))
      assert info_event?(events, &String.contains?(&1, "Daily brief: scheduled at 07:30"))
    end

    test "non-interactive setup stays off unless --daily-brief is given", %{
      config_path: config_path
    } do
      assert Wizard.run(["--non-interactive", "--config-path", config_path], recording_io()) ==
               {:error, :setup_incomplete}

      refute File.read!(config_path) =~ "daily_brief"

      assert Wizard.run(
               ["--non-interactive", "--config-path", config_path, "--daily-brief", "6:45"],
               recording_io()
             ) == {:error, :setup_incomplete}

      assert %{"automation" => %{"daily_brief" => "06:45"}} =
               config_path |> File.read!() |> Toml.decode!()
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

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "not live-verified"))
      refute info_event?(events, &String.contains?(&1, "Setup complete"))
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
      assert {:ok, _config} = LemonCore.Config.Modular.validate_settings(settings)
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

  defp info_event?(events, predicate) do
    Enum.any?(events, fn
      {:info, message} -> predicate.(message)
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

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
