defmodule LemonCli.MigrateCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.{CLI, MigrateCommand}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon_migrate_cli_#{System.unique_integer([:positive])}")
    source = Path.join(root, "hermes")
    target = Path.join(root, "lemon")

    original_home = System.get_env("HOME")
    System.put_env("HOME", root)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
    end)

    File.mkdir_p!(source)
    File.write!(Path.join(source, "SOUL.md"), "Hermes persona\n")
    on_exit(fn -> File.rm_rf!(root) end)

    %{source: source, target: target, soul: Path.join([target, "agent", "workspace", "SOUL.md"])}
  end

  test "audit is read-only and emits a JSON report", %{source: source, target: target} do
    output =
      capture_io(fn ->
        assert CLI.run([
                 "migrate",
                 "hermes",
                 "audit",
                 "--json",
                 "--source",
                 source,
                 "--target",
                 target
               ]) == 0
      end)

    report = Jason.decode!(output)
    assert is_map(report["summary"])
    assert Enum.any?(report["items"], &(&1["kind"] == "soul"))
    refute File.exists?(target)
  end

  test "dry run previews without writing", %{source: source, target: target, soul: soul} do
    output =
      capture_io(fn ->
        assert CLI.run(["migrate", "hermes", "--dry-run", "--source", source, "--target", target]) ==
                 0
      end)

    assert output =~ "Migration Preview"
    refute File.exists?(soul)
  end

  test "dry run displays unsupported Honcho settings and gated API key without leaking it", %{
    source: source,
    target: target
  } do
    File.cp!(
      Path.expand("../fixtures/hermes/honcho.json", __DIR__),
      Path.join(source, "honcho.json")
    )

    output =
      capture_io(fn ->
        assert CLI.run(["migrate", "hermes", "--dry-run", "--source", source, "--target", target]) ==
                 0
      end)

    assert output =~ "unsupported: honcho (dialecticDepth)"
    assert output =~ "unsupported: honcho (writeFrequency)"
    assert output =~ "gated: honcho_secret"
    refute output =~ "hk-fixture"
    refute File.exists?(target)
  end

  test "declined confirmation writes nothing", %{source: source, target: target, soul: soul} do
    output =
      capture_io(fn ->
        assert MigrateCommand.run(["hermes", "--source", source, "--target", target],
                 confirm: fn _question -> false end
               ) == 0
      end)

    assert output =~ "Migration cancelled."
    refute File.exists?(soul)
  end

  test "--yes applies the migration", %{source: source, target: target, soul: soul} do
    output =
      capture_io(fn ->
        assert CLI.run([
                 "migrate",
                 "hermes",
                 "--yes",
                 "--no-backup",
                 "--source",
                 source,
                 "--target",
                 target
               ]) == 0
      end)

    assert output =~ "Migration Complete"
    assert File.read!(soul) == "Hermes persona\n"
  end

  test "pre-migration backup is a verifiable Lemon backup without credentials", %{
    source: source,
    target: target
  } do
    File.mkdir_p!(Path.join([target, "agent", "workspace"]))
    File.write!(Path.join([target, "agent", "workspace", "MEMORY.md"]), "existing memory\n")
    File.write!(Path.join(target, "secrets_master_key"), "MASTER-KEY-BYTES-42")
    File.write!(Path.join(target, "env"), "export TOKEN=env-secret-42\n")

    output =
      capture_io(fn ->
        assert CLI.run(["migrate", "hermes", "--yes", "--source", source, "--target", target]) ==
                 0
      end)

    [_, bundle] = Regex.run(~r/Pre-migration backup: (\S+)/, output)

    assert {:ok, %{verified: true, includes_credentials: false}} =
             LemonCore.Backup.verify(bundle, target: target)

    assert File.read!(Path.join([bundle, "data", "agent", "workspace", "MEMORY.md"])) ==
             "existing memory\n"

    refute File.exists?(Path.join([bundle, "data", "secrets_master_key"]))
    refute File.exists?(Path.join([bundle, "data", "env"]))

    verify_output =
      capture_io(fn -> assert CLI.run(["backup", "verify", bundle]) == 0 end)

    assert verify_output =~ "Backup verified:"
  end

  test "rollback subcommand reverts an applied migration", %{
    source: source,
    target: target,
    soul: soul
  } do
    output =
      capture_io(fn ->
        assert CLI.run(["migrate", "hermes", "--yes", "--source", source, "--target", target]) ==
                 0
      end)

    [_, report_dir] = Regex.run(~r/Report: (\S+)/, output)
    assert File.read!(soul) == "Hermes persona\n"

    rollback =
      capture_io(fn -> assert CLI.run(["migrate", "hermes", "rollback", report_dir]) == 0 end)

    assert rollback =~ "Migration Rollback"
    refute File.exists?(soul)
  end

  test "conflicts fail closed unless --overwrite", %{source: source, target: target, soul: soul} do
    File.mkdir_p!(Path.dirname(soul))
    File.write!(soul, "Existing Lemon persona\n")

    error =
      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert CLI.run(["migrate", "hermes", "--yes", "--source", source, "--target", target]) ==
                   1
        end)
      end)

    assert error =~ "Migration has conflicts"
    assert File.read!(soul) == "Existing Lemon persona\n"
  end

  test "invalid presets and missing subcommands are usage errors" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["migrate", "hermes", "--preset", "everything"]) == 2
        assert CLI.run(["migrate"]) == 2
      end)

    assert error =~ "--preset must be one of: user-data, full"
    assert error =~ "Usage: lemon migrate hermes [audit|rollback DIR] [options]"
  end
end
