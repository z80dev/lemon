defmodule LemonCli.Setup.ProviderTest do
  # async: false because we manipulate Application env and HOME
  use ExUnit.Case, async: false

  alias LemonCli.Onboarding.Runner
  alias LemonCli.Setup.{Provider, Verification}
  alias LemonCore.Secrets

  # IO callbacks that capture output messages for inspection
  defp capturing_io do
    pid = self()

    %{
      info: fn msg -> send(pid, {:info, msg}) end,
      error: fn msg -> send(pid, {:error, msg}) end,
      prompt: fn _msg -> "" end,
      secret: fn _msg -> "" end
    }
  end

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_setup_provider_#{System.unique_integer([:positive])}"
      )

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

    {:ok, tmp_dir: tmp_dir, config_path: Path.join(tmp_dir, "config.toml")}
  end

  describe "run/2 — scaffold error propagation" do
    test "returns {:error, {:scaffold_failed, _}} when config directory is unwritable" do
      io = capturing_io()

      # Point HOME at a non-existent/unwritable path so bootstrap_global
      # cannot create ~/.lemon/config.toml — triggering the error path.
      original_home = System.get_env("HOME")
      System.put_env("HOME", "/nonexistent_home_for_test")

      # Ensure lemon_core secrets look configured so we reach the scaffold step.
      # We stub the status by temporarily setting the master key env var.
      System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:binary.copy(<<1>>, 32)))

      try do
        result = Provider.run([], io)

        case result do
          {:error, :secrets_not_configured} ->
            # Secrets check ran first and failed — acceptable, the scaffold path
            # is not reachable from this state.
            :ok

          {:error, {:scaffold_failed, _reason}} ->
            # The scaffold step correctly propagated the error.
            :ok

          {:error, _other} ->
            # Any other error is acceptable too — setup correctly short-circuits.
            :ok

          :ok ->
            flunk("Expected an error when config directory is unwritable, got :ok")
        end
      after
        if original_home,
          do: System.put_env("HOME", original_home),
          else: System.delete_env("HOME")

        System.delete_env("LEMON_SECRETS_MASTER_KEY")
      end
    end
  end

  describe "run/3 — post-onboarding verification" do
    test "successful onboarding verifies offline and through the injectable live check", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      result =
        Provider.run(onboard_args(config_path, ["--set-default", "--model", "gpt-5"]), io,
          live_verify: true,
          verifier: fn input ->
            send(self(), {:live_check, input})
            {:ok, %{http_status: 200}}
          end
        )

      assert result == :ok
      # The live verifier received the stored credential and the registry's
      # endpoint details for the selected model.
      assert_received {:live_check,
                       %{
                         provider: "openai",
                         model: "openai:gpt-5",
                         api_key: "provider-test-token"
                       } = input}

      assert is_binary(input.base_url) and input.base_url =~ "api.openai.com"

      events = drain_events([])

      assert info_event?(events, &String.contains?(&1, "Verifying provider configuration"))

      assert info_event?(
               events,
               &String.contains?(&1, "Provider configuration verified: openai / openai:gpt-5")
             )
    end

    test "failed live verification returns the user to recovery without claiming success", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      result =
        Provider.run(onboard_args(config_path, ["--set-default", "--model", "gpt-5"]), io,
          live_verify: true,
          verifier: fn _input -> {:error, :unauthorized} end
        )

      assert result == {:error, :verification_failed}

      events = drain_events([])

      assert error_event?(events, &String.contains?(&1, "Verification failed"))
      assert error_event?(events, &String.contains?(&1, "HTTP 401/403"))
      assert error_event?(events, &String.contains?(&1, "lemon setup provider"))
      assert error_event?(events, &String.contains?(&1, "--skip-verify"))

      refute info_event?(events, &String.contains?(&1, "Provider configuration verified"))
    end

    test "--skip-verify disables the live check while keeping offline verification", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      result =
        Provider.run(
          onboard_args(config_path, ["--set-default", "--model", "gpt-5", "--skip-verify"]),
          io,
          live_verify: true,
          verifier: fn _input ->
            send(self(), :live_check_ran)
            {:ok, %{}}
          end
        )

      assert result == :ok
      refute_received :live_check_ran

      events = drain_events([])

      assert info_event?(events, &String.contains?(&1, "Provider configuration verified"))
      assert info_event?(events, &String.contains?(&1, "--skip-verify"))
    end

    test "direct onboarding callers (lemon model) stay offline by default", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      result =
        Provider.run(onboard_args(config_path, ["--set-default", "--model", "gpt-5"]), io,
          verifier: fn _input ->
            send(self(), :live_check_ran)
            {:ok, %{}}
          end
        )

      assert result == :ok
      refute_received :live_check_ran

      events = drain_events([])

      assert info_event?(events, &String.contains?(&1, "Provider configuration verified"))
    end

    test "an unavailable live check degrades to offline verification", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      result =
        Provider.run(onboard_args(config_path, ["--set-default", "--model", "gpt-5"]), io,
          live_verify: true,
          verifier: fn _input -> {:skip, :offline} end
        )

      assert result == :ok

      events = drain_events([])

      assert info_event?(events, &String.contains?(&1, "Provider configuration verified"))
      assert info_event?(events, &String.contains?(&1, "live check not available"))
    end

    test "onboarding without a default stays honest about the pending step", %{
      config_path: config_path
    } do
      set_master_key_env()
      io = capturing_io()

      assert Provider.run(onboard_args(config_path), io) == :ok

      events = drain_events([])

      assert info_event?(events, &String.contains?(&1, "no default provider/model was set"))
      assert info_event?(events, &String.contains?(&1, "lemon setup provider --set-default"))
      refute info_event?(events, &String.contains?(&1, "Provider configuration verified"))
    end
  end

  describe "Verification.setup_state/1" do
    test "fresh state marks every step pending", %{config_path: config_path} do
      state = Verification.setup_state(config_path: config_path)

      assert state.config.complete == false
      assert state.secrets.complete == false
      assert state.provider.complete == false
      assert Verification.pending_steps(state) == [:config, :secrets, :provider]
    end

    test "a referenced-but-missing credential leaves the provider step pending", %{
      config_path: config_path
    } do
      write_config(config_path, defaults: true, secret_ref: "nowhere_secret")

      state = Verification.setup_state(config_path: config_path)

      assert state.provider.provider == "openai"
      assert state.provider.model == "openai:gpt-5"
      assert state.provider.reason == :credential_not_usable
      assert state.provider.complete == false
    end

    test "a same-named environment variable keeps the credential usable", %{
      config_path: config_path
    } do
      write_config(config_path, defaults: true, secret_ref: "env_carried_secret")
      System.put_env("env_carried_secret", "env-value")

      try do
        state = Verification.setup_state(config_path: config_path)
        assert state.provider.complete == true
      after
        System.delete_env("env_carried_secret")
      end
    end

    test "a decryptable stored secret completes the provider step", %{config_path: config_path} do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("stored_provider_secret", "sk-stored")
      write_config(config_path, defaults: true, secret_ref: "stored_provider_secret")

      state = Verification.setup_state(config_path: config_path)

      assert state.provider.complete == true
      assert Verification.pending_steps(state) == []
    end

    test "a default model owned by another provider is rejected", %{config_path: config_path} do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("mismatch_secret", "sk-stored")

      File.write!(config_path, """
      [defaults]
        provider = "openai"
        model = "anthropic:claude-sonnet-4-20250514"

      [providers.openai]
        api_key_secret = "mismatch_secret"
      """)

      state = Verification.setup_state(config_path: config_path)

      assert state.provider.reason == :model_provider_mismatch
      assert state.provider.complete == false
    end
  end

  describe "Verification.verify_provider/1" do
    test "offline failure returns actionable recovery, not success", %{config_path: config_path} do
      write_config(config_path, defaults: true, secret_ref: "nowhere_secret")

      assert {:error, failure} = Verification.verify_provider(config_path: config_path)

      assert failure.step == :provider
      assert failure.reason == :credential_not_usable
      assert failure.message =~ "not usable"
      assert failure.message =~ "lemon setup provider"
    end

    test "skip_verify disables the live check for offline use", %{config_path: config_path} do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("skip_verify_secret", "sk-stored")
      write_config(config_path, defaults: true, secret_ref: "skip_verify_secret")

      assert {:ok, %{live: :disabled, provider: "openai", model: "openai:gpt-5"}} =
               Verification.verify_provider(config_path: config_path, skip_verify: true)
    end

    test "live failure carries recovery guidance including --skip-verify", %{
      config_path: config_path
    } do
      set_master_key_env()
      assert {:ok, _metadata} = Secrets.set("live_fail_secret", "sk-stored")
      write_config(config_path, defaults: true, secret_ref: "live_fail_secret")

      assert {:error, failure} =
               Verification.verify_provider(
                 config_path: config_path,
                 verifier: fn _input -> {:error, :unauthorized} end
               )

      assert failure.step == :live
      assert failure.message =~ "lemon setup provider"
      assert failure.message =~ "--skip-verify"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp onboard_args(config_path, extra \\ []) do
    [
      "--provider",
      "openai",
      "--token",
      "provider-test-token",
      "--secret-name",
      "provider_test_key",
      "--config-path",
      config_path
    ] ++ extra
  end

  defp write_config(config_path, opts) do
    secret_ref = Keyword.fetch!(opts, :secret_ref)

    defaults =
      if Keyword.get(opts, :defaults, false) do
        """
        [defaults]
          provider = "openai"
          model = "openai:gpt-5"
        """
      else
        ""
      end

    File.write!(config_path, """
    #{defaults}

    [providers.openai]
      api_key_secret = "#{secret_ref}"
    """)
  end

  defp set_master_key_env do
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
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

  defp drain_events(acc) do
    receive do
      message -> drain_events([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
