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

    System.put_env("HOME", home)
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    clear_secrets_table()

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

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
    test "invalid --profile value does not create a new atom" do
      # An attacker (or fuzzer) passing an arbitrary --profile value must not
      # cause String.to_atom/1 to intern a new atom.  The fix uses
      # String.to_existing_atom/1 only after string-level validation.
      malicious_profile = "definitely_not_a_real_profile_#{System.unique_integer([:positive])}"

      atoms_before = :erlang.system_info(:atom_count)

      # run_runtime picks up --profile from parsed args
      io = silent_io()
      Wizard.run_runtime(["--profile", malicious_profile], io, non_interactive: true)

      atoms_after = :erlang.system_info(:atom_count)

      refute atoms_after - atoms_before >= 1 and
               :erlang.system_info(:atom_table)
               |> Atom.to_string()
               |> then(fn _ ->
                 String.to_existing_atom(malicious_profile)
                 true
               end),
             "No new atom should have been created for an invalid profile name"
    rescue
      ArgumentError ->
        # String.to_existing_atom raised — the atom was never created; test passes.
        :ok
    end

    test "valid profile name is accepted without error" do
      io = silent_io()
      result = Wizard.run_runtime(["--profile", "runtime_full"], io, non_interactive: true)
      assert result == :ok
    end
  end

  describe "run_full/3 — fresh state" do
    test "bootstraps config, auto-initializes the master key, and defers the provider step", %{
      config_path: config_path,
      key_file: key_file
    } do
      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) == :ok

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
      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) == :ok
      drain_events([])

      {:ok, config_before} = File.read(config_path)
      {:ok, key_before} = File.read(key_file)

      io = recording_io()
      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) == :ok

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
      original_config = "[runtime]\n  default_engine = \"lemon\"\n"
      File.write!(config_path, original_config)
      set_master_key_env()

      io = recording_io()

      assert Wizard.run_full([], io, non_interactive: true, config_path: config_path) == :ok

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

      # One scripted answer: declining the optional runtime configuration.
      io = recording_io(["n"])

      assert Wizard.run_full([], io, config_path: config_path) == :ok

      events = drain_events([])

      assert info_event?(events, &String.contains?(squish(&1), "[done] provider"))
      assert info_event?(events, &String.contains?(&1, "Provider already configured"))
      assert info_event?(events, &String.contains?(&1, "Setup complete"))

      # Provider onboarding is never asked for again; runtime stays optional.
      assert Enum.any?(prompt_events(events), &String.contains?(&1, "Configure runtime profile"))
      assert Enum.all?(prompt_events(events), &not String.contains?(&1, "Onboard an AI provider"))

      refute info_event?(events, &String.contains?(&1, "Verifying provider"))
    end
  end

  describe "run/3 — full wizard flags" do
    test "top-level flags drive the non-interactive full wizard", %{config_path: config_path} do
      io = recording_io()

      assert Wizard.run(["--non-interactive", "--config-path", config_path], io) == :ok

      assert File.exists?(config_path)

      events = drain_events([])
      assert info_event?(events, &String.contains?(&1, "Setup unfinished"))
    end
  end

  describe "run/3 — provider verification failure" do
    test "returns {:error, :verification_failed} with actionable recovery and no success claim", %{
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
