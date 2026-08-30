defmodule LemonCore.BackupTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias LemonCore.Backup

  @moduletag :tmp_dir

  defp fixture(tmp_dir) do
    home = Path.join(tmp_dir, "home")
    source = Path.join(home, ".lemon")
    bundle = Path.join(tmp_dir, "fixture.lemonbackup")
    File.mkdir_p!(Path.join(source, "agent/sessions"))
    File.mkdir_p!(Path.join(source, "store"))
    File.write!(Path.join(source, "config.toml"), "[defaults]\nprovider = \"test\"\n")
    File.write!(Path.join(source, "agent/sessions/session.jsonl"), "{\"type\":\"session\"}\n")
    File.write!(Path.join(source, "store/state.sqlite3"), "durable-store")
    File.chmod!(Path.join(source, "config.toml"), 0o644)

    %{home: home, source: source, bundle: bundle}
  end

  defp create!(fixture, opts \\ []) do
    assert {:ok, summary} =
             Backup.create([paths_opts: [home_dir: fixture.home], output: fixture.bundle] ++ opts)

    summary
  end

  test "create is atomic, metadata-only, and excludes runtime and credentials by default", %{
    tmp_dir: tmp_dir
  } do
    fixture = fixture(tmp_dir)
    File.mkdir_p!(Path.join(fixture.source, "versions/2099.01.0"))
    File.write!(Path.join(fixture.source, "versions/2099.01.0/release"), "runtime")
    File.mkdir_p!(Path.join(fixture.source, "logs"))
    File.write!(Path.join(fixture.source, "logs/runtime.log"), "possibly sensitive")
    File.write!(Path.join(fixture.source, "cookie"), "cookie-secret")
    File.write!(Path.join(fixture.source, "env"), "export SECRET=value\n")
    File.write!(Path.join(fixture.source, "secrets_master_key"), "PRIVATE_KEY_BYTES_42")
    File.mkdir_p!(Path.join(fixture.source, "nodes/execution"))
    File.write!(Path.join(fixture.source, "nodes/execution/node.json"), "node-token")
    File.ln_s!("/etc/passwd", Path.join(fixture.source, "outside-link"))

    summary = create!(fixture)

    assert summary.verified
    assert summary.includes_credentials == false
    assert summary.contents_returned == false
    assert summary.secret_values_returned == false
    refute File.exists?(fixture.bundle <> ".partial")

    assert {:ok, verified} =
             Backup.verify(fixture.bundle, paths_opts: [home_dir: fixture.home])

    assert verified.file_count == 3
    assert byte_size(verified.manifest_sha256) == 64
    assert byte_size(verified.overwrite_confirmation) == 64

    data = Path.join(fixture.bundle, "data")
    assert File.read!(Path.join(data, "config.toml")) =~ "provider"
    refute File.exists?(Path.join(data, "versions"))
    refute File.exists?(Path.join(data, "logs"))
    refute File.exists?(Path.join(data, "cookie"))
    refute File.exists?(Path.join(data, "env"))
    refute File.exists?(Path.join(data, "secrets_master_key"))
    refute File.exists?(Path.join(data, "nodes/execution"))
    refute File.exists?(Path.join(data, "outside-link"))

    manifest_bytes = File.read!(Path.join(fixture.bundle, "manifest.json"))
    refute manifest_bytes =~ fixture.source
    refute manifest_bytes =~ "cookie-secret"
    refute manifest_bytes =~ "PRIVATE_KEY_BYTES_42"

    for path <- [
          fixture.bundle,
          data,
          Path.join(fixture.bundle, "manifest.json"),
          Path.join(fixture.bundle, "manifest.sha256"),
          Path.join(data, "config.toml")
        ] do
      assert {:ok, stat} = File.lstat(path)
      assert (stat.mode &&& 0o077) == 0
    end
  end

  test "credentials require explicit inclusion", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir)
    File.write!(Path.join(fixture.source, "cookie"), "cookie-secret")
    File.write!(Path.join(fixture.source, "secrets_master_key"), "master-key")
    File.mkdir_p!(Path.join(fixture.source, "nodes/execution"))
    File.write!(Path.join(fixture.source, "nodes/execution/node.json"), "node-token")

    summary = create!(fixture, include_credentials: true)

    assert summary.includes_credentials
    assert File.read!(Path.join(fixture.bundle, "data/cookie")) == "cookie-secret"
    assert File.read!(Path.join(fixture.bundle, "data/secrets_master_key")) == "master-key"

    assert File.read!(Path.join(fixture.bundle, "data/nodes/execution/node.json")) ==
             "node-token"
  end

  test "verify detects changed bytes, extra files, and permission widening", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir)
    create!(fixture)
    config = Path.join(fixture.bundle, "data/config.toml")

    File.write!(config, "tampered")
    assert {:error, :file_checksum_mismatch} = Backup.verify(fixture.bundle)

    File.rm_rf!(fixture.bundle)
    create!(fixture)
    extra = Path.join(fixture.bundle, "data/extra")
    File.write!(extra, "unexpected")
    File.chmod!(extra, 0o600)
    assert {:error, :bundle_file_set_mismatch} = Backup.verify(fixture.bundle)

    File.rm_rf!(fixture.bundle)
    create!(fixture)
    config = Path.join(fixture.bundle, "data/config.toml")
    File.chmod!(config, 0o644)
    assert {:error, :unsafe_bundle_permissions} = Backup.verify(fixture.bundle)
  end

  test "verify rejects traversal and unsupported schemas before restore", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir)
    create!(fixture)

    rewrite_manifest!(fixture.bundle, fn manifest ->
      put_in(manifest, ["files", Access.at(0), "path"], "../outside")
    end)

    assert {:error, :unsafe_manifest_path} = Backup.verify(fixture.bundle)

    File.rm_rf!(fixture.bundle)
    create!(fixture)

    rewrite_manifest!(fixture.bundle, &Map.put(&1, "schema", 99))

    assert {:error, {:unsupported_backup_schema, 99}} = Backup.verify(fixture.bundle)
  end

  test "restore verifies first, refuses conflicts, and binds overwrite to manifest plus target",
       %{
         tmp_dir: tmp_dir
       } do
    fixture = fixture(tmp_dir)
    create!(fixture)

    target = Path.join(tmp_dir, "restore-home/.lemon")
    File.mkdir_p!(Path.join(target, "versions/keep-me"))
    File.write!(Path.join(target, "versions/keep-me/runtime"), "installed")
    File.write!(Path.join(target, "config.toml"), "current-config")
    File.chmod!(Path.join(target, "config.toml"), 0o600)

    assert {:error, {:restore_conflicts, 1}} = Backup.restore(fixture.bundle, target: target)
    assert File.read!(Path.join(target, "config.toml")) == "current-config"

    assert {:ok, verified} = Backup.verify(fixture.bundle, target: target)

    assert {:error, :restore_confirmation_mismatch} =
             Backup.restore(fixture.bundle,
               target: target,
               overwrite: true,
               confirmation: String.duplicate("0", 64)
             )

    assert File.read!(Path.join(target, "config.toml")) == "current-config"

    assert {:ok, restored} =
             Backup.restore(fixture.bundle,
               target: target,
               overwrite: true,
               confirmation: verified.overwrite_confirmation
             )

    assert restored.verified
    assert restored.overwritten_count == 1
    assert restored.restored_count == 3
    assert is_binary(restored.rollback_path)
    assert File.read!(Path.join(target, "config.toml")) =~ "provider"
    assert File.read!(Path.join(target, "versions/keep-me/runtime")) == "installed"
    assert File.read!(Path.join(restored.rollback_path, "config.toml")) == "current-config"

    assert {:ok, stat} = File.stat(Path.join(target, "config.toml"))
    assert (stat.mode &&& 0o777) == 0o600
  end

  test "restore to an empty target needs no overwrite confirmation and list is aggregate-only", %{
    tmp_dir: tmp_dir
  } do
    fixture = fixture(tmp_dir)
    create!(fixture)
    target = Path.join(tmp_dir, "empty/.lemon")

    assert {:ok, restored} = Backup.restore(fixture.bundle, target: target)
    assert restored.overwritten_count == 0
    assert restored.rollback_path == nil
    assert File.read!(Path.join(target, "store/state.sqlite3")) == "durable-store"

    backup_root = Path.join(tmp_dir, "listed")
    listed_bundle = Path.join(backup_root, "listed.lemonbackup")
    File.mkdir_p!(backup_root)

    assert {:ok, _summary} =
             Backup.create(
               paths_opts: [home_dir: fixture.home],
               output: listed_bundle,
               backup_root: backup_root
             )

    assert {:ok, [listed]} = Backup.list(backup_root: backup_root)
    assert listed.contents_returned == false
    assert listed.secret_values_returned == false
    refute Map.has_key?(listed, :files)
  end

  defp rewrite_manifest!(bundle, fun) do
    manifest_path = Path.join(bundle, "manifest.json")
    manifest = manifest_path |> File.read!() |> Jason.decode!() |> fun.()
    bytes = Jason.encode!(manifest, pretty: true) <> "\n"
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    File.write!(manifest_path, bytes)
    File.write!(Path.join(bundle, "manifest.sha256"), "#{digest}  manifest.json\n")
    File.chmod!(manifest_path, 0o600)
    File.chmod!(Path.join(bundle, "manifest.sha256"), 0o600)
  end
end
