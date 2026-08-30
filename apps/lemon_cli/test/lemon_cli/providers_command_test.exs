defmodule LemonCli.ProvidersCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  @env_keys ~w(HOME OPENAI_API_KEY LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL)

  setup do
    saved_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    Enum.each(@env_keys, &System.delete_env/1)

    root =
      Path.join(
        System.tmp_dir!(),
        "providers_command_test_#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")
    project = Path.join(root, "project")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))
    System.put_env("HOME", home)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      File.rm_rf!(root)
    end)

    %{
      project: project,
      project_config: Path.join(project, ".lemon/config.toml"),
      global_config: Path.join(home, ".lemon/config.toml")
    }
  end

  test "status emits stable redacted JSON", ctx do
    File.write!(ctx.project_config, """
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"
    """)

    System.put_env("OPENAI_API_KEY", "private-openai-value")

    output =
      capture_io(fn ->
        assert CLI.run(["providers", "status", "--project-dir", ctx.project, "--json"]) == 0
      end)

    assert {:ok, %{"ok" => true, "result" => result}} = Jason.decode(output)
    assert result["defaultProvider"] == "openai"
    assert result["readyCount"] >= 1
    assert result["routingConfig"]["cleanup"]["includesCredentialReferences"] == false
    refute output =~ "private-openai-value"
    refute output =~ "OPENAI_API_KEY"
  end

  test "fallback edits preserve config and require confirmation to remove", ctx do
    File.write!(ctx.global_config, "# operator comment\n")

    output =
      capture_io(fn ->
        assert CLI.run([
                 "providers",
                 "fallback",
                 "add",
                 "zai",
                 "--config-path",
                 ctx.global_config
               ]) == 0
      end)

    assert output =~ "Provider configuration applied: fallback.add"
    assert File.read!(ctx.global_config) =~ "# operator comment"
    assert File.read!(ctx.global_config) =~ "zai"

    error =
      capture_io(:stderr, fn ->
        assert CLI.run([
                 "providers",
                 "fallback",
                 "remove",
                 "zai",
                 "--config-path",
                 ctx.global_config
               ]) == 1
      end)

    assert error =~ "confirmation_required"
    assert File.read!(ctx.global_config) =~ "zai"

    capture_io(fn ->
      assert CLI.run([
               "providers",
               "fallback",
               "remove",
               "zai",
               "--confirm",
               "zai",
               "--config-path",
               ctx.global_config
             ]) == 0
    end)

    {:ok, decoded} = Toml.decode_file(ctx.global_config)
    assert get_in(decoded, ["runtime", "provider_routing", "fallback_providers"]) == []
  end

  test "pool and credential commands return counts but never references", ctx do
    pool_output =
      capture_io(fn ->
        assert CLI.run([
                 "providers",
                 "pool",
                 "set",
                 "burst",
                 "--provider",
                 "openai",
                 "--provider",
                 "zai",
                 "--strategy",
                 "round_robin",
                 "--activate",
                 "--config-path",
                 ctx.global_config
               ]) == 0
      end)

    assert pool_output =~ "Pool burst: strategy=round_robin"
    assert pool_output =~ "providers=openai,zai"

    credential_output =
      capture_io(fn ->
        assert CLI.run([
                 "providers",
                 "pool",
                 "credential",
                 "add",
                 "burst",
                 "openai",
                 "secret:private_pool_reference",
                 "--config-path",
                 ctx.global_config
               ]) == 0
      end)

    assert credential_output =~ "credential_refs=1"
    refute credential_output =~ "private_pool_reference"
    assert File.read!(ctx.global_config) =~ "secret:private_pool_reference"
  end

  test "invalid JSON invocation returns one JSON error and exit 2" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["providers", "unknown", "--json"]) == 2
      end)

    assert {:ok, %{"ok" => false, "error" => %{"code" => "invalid_arguments"}}} =
             Jason.decode(error)
  end

  test "providers help exits successfully without starting a mutation" do
    output =
      capture_io(fn ->
        assert CLI.run(["providers", "--help"]) == 0
      end)

    assert output =~ "lemon providers fallback"
    assert output =~ "secret:NAME"
  end
end
