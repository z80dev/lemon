Code.require_file(
  Path.expand("../../../../../scripts/support/setup_verification_probe.exs", __DIR__)
)

Code.require_file(
  Path.expand("../../../../../scripts/support/setup_onboarding_probe.exs", __DIR__)
)

defmodule LemonCli.Setup.VerificationWireTest do
  use ExUnit.Case, async: false

  alias LemonAi.Models.Presets
  alias LemonCli.Setup.Verification
  alias LemonCore.Secrets
  alias LemonScripts.SetupOnboardingProbe
  alias LemonScripts.SetupVerificationProbe

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "setup_verification_wire_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    previous =
      Map.new(
        ~w(HOME LEMON_SECRETS_MASTER_KEY LITELLM_API_KEY LITELLM_BASE_URL XAI_API_KEY),
        &{&1, System.get_env(&1)}
      )

    paths = Application.fetch_env(:lemon_core, :paths)
    secrets_config = Application.fetch_env(:lemon_core, Secrets)
    System.put_env("HOME", root)
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))
    Application.put_env(:lemon_core, :paths, home_dir: root)
    Application.put_env(:lemon_core, Secrets, key_providers: [:env])
    clear_secrets()

    on_exit(fn ->
      clear_secrets()

      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      restore_env(:paths, paths)
      restore_env(Secrets, secrets_config)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  for {provider, settings} <- [
        {"ollama", ""},
        {"local-custom",
         "api = \"openai_completions\"\nbase_url = \"http://127.0.0.1:1234/v1\"\nauth = \"none\""}
      ] do
    test "#{provider} passes offline setup verification without credentials", %{root: root} do
      path = Path.join(root, "config.toml")

      File.write!(path, """
      [defaults]
      provider = "#{unquote(provider)}"
      model = "test-model"
      [providers.#{unquote(provider)}]
      #{unquote(settings)}
      """)

      assert {:ok, %{live: :disabled}} =
               Verification.verify_provider(config_path: path, skip_verify: true)
    end
  end

  test "Ollama live verification receives no credential", %{root: root} do
    path = Path.join(root, "config.toml")

    File.write!(path, """
    [defaults]
    provider = "ollama"
    model = "test-model"
    """)

    assert {:ok, %{live: :ok}} =
             Verification.verify_provider(
               config_path: path,
               verification_model: Presets.model(:ollama, "test-model"),
               verifier: fn input ->
                 assert input.provider == "ollama"
                 assert is_nil(input.api_key)
                 {:ok, %{}}
               end
             )
  end

  test "offline setup rejects a cloud provider without credentials", %{root: root} do
    path = Path.join(root, "config.toml")

    File.write!(path, """
    [defaults]
    provider = "ollama_cloud"
    model = "test-model"
    """)

    assert {:error, %{reason: :credential_not_usable}} =
             Verification.verify_provider(config_path: path, skip_verify: true)
  end

  for provider <- [:litellm, :xai], scenario <- [:success, :raw_success] do
    @provider provider
    @scenario scenario
    test "#{provider} #{scenario}: public verification sends only selected access to effective endpoint and scope",
         %{root: root} do
      result = SetupVerificationProbe.run(root, @scenario, @provider)
      assert result.live_ok
      assert result.requests == 1
      assert result.registry_requests == 0
      assert result.configured_requests == 1
      assert result.correct_access
      assert result.correct_scope_header
      assert result.models_get
      assert_clean(result)
    end
  end

  for provider <- [:litellm, :xai], scenario <- [:expired, :unavailable, :encoded] do
    @provider provider
    @scenario scenario
    test "#{provider} #{scenario}: selected login refusal makes no HTTP and is not skipped success",
         %{root: root} do
      result = SetupVerificationProbe.run(root, @scenario, @provider)
      assert result.requests == 0
      assert result.refused
      refute result.success
      assert_clean(result)
    end
  end

  for provider <- [:litellm, :xai] do
    @provider provider
    test "#{provider}: canonical file loading preserves selected authority and configured endpoint",
         %{root: root} do
      result = SetupVerificationProbe.run(root, :success, @provider, :file)
      assert result.live_ok
      assert result.requests == 1
      assert result.configured_requests == 1
      assert result.registry_requests == 0
      assert result.correct_access
      assert result.correct_scope_header
      assert_clean(result)
    end
  end

  test "explicit verification skip preserves offline behavior without HTTP", %{root: root} do
    result = SetupVerificationProbe.run(root, :skip)
    assert result.disabled
    assert result.requests == 0
    assert_clean(result)
  end

  test "legitimate keyless verification reaches configured endpoint without Authorization", %{
    root: root
  } do
    result = SetupVerificationProbe.run(root, :keyless)
    assert result.live_ok
    assert result.configured_requests == 1
    assert result.registry_requests == 0
    assert result.keyless_wire
    assert_clean(result)
  end

  for entry <- [:provider, :wizard] do
    @entry entry
    test "#{entry}: public onboarding caller verifies effective local URL and headers", %{
      root: root
    } do
      result = SetupOnboardingProbe.run(root, @entry)
      assert result.success
      assert result.requests == 1
      assert result.correct_access
      assert result.correct_scope_header
      assert result.models_get
      refute result.event_credential_leak
    end
  end

  test "lemon model's live_verify false remains offline after real onboarding", %{root: root} do
    result = SetupOnboardingProbe.run(root, :provider, false)
    assert result.success
    assert result.requests == 0
    refute result.event_credential_leak
  end

  for scenario <- [
        :literal,
        :qualified,
        :multiple,
        :env,
        :effective,
        :custom,
        :custom_qualified,
        :declared,
        :scoped_native
      ] do
    @scenario scenario
    test "#{scenario}: verification preserves full native colon identity on actual HTTP", %{
      root: root
    } do
      result = SetupVerificationProbe.run_identity(root, @scenario)
      assert result.readiness_complete
      assert result.exact_model_id
      assert result.live_ok
      assert result.requests == 1
      assert result.models_get
      assert result.correct_access
      assert result.correct_scope_header
      refute result.event_credential_leak
    end
  end

  for scenario <- [:foreign, :foreign_alias, :foreign_custom, :ambient_foreign] do
    @scenario scenario
    test "#{scenario}: real foreign qualification is refused before HTTP", %{root: root} do
      result = SetupVerificationProbe.run_identity(root, @scenario)
      assert result.mismatch
      refute result.live_ok
      assert result.requests == 0
      refute result.event_credential_leak
    end
  end

  test "offline verification retains scoped native full IDs without resolving live identity", %{
    root: root
  } do
    result = SetupVerificationProbe.run_identity(root, :scoped_skip)
    assert result.readiness_complete
    assert result.disabled
    assert result.retained_model
    assert result.requests == 0
    refute result.event_credential_leak
  end

  for entry <- [:provider, :wizard], scenario <- [:literal, :qualified, :foreign] do
    @entry entry
    @scenario scenario
    test "#{entry} #{@scenario}: public onboarding retains colon model or refuses foreign override",
         %{root: root} do
      effective_model =
        case @scenario do
          :literal -> "qwen3:32b"
          :qualified -> "openai:qwen3:32b"
          :foreign -> "anthropic:claude-sonnet-4-6"
        end

      opts = [
        provider: "openai",
        model: "gpt-5",
        effective_model: effective_model,
        expected_model: "qwen3:32b",
        native_model: "qwen3:32b"
      ]

      result = SetupOnboardingProbe.run(root, @entry, true, opts)

      if @scenario == :foreign do
        refute result.success
        assert result.verification_failed
        assert result.requests == 0
      else
        assert result.success
        assert result.exact_model_id
        assert result.requests == 1
        assert result.models_get
        assert result.correct_access
        assert result.correct_scope_header
      end

      refute result.event_credential_leak
    end
  end

  defp assert_clean(result) do
    refute result.wrong_principal
    refute result.wire_credential_leak
    refute result.log_credential_leak
    refute result.event_credential_leak
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:lemon_core, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:lemon_core, key)

  defp clear_secrets do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
