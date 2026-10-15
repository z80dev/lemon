defmodule LemonCli.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonAi.Models.Presets
  alias LemonCli.CLI
  alias LemonCore.Secrets
  alias LemonCore.Secrets.EnvCatalog
  alias LemonCore.Setup.Readiness

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "lemon_cli_runtime_#{System.unique_integer([:positive])}"
      )

    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)

    original_home = System.get_env("HOME")
    original_master_key = System.get_env("LEMON_SECRETS_MASTER_KEY")
    original_anthropic_api_key = System.get_env("ANTHROPIC_API_KEY")
    original_openai_api_key = System.get_env("OPENAI_API_KEY")
    original_default_provider = System.get_env("LEMON_DEFAULT_PROVIDER")
    original_default_model = System.get_env("LEMON_DEFAULT_MODEL")
    original_secrets_config = Application.get_env(:lemon_core, LemonCore.Secrets)
    Application.put_env(:lemon_core, LemonCore.Secrets, key_providers: [:env, :file])

    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("LEMON_DEFAULT_PROVIDER")
    System.delete_env("LEMON_DEFAULT_MODEL")
    clear_secrets_table()

    on_exit(fn ->
      if original_secrets_config,
        do: Application.put_env(:lemon_core, LemonCore.Secrets, original_secrets_config),
        else: Application.delete_env(:lemon_core, LemonCore.Secrets)

      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")

      if original_master_key,
        do: System.put_env("LEMON_SECRETS_MASTER_KEY", original_master_key),
        else: System.delete_env("LEMON_SECRETS_MASTER_KEY")

      restore_env("ANTHROPIC_API_KEY", original_anthropic_api_key)
      restore_env("OPENAI_API_KEY", original_openai_api_key)
      restore_env("LEMON_DEFAULT_PROVIDER", original_default_provider)
      restore_env("LEMON_DEFAULT_MODEL", original_default_model)

      clear_secrets_table()
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "invalid TOML fails validation and names the file", %{tmp_dir: tmp_dir} do
    path = LemonCore.Config.Modular.global_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "api_key = \n")

    output =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert CLI.run(["config", "validate", "--project-dir", tmp_dir]) == 1
        end)
      end)

    assert output =~ path
    assert output =~ "invalid TOML"
    assert CLI.setup_required?()
  end

  test "removed settings produce doctor failures and actionable show errors", %{tmp_dir: tmp_dir} do
    path = LemonCore.Config.Modular.global_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[runtime.cli]\nenabled = true\n")
    checks = LemonCore.Doctor.checks(project_dir: tmp_dir)
    assert Enum.any?(checks, &(&1.status == :fail))

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "show", "--project-dir", tmp_dir]) == 1
      end)

    assert output =~ "lemon config migrate"
  end

  test "migration explains invalid TOML without internal tuples", %{tmp_dir: tmp_dir} do
    path = LemonCore.Config.Modular.global_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "value = \n")

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "migrate", "--project-dir", tmp_dir]) == 1
      end)

    assert output =~ path
    assert output =~ "invalid TOML"
    assert output =~ "lemon config migrate"
    refute output =~ "{:"
  end

  test "summary distinguishes unset values from false", %{tmp_dir: tmp_dir} do
    output =
      capture_io(fn ->
        assert CLI.run(["config", "show", "--project-dir", tmp_dir]) == 0
      end)

    assert output =~ "Auto resume: false"
    assert output =~ "File: (not set)"
  end

  test "CLI and Mix summaries agree and identify active environment overrides", %{
    tmp_dir: tmp_dir
  } do
    System.put_env("LEMON_DEFAULT_MODEL", "model-from-environment")
    path = LemonCore.Config.Modular.global_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[defaults]\nmodel = \"model-from-file\"\n")

    cli = capture_io(fn -> assert CLI.run(["config", "show", "--project-dir", tmp_dir]) == 0 end)
    mix = capture_io(fn -> Mix.Tasks.Lemon.Config.run(["show", "--project-dir", tmp_dir]) end)

    assert cli == mix
    assert cli =~ "Default model: model-from-environment (from LEMON_DEFAULT_MODEL)"
    assert cli =~ "Auto resume: false"
    assert cli =~ "Debug: false"
    assert cli =~ "File: (not set)"
    refute cli =~ "model-from-file"
  end

  test "show rejects unknown thinking choices rather than claiming a default", %{tmp_dir: tmp_dir} do
    path = LemonCore.Config.Modular.global_path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "[defaults]\nthinking_level = \"private-unknown-choice\"\n")

    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "show", "--project-dir", tmp_dir]) == 1
      end)

    assert output =~ path
    assert output =~ "defaults.thinking_level"
    refute output =~ "private-unknown-choice"
  end

  test "unknown options point to command help" do
    output =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "validate", "--foo"]) == 2
      end)

    assert output =~ "unknown option --foo (see lemon config --help)"
    refute output =~ "{"
  end

  test "dispatches setup without a Mix shell" do
    output =
      capture_io(fn ->
        assert CLI.run(["setup", "gateway", "--non-interactive"]) == 0
      end)

    assert output =~ "Available gateway transports"
  end

  test "forwards model provider arguments to onboarding", %{tmp_dir: tmp_dir} do
    config_path = Path.join(tmp_dir, "config.toml")

    output =
      capture_io(fn ->
        assert CLI.run([
                 "model",
                 "--non-interactive",
                 "--provider",
                 "openai",
                 "--token",
                 "runtime-cli-token",
                 "--secret-name",
                 "runtime_cli_test_token",
                 "--set-default",
                 "--model",
                 "gpt-5",
                 "--config-path",
                 config_path
               ]) == 0
      end)

    assert output =~ "OpenAI onboarding complete."
    {:ok, secret} = Secrets.get("runtime_cli_test_token", prefer_env: false, env_fallback: false)
    assert secret == "runtime-cli-token"

    {:ok, config} = Toml.decode_file(config_path)
    assert get_in(config, ["providers", "openai", "api_key_secret"]) == "runtime_cli_test_token"
    assert get_in(config, ["defaults", "provider"]) == "openai"
    assert get_in(config, ["defaults", "model"]) == "openai:gpt-5"
  end

  test "explicit CLI import stores encrypted OAuth without HTTP or source writes", %{
    tmp_dir: tmp_dir
  } do
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})
    Req.Test.stub(__MODULE__, fn _ -> flunk("CLI import must not call HTTP") end)
    codex_home = System.get_env("CODEX_HOME")
    System.delete_env("CODEX_HOME")

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
      restore_env("CODEX_HOME", codex_home)
    end)

    claims = %{
      "exp" => System.system_time(:second) + 3_600,
      "https://api.openai.com/auth" => %{"chatgpt_account_id" => "cli-import-account"}
    }

    token = "header." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".signature"

    source =
      Jason.encode!(%{
        "auth_mode" => "chatgpt",
        "tokens" => %{
          "access_token" => token,
          "refresh_token" => "cli-import-refresh",
          "account_id" => "cli-import-account",
          "id_token" => token
        }
      })

    auth_path = Path.join([System.fetch_env!("HOME"), ".codex", "auth.json"])
    File.mkdir_p!(Path.dirname(auth_path))
    File.write!(auth_path, source)

    for auth <- ["codex-cli", "codex_cli"] do
      config_path = Path.join(tmp_dir, "#{auth}.toml")

      File.write!(config_path, """
      [providers.openai-codex]
      auth_source = "api_key"
      api_key_secret = "old-secret"
      """)

      path_args = if auth == "codex_cli", do: ["--codex-auth-path", auth_path], else: []

      output =
        capture_io(fn ->
          assert CLI.run(
                   [
                     "model",
                     "--provider",
                     "openai-codex",
                     "--auth",
                     auth,
                     "--non-interactive",
                     "--config-path",
                     config_path
                   ] ++ path_args
                 ) == 0
        end)

      assert output =~ "OpenAI Codex onboarding complete."
      refute output =~ "cli-import-refresh"

      assert {:ok, stored} =
               Secrets.get("llm_openai_codex_api_key", prefer_env: false, env_fallback: false)

      assert {:ok, secret} = LemonAi.Auth.OpenAICodexOAuth.decode_secret(stored)
      assert secret["refresh_token"] == "cli-import-refresh"
      assert secret["access_token"] == token
      records = LemonCore.Store.list(Secrets.table()) |> inspect()
      refute records =~ "cli-import-refresh"
      refute records =~ token
      assert records =~ "ciphertext"
      assert {:ok, config} = Toml.decode_file(config_path)
      provider = config["providers"]["openai-codex"]
      assert provider["auth_source"] == "oauth"
      assert provider["oauth_secret"] == "llm_openai_codex_api_key"
      refute Map.has_key?(provider, "api_key_secret")
      refute File.read!(config_path) =~ "cli-import-refresh"
      assert File.read!(auth_path) == source
    end
  end

  test "reports unknown commands as a user-facing usage error" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["not-a-command"]) == 2
      end)

    assert error =~ "Unknown command: not-a-command"
    assert error =~ "Usage: lemon <command> [options]"
    assert error =~ "Run `lemon <command> --help` for command options."
  end

  test "routes empty-argument usage to stderr" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run([]) == 2
      end)

    assert error =~ "Usage: lemon <command> [options]"
    assert error =~ "Run `lemon <command> --help` for command options."
  end

  test "rejects unknown doctor options before running diagnostics" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["doctor", "--not-an-option"]) == 2
      end)

    assert error =~ "unknown option"
    assert error =~ "Usage: lemon doctor [options]"
    assert error =~ "--bundle [PATH]"
    refute error =~ "Diagnostics failed:"
  end

  test "rejects unsupported doctor positional arguments" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["doctor", "unexpected"]) == 2
      end)

    assert error =~ "Unsupported arguments: \"unexpected\""
    assert error =~ "Usage: lemon doctor [options]"
  end

  test "config migrate rewrites a legacy [agent] config and is idempotent", %{tmp_dir: tmp_dir} do
    config_path = Path.join([tmp_dir, "home", ".lemon", "config.toml"])
    File.mkdir_p!(Path.dirname(config_path))
    legacy = "[agent]\ndefault_provider = \"openai\"\ndefault_model = \"openai:gpt-5.1\"\n"
    File.write!(config_path, legacy)

    output =
      capture_io(fn ->
        assert CLI.run(["config", "migrate", "--project-dir", tmp_dir]) == 0
      end)

    assert output =~ "Migrated #{config_path}"
    assert output =~ "agent.default_provider → defaults.provider"
    assert [backup] = Path.wildcard(config_path <> ".bak-*")
    assert File.read!(backup) == legacy

    assert Toml.decode_file!(config_path) == %{
             "defaults" => %{"provider" => "openai", "model" => "openai:gpt-5.1"}
           }

    again =
      capture_io(fn ->
        assert CLI.run(["config", "migrate", "--project-dir", tmp_dir]) == 0
      end)

    assert again =~ "already uses the current schema"
    assert [^backup] = Path.wildcard(config_path <> ".bak-*")
  end

  test "rejects unknown config options with config usage on stderr" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "validate", "--not-an-option"]) == 2
      end)

    assert error =~ "unknown option"
    assert error =~ "Usage: lemon config [validate|show|migrate] [options]"
    assert error =~ "--project-dir, -p PATH"
  end

  test "rejects unsupported config positional arguments" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "show", "unexpected"]) == 2
      end)

    assert error =~ "Unsupported arguments: \"show\" \"unexpected\""
    assert error =~ "Usage: lemon config [validate|show|migrate] [options]"
  end

  test "packaged secrets check uses the shared ordered catalog" do
    with_clean_catalog_env(fn ->
      output =
        capture_io(fn ->
          assert CLI.run(["secrets", "check"]) == 0
        end)

      assert output =~
               "0 from store, 0 from external sources, 0 from env, #{length(EnvCatalog.names())} missing"

      assert output =~ "ANTHROPIC_API_KEY"
      assert output =~ "MARKET_INTEL_ANTHROPIC_KEY"
    end)
  end

  test "packaged secrets import-env uses the shared catalog" do
    with_clean_catalog_env(fn ->
      System.put_env("GITHUB_TOKEN", "ghp_catalog_test")

      output =
        capture_io(fn ->
          assert CLI.run(["secrets", "import-env", "--dry-run"]) == 0
        end)

      assert output =~ "GITHUB_TOKEN: would import"

      assert output =~
               "1 imported, 0 already in store, #{length(EnvCatalog.names()) - 1} not in env"

      assert {:error, :not_found} = Secrets.get("GITHUB_TOKEN")
    end)
  end

  test "secrets rotate-key previews, refuses a wrong token, then rotates the key file",
       %{tmp_dir: tmp_dir} do
    # The key comes from the private key file under the isolated HOME, never
    # the developer's Keychain or a running runtime.
    System.delete_env("LEMON_SECRETS_MASTER_KEY")
    # Stub the directory flush so the key-file path also runs on macOS, which
    # has no synchronous one (that refusal is covered in KeyRotationTest).
    Application.put_env(:lemon_core, LemonCore.Secrets,
      key_providers: [:env, :file],
      directory_sync: fn _dir -> :ok end
    )

    key_file = Path.join([tmp_dir, "home", ".lemon", "secrets_master_key"])
    assert {:ok, %{source: :file}} = LemonCore.Secrets.MasterKey.init(target: :file)
    original_key = File.read!(key_file)
    original_port = System.get_env("LEMON_CONTROL_PLANE_PORT")
    System.put_env("LEMON_CONTROL_PLANE_PORT", Integer.to_string(closed_port()))

    try do
      assert {:ok, _} = Secrets.set("ROTATE_ME", "rotate-value")

      preview = capture_io(fn -> assert CLI.run(["secrets", "rotate-key"]) == 0 end)
      assert preview =~ "secrets to re-encrypt: 1"
      assert preview =~ "key source: file (#{key_file})"
      [_, token] = Regex.run(~r/confirmation token: ([0-9a-f]{64})/, preview)

      mismatch =
        capture_io(:stderr, fn ->
          assert CLI.run(["secrets", "rotate-key", "--confirm", String.duplicate("0", 64)]) == 1
        end)

      assert mismatch =~ "does not match"
      assert File.read!(key_file) == original_key

      applied =
        capture_io(fn -> assert CLI.run(["secrets", "rotate-key", "--confirm", token]) == 0 end)

      assert applied =~ "1 secrets re-encrypted"
      refute File.read!(key_file) == original_key
      assert {:ok, "rotate-value"} = Secrets.get("ROTATE_ME")
      refute preview <> applied <> mismatch =~ "rotate-value"
    after
      restore_env("LEMON_CONTROL_PLANE_PORT", original_port)
    end
  end

  test "secrets rotate-key rejects unexpected arguments" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["secrets", "rotate-key", "extra"]) == 2
      end)

    assert error =~ "Usage: lemon secrets rotate-key [--confirm <token>]"
  end

  describe "setup_required?/0" do
    test "requires setup when no configuration exists" do
      assert CLI.setup_required?()
    end

    test "requires setup for malformed configuration" do
      config_path = global_config_path()
      File.mkdir_p!(Path.dirname(config_path))
      File.write!(config_path, "[defaults\nprovider = \"openai\"\n")
      assert CLI.setup_required?()
    end

    test "requires setup when provider credentials are missing" do
      write_openai_config("missing_setup_required_credential")

      assert CLI.setup_required?()
    end

    test "requires setup for a scaffold without a provider" do
      config_path = global_config_path()
      File.mkdir_p!(Path.dirname(config_path))
      File.write!(config_path, "[defaults]\n")

      assert CLI.setup_required?()
    end

    test "does not require setup for a keyless local provider" do
      config_path = global_config_path()
      File.mkdir_p!(Path.dirname(config_path))
      File.write!(config_path, "[defaults]\nprovider = \"ollama\"\nmodel = \"qwen3\"\n")

      refute CLI.setup_required?()
    end

    test "core keyless presets agree with the model catalog" do
      for preset <- Presets.all(),
          name <- [Atom.to_string(preset.id) | preset.aliases] do
        assert Readiness.keyless_provider?(name, %{}) == preset.keyless
      end
    end

    test "does not require setup with a resolved default provider credential" do
      secret_name = "ready_setup_required_credential"
      write_openai_config(secret_name)
      assert {:ok, _metadata} = Secrets.set(secret_name, "test-provider-credential")

      refute CLI.setup_required?()
    end

    test "setup --if-required is a no-op once setup is complete" do
      secret_name = "if_required_ready_credential"
      write_openai_config(secret_name)
      assert {:ok, _metadata} = Secrets.set(secret_name, "test-provider-credential")

      output = capture_io(fn -> assert CLI.run(["setup", "--if-required"]) == 0 end)

      refute output =~ "Setup is required"
      refute output =~ "Welcome to Lemon setup!"
    end
  end

  describe "launcher-aware dispatch" do
    setup do
      previous = System.get_env("LEMON_CLI_LAUNCHER")

      on_exit(fn -> restore_env("LEMON_CLI_LAUNCHER", previous) end)
    end

    test "packaged runtime commands return usage errors through the CLI boundary" do
      System.put_env("LEMON_CLI_LAUNCHER", "release")

      capture_io(:stderr, fn ->
        assert CLI.run(["models", "--limit", "-1"]) == 2
        assert CLI.run(["usage", "--unexpected"]) == 2
      end)
    end

    test "source checkouts refuse release-VM commands" do
      System.put_env("LEMON_CLI_LAUNCHER", "source")

      error = capture_io(:stderr, fn -> assert CLI.run(["eval", "1 + 1"]) == 2 end)

      assert error =~ "`lemon eval` is available only in a packaged install."
    end

    test "lifecycle commands belong to the launcher script, but their help is shared" do
      System.put_env("LEMON_CLI_LAUNCHER", "release")

      error = capture_io(:stderr, fn -> assert CLI.run(["daemon"]) == 2 end)
      assert error =~ "`lemon daemon` is handled by the lemon launcher script."

      help = capture_io(fn -> assert CLI.run(["help", "daemon"]) == 0 end)
      assert help =~ "Usage: lemon daemon [runtime options]"
    end

    test "version prints the current Lemon version" do
      output = capture_io(fn -> assert CLI.run(["version"]) == 0 end)

      assert output == LemonCore.Update.Version.current() <> "\n"
    end
  end

  defp global_config_path do
    Path.join([System.fetch_env!("HOME"), ".lemon", "config.toml"])
  end

  defp write_openai_config(secret_name) do
    config_path = global_config_path()
    File.mkdir_p!(Path.dirname(config_path))

    File.write!(
      config_path,
      """
      [defaults]
      provider = "openai"
      model = "openai:gpt-5"

      [providers.openai]
      api_key_secret = "#{secret_name}"
      """
    )
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp with_clean_catalog_env(fun) do
    snapshot = Map.new(EnvCatalog.names(), &{&1, System.get_env(&1)})
    Enum.each(EnvCatalog.names(), &System.delete_env/1)

    try do
      fun.()
    after
      Enum.each(snapshot, fn {name, value} -> restore_env(name, value) end)
    end
  end

  # A port with no listener, so the runtime health probe reports "not running".
  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
