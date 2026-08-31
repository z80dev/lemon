defmodule LemonCli.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI
  alias LemonCore.Secrets
  alias LemonCore.Secrets.EnvCatalog

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

    System.put_env("HOME", home)
    System.put_env("LEMON_SECRETS_MASTER_KEY", :crypto.strong_rand_bytes(32) |> Base.encode64())
    System.delete_env("ANTHROPIC_API_KEY")
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("LEMON_DEFAULT_PROVIDER")
    System.delete_env("LEMON_DEFAULT_MODEL")
    clear_secrets_table()

    on_exit(fn ->
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

    assert error =~ "Invalid options:"
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

  test "rejects unknown config options with config usage on stderr" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "validate", "--not-an-option"]) == 2
      end)

    assert error =~ "Invalid options:"
    assert error =~ "Usage: lemon config [validate|show] [options]"
    assert error =~ "--project-dir, -p PATH"
  end

  test "rejects unsupported config positional arguments" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["config", "show", "unexpected"]) == 2
      end)

    assert error =~ "Unsupported arguments: \"show\" \"unexpected\""
    assert error =~ "Usage: lemon config [validate|show] [options]"
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

  describe "setup_required?/0" do
    test "requires setup when no configuration exists" do
      assert CLI.setup_required?()
    end

    test "fails closed when configuration is malformed" do
      config_path = global_config_path()
      File.mkdir_p!(Path.dirname(config_path))
      File.write!(config_path, "[defaults\nprovider = \"openai\"\n")
      assert CLI.setup_required?()
    end

    test "requires setup when the default provider credential is missing" do
      write_openai_config("missing_setup_required_credential")

      assert CLI.setup_required?()
    end

    test "does not require setup with a resolved default provider credential" do
      secret_name = "ready_setup_required_credential"
      write_openai_config(secret_name)
      assert {:ok, _metadata} = Secrets.set(secret_name, "test-provider-credential")

      refute CLI.setup_required?()
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

  defp clear_secrets_table do
    Secrets.table()
    |> LemonCore.Store.list()
    |> Enum.each(fn {key, _} -> LemonCore.Store.delete(Secrets.table(), key) end)
  end
end
