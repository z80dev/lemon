defmodule LemonCore.BackupTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Exqlite.Sqlite3
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

  test "create refuses an output inside an included source path and unsupported owner modes", %{
    tmp_dir: tmp_dir
  } do
    fixture = fixture(tmp_dir)
    unsafe_output = Path.join(fixture.source, "nested-backup.lemonbackup")

    assert {:error, :output_inside_source} =
             Backup.create(paths_opts: [home_dir: fixture.home], output: unsafe_output)

    refute File.exists?(unsafe_output)

    File.chmod!(Path.join(fixture.source, "config.toml"), 0o200)

    assert {:error, :unsupported_source_file_mode} =
             Backup.create(paths_opts: [home_dir: fixture.home], output: fixture.bundle)
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

    receipt =
      restored.rollback_path
      |> Path.join("restore-receipt.json")
      |> File.read!()
      |> Jason.decode!()

    assert receipt["manifest_sha256"] == verified.manifest_sha256
    assert receipt["target"] == Path.expand(target)

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

  test "restore refuses a symlink target before staging", %{tmp_dir: tmp_dir} do
    fixture = fixture(tmp_dir)
    create!(fixture)
    real_target = Path.join(tmp_dir, "real-target")
    symlink_target = Path.join(tmp_dir, "linked-target")
    File.mkdir_p!(real_target)
    File.ln_s!(real_target, symlink_target)

    assert {:error, :unsafe_restore_target} =
             Backup.restore(fixture.bundle, target: symlink_target)

    assert File.ls!(real_target) == []
  end

  describe "SQLite snapshots" do
    test "a backup taken during WAL writes is consistent and omits live sidecars", %{
      tmp_dir: tmp_dir
    } do
      fixture = fixture(tmp_dir)
      db = Path.join(fixture.source, "store/state.sqlite3")
      File.rm!(db)
      conn = open_wal_db!(db)

      Enum.each(1..200, &insert_item!(conn, &1))
      assert File.stat!(db <> "-wal").size > 0

      writer_conn = open_wal_db!(db)
      parent = self()

      writer =
        Task.async(fn ->
          send(parent, :writer_ready)
          write_until_stopped(writer_conn, 200)
        end)

      assert_receive :writer_ready
      summary = create!(fixture)
      send(writer.pid, :stop)
      assert Task.await(writer) >= 200

      assert summary.verified
      assert {:ok, _} = Backup.verify(fixture.bundle)

      data = Path.join(fixture.bundle, "data/store")
      assert File.ls!(data) == ["state.sqlite3"]
      manifest = fixture.bundle |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["exclusions"]["observed_counts"]["sqlite_sidecar"] >= 1

      copy = Path.join(tmp_dir, "copy.db")
      File.cp!(Path.join(data, "state.sqlite3"), copy)
      {:ok, check} = Sqlite3.open(copy)
      assert [["ok"]] = query!(check, "PRAGMA integrity_check")

      assert [[count, max_id]] = query!(check, "SELECT count(*), max(id) FROM items")
      assert count >= 200
      assert count == max_id
      Sqlite3.close(check)
      Sqlite3.close(conn)
      Sqlite3.close(writer_conn)
    end

    test "restore displaces a stale WAL beside a replaced database", %{tmp_dir: tmp_dir} do
      fixture = fixture(tmp_dir)
      db = Path.join(fixture.source, "store/state.sqlite3")
      File.rm!(db)
      conn = open_wal_db!(db)
      Enum.each(1..5, &insert_item!(conn, &1))
      create!(fixture)
      Sqlite3.close(conn)

      target = Path.join(tmp_dir, "restore-home/.lemon")
      File.mkdir_p!(Path.join(target, "store"))
      File.write!(Path.join(target, "store/state.sqlite3"), "old")
      File.write!(Path.join(target, "store/state.sqlite3-wal"), "stale wal")
      File.chmod!(Path.join(target, "store/state.sqlite3"), 0o600)

      assert {:error, {:restore_conflicts, 2}} = Backup.restore(fixture.bundle, target: target)
      assert {:ok, verified} = Backup.verify(fixture.bundle, target: target)

      assert {:ok, restored} =
               Backup.restore(fixture.bundle,
                 target: target,
                 overwrite: true,
                 confirmation: verified.overwrite_confirmation
               )

      assert restored.overwritten_count == 2
      refute File.exists?(Path.join(target, "store/state.sqlite3-wal"))

      assert File.read!(Path.join(restored.rollback_path, "store/state.sqlite3-wal")) ==
               "stale wal"
    end

    test "a pre-patch bundle's manifest-listed WAL is restored, not displaced as stale", %{
      tmp_dir: tmp_dir
    } do
      fixture = fixture(tmp_dir)
      {wal_bytes, rows} = legacy_bundle!(fixture, 25)
      assert {:ok, _} = Backup.verify(fixture.bundle)

      # Target database absent; an identical WAL holding committed rows is
      # already in place. Nothing is a conflict and nothing is displaced.
      absent = Path.join(tmp_dir, "legacy-absent/.lemon")
      File.mkdir_p!(Path.join(absent, "store"))
      File.write!(Path.join(absent, "store/state.sqlite3-wal"), wal_bytes)
      File.chmod!(Path.join(absent, "store/state.sqlite3-wal"), 0o600)

      assert {:ok, restored} = Backup.restore(fixture.bundle, target: absent)
      assert restored.overwritten_count == 0
      assert restored.rollback_path == nil
      assert restored.identical_count == 1
      assert File.read!(Path.join(absent, "store/state.sqlite3-wal")) == wal_bytes
      assert db_row_count(Path.join(absent, "store/state.sqlite3")) == rows

      # Target database different, identical WAL beside it: only the database
      # conflicts, and the committed WAL-only rows survive the overwrite.
      differing = Path.join(tmp_dir, "legacy-different/.lemon")
      File.mkdir_p!(Path.join(differing, "store"))
      File.write!(Path.join(differing, "store/state.sqlite3"), "old")
      File.chmod!(Path.join(differing, "store/state.sqlite3"), 0o600)
      File.write!(Path.join(differing, "store/state.sqlite3-wal"), wal_bytes)
      File.chmod!(Path.join(differing, "store/state.sqlite3-wal"), 0o600)

      assert {:error, {:restore_conflicts, 1}} = Backup.restore(fixture.bundle, target: differing)
      assert {:ok, verified} = Backup.verify(fixture.bundle, target: differing)

      assert {:ok, overwritten} =
               Backup.restore(fixture.bundle,
                 target: differing,
                 overwrite: true,
                 confirmation: verified.overwrite_confirmation
               )

      assert overwritten.overwritten_count == 1
      assert File.read!(Path.join(overwritten.rollback_path, "store/state.sqlite3")) == "old"
      assert File.read!(Path.join(differing, "store/state.sqlite3-wal")) == wal_bytes
      assert db_row_count(Path.join(differing, "store/state.sqlite3")) == rows
    end
  end

  # A bundle in the pre-patch layout: the raw database plus its live -wal as
  # manifest entries, with every row committed only in the WAL.
  defp legacy_bundle!(fixture, rows) do
    db = Path.join(fixture.source, "store/state.sqlite3")
    File.rm!(db)
    conn = open_wal_db!(db)
    Enum.each(1..rows, &insert_item!(conn, &1))
    create!(fixture)

    data = Path.join(fixture.bundle, "data/store")
    File.cp!(db, Path.join(data, "state.sqlite3"))
    File.cp!(db <> "-wal", Path.join(data, "state.sqlite3-wal"))
    Sqlite3.close(conn)
    Enum.each(["state.sqlite3", "state.sqlite3-wal"], &File.chmod!(Path.join(data, &1), 0o600))

    entry = fn name ->
      bytes = File.read!(Path.join(data, name))

      %{
        "path" => "store/" <> name,
        "bytes" => byte_size(bytes),
        "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
        "mode" => 0o600
      }
    end

    entries = [entry.("state.sqlite3"), entry.("state.sqlite3-wal")]

    rewrite_manifest!(fixture.bundle, fn manifest ->
      files =
        Enum.reject(manifest["files"], &(&1["path"] in Enum.map(entries, fn e -> e["path"] end))) ++
          entries

      %{
        manifest
        | "files" => files,
          "file_count" => length(files),
          "total_bytes" => Enum.reduce(files, 0, &(&1["bytes"] + &2))
      }
    end)

    {File.read!(Path.join(data, "state.sqlite3-wal")), rows}
  end

  defp db_row_count(path) do
    {:ok, conn} = Sqlite3.open(path)
    [[count]] = query!(conn, "SELECT count(*) FROM items")
    Sqlite3.close(conn)
    count
  end

  defp open_wal_db!(path) do
    {:ok, conn} = Sqlite3.open(path)
    :ok = Sqlite3.execute(conn, "PRAGMA busy_timeout=5000")
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA wal_autocheckpoint=0")

    :ok =
      Sqlite3.execute(
        conn,
        "CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, note TEXT NOT NULL)"
      )

    conn
  end

  defp insert_item!(conn, id) do
    :ok = Sqlite3.execute(conn, "INSERT INTO items (id, note) VALUES (#{id}, 'row-#{id}')")
  end

  defp write_until_stopped(conn, id) do
    receive do
      :stop -> id
    after
      0 ->
        case Sqlite3.execute(conn, "INSERT INTO items (id, note) VALUES (#{id + 1}, 'w')") do
          :ok -> write_until_stopped(conn, id + 1)
          {:error, _busy} -> write_until_stopped(conn, id)
        end
    end
  end

  defp query!(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    {:ok, rows} = Sqlite3.fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
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
