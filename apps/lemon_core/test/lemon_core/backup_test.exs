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

  defp restore(bundle, opts) do
    Backup.restore(
      bundle,
      Keyword.put_new(opts, :paths_opts, home_dir: Path.join(Path.dirname(bundle), "home"))
    )
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

    assert {:error, {:restore_conflicts, 1}} = restore(fixture.bundle, target: target)
    assert File.read!(Path.join(target, "config.toml")) == "current-config"

    assert {:ok, verified} = Backup.verify(fixture.bundle, target: target)

    assert {:error, :restore_confirmation_mismatch} =
             restore(fixture.bundle,
               target: target,
               overwrite: true,
               confirmation: String.duplicate("0", 64)
             )

    assert File.read!(Path.join(target, "config.toml")) == "current-config"

    assert {:ok, restored} =
             restore(fixture.bundle,
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

    assert {:ok, restored} = restore(fixture.bundle, target: target)
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
             restore(fixture.bundle, target: symlink_target)

    assert File.ls!(real_target) == []
  end

  describe "daemon ownership" do
    setup %{tmp_dir: tmp_dir} do
      fixture = fixture(tmp_dir)
      create!(fixture)
      run = Path.join(fixture.source, "run")
      target = Path.join(tmp_dir, "relocated")
      File.mkdir_p!(run)
      File.mkdir_p!(target)
      %{fixture: fixture, run: run, target: target}
    end

    test "live target PID records refuse additive and authorized overwrite without mutation",
         ctx do
      run = Path.join(ctx.target, "run")
      File.mkdir_p!(run)
      write_pid!(Path.join(run, "lemon-4040.pid"))
      File.write!(Path.join(ctx.target, "config.toml"), "current")
      {:ok, verified} = Backup.verify(ctx.fixture.bundle, target: ctx.target)
      before = snapshot_tree(ctx.tmp_dir)

      assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: ctx.target)

      assert {:error, :daemon_running} =
               restore(ctx.fixture.bundle,
                 target: ctx.target,
                 overwrite: true,
                 confirmation: verified.overwrite_confirmation
               )

      assert snapshot_tree(ctx.tmp_dir) == before
    end

    test "verifies all bundle bytes before publishing a lifecycle lock", ctx do
      File.write!(Path.join(ctx.fixture.bundle, "data/store/state.sqlite3"), "changed")
      before = snapshot_tree(ctx.tmp_dir)

      assert {:error, :file_checksum_mismatch} = restore(ctx.fixture.bundle, target: ctx.target)
      assert snapshot_tree(ctx.tmp_dir) == before
    end

    test "PID start identity distinguishes stale records from live ownership", ctx do
      pid_file = Path.join(ctx.run, "lemon-4040.pid")
      write_pid!(pid_file)
      inner = Path.join(ctx.fixture.source, "restored")
      assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: inner)

      File.write!(pid_file, "#{System.pid()}\nstale-start-time\n")
      assert {:ok, _} = restore(ctx.fixture.bundle, target: inner)
    end

    test "relocated stores and their children are detected through symlinks", ctx do
      alias_dir = Path.join(ctx.tmp_dir, "alias")
      File.ln_s!(ctx.target, alias_dir)
      register_runtime!(ctx.run, ctx.fixture.source, Path.join(alias_dir, "store"))
      before = snapshot_tree(ctx.tmp_dir)

      for target <- [ctx.target, Path.join(ctx.target, "store/nested")] do
        assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: target)
      end

      assert snapshot_tree(ctx.tmp_dir) == before
      assert {:ok, _} = restore(ctx.fixture.bundle, target: Path.join(ctx.tmp_dir, "isolated"))
    end

    test "custom PID records remain discoverable without a default PID or health endpoint", ctx do
      pid_file = Path.join(ctx.tmp_dir, "custom.pid")
      write_pid!(pid_file)

      File.write!(
        Path.join(ctx.run, "lemon-4040.paths"),
        "#{ctx.fixture.source}\n#{ctx.target}\n#{pid_file}\n"
      )

      before = snapshot_tree(ctx.tmp_dir)
      assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: ctx.target)
      assert snapshot_tree(ctx.tmp_dir) == before

      File.write!(pid_file, "999999999\n")
      assert {:ok, _} = restore(ctx.fixture.bundle, target: ctx.target)
    end

    test "the default-home health probe refuses before mutation", ctx do
      before = snapshot_tree(ctx.tmp_dir)

      assert {:error, :daemon_running} =
               restore(ctx.fixture.bundle,
                 paths_opts: [home_dir: ctx.fixture.home],
                 runtime_probe: fn _ -> true end
               )

      assert snapshot_tree(ctx.tmp_dir) == before
    end

    test "a daemon appearing at the final check leaves no destination or lock", ctx do
      fresh_home = Path.join(ctx.tmp_dir, "fresh-home")
      calls = :counters.new(1, [])

      probe = fn _ ->
        :counters.add(calls, 1, 1)
        :counters.get(calls, 1) > 1
      end

      before = snapshot_tree(ctx.tmp_dir)

      assert {:error, :daemon_running} =
               restore(ctx.fixture.bundle,
                 paths_opts: [home_dir: fresh_home],
                 runtime_probe: probe
               )

      assert snapshot_tree(ctx.tmp_dir) == before
    end

    test "a crashed restore lock is reclaimed without retaining staging metadata", ctx do
      lock = Path.join(ctx.run, "restore-dead.lock")
      File.mkdir_p!(lock)
      File.write!(Path.join(lock, "owner"), "999999999\n")
      File.write!(Path.join(lock, "target"), ctx.target <> "\n")

      # A stale lock from another target is harmless to launchers; the actual
      # same-target lock must also be reclaimable on the next restore.
      digest = :crypto.hash(:sha256, ctx.target) |> Base.encode16(case: :lower)
      File.rename!(lock, Path.join(ctx.run, "restore-#{digest}.lock"))
      assert {:ok, _} = restore(ctx.fixture.bundle, target: ctx.target)
      assert File.ls!(ctx.run) == []
    end

    for {name, relative} <- [
          {"source", "bin/lemon"},
          {"packaged", "rel/overlays/bin/lemon"}
        ] do
      test "#{name}: healthy reuse precedes state publication and runtime boot", ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        curl = Path.join(ctx.tmp_dir, "fakebin/curl")
        File.write!(curl, "#!/usr/bin/env bash\nprintf '{\"ok\":true}'\n")
        before = snapshot_tree(ctx.tmp_dir)

        for command <- ["start", "daemon"] do
          assert {output, 0} = run_launcher(launcher, command, [])
          assert output =~ "reusing"
          assert snapshot_tree(ctx.tmp_dir) == before
        end
      end

      test "#{name}: backup dispatch creates no runtime credentials or bootstrap state", ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        before = snapshot_tree(ctx.tmp_dir)

        {_output, status} =
          run_launcher(
            launcher,
            ["backup", "restore", ctx.fixture.bundle, "--target", ctx.target, "--json"],
            []
          )

        # The stand-in eval/Elixir deliberately fails. This isolates the shell
        # boundary; real CLI refusal and its error document are tested separately.
        assert status != 0
        assert snapshot_tree(ctx.tmp_dir) == before
      end

      test "#{name}: unhealthy live runtime paths survive both startup refusals", ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        pid_file = Path.join(ctx.tmp_dir, "original-runtime.pid")
        write_pid!(pid_file)

        File.write!(
          Path.join(ctx.run, "lemon-#{launcher.port}.paths"),
          "#{ctx.fixture.source}\n#{ctx.target}\n#{pid_file}\n"
        )

        # The caller changes both store and PID-file overrides. Neither may
        # conceal or replace the original live runtime's ownership record.
        env = [
          {"LEMON_STORE_PATH", Path.join(ctx.tmp_dir, "different-store")},
          {"LEMON_RUNTIME_PID_FILE", Path.join(ctx.tmp_dir, "different.pid")}
        ]

        for record <- [File.read!(pid_file), "#{System.pid()}\n"],
            command <- ["start", "daemon"] do
          # Both source two-line identities and packaged PID-only records
          # must survive a launch through either installation's wrapper.
          File.write!(pid_file, record)
          before = snapshot_tree(ctx.tmp_dir)
          assert {output, 1} = run_launcher(launcher, command, env)
          assert output =~ "alive"
          assert snapshot_tree(ctx.tmp_dir) == before
          assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: ctx.target)
          assert snapshot_tree(ctx.tmp_dir) == before
        end
      end

      test "#{name}: relative stores belong to the runtime root, not the launch cwd", ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        ready = Path.join(ctx.tmp_dir, "runtime-ready")
        gate = Path.join(ctx.tmp_dir, "runtime-exit")
        target = Path.join(launcher.root, "relocated")

        task =
          Task.async(fn ->
            run_launcher(launcher, "start", [
              {"LEMON_STORE_PATH", "relocated/nested/../store"},
              {"RUNTIME_READY", ready},
              {"RUNTIME_GATE", gate}
            ])
          end)

        try do
          await_file!(ready)
          paths = File.read!(Path.join(ctx.run, "lemon-#{launcher.port}.paths"))
          assert Enum.at(String.split(paths, "\n"), 1) == Path.join(target, "store")
          runtime_store = ready |> Kernel.<>(".store") |> File.read!() |> String.trim()
          assert Path.type(runtime_store) == :absolute
          assert Path.expand(runtime_store) == Path.join(target, "store")
          before = snapshot_tree(ctx.tmp_dir)
          assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: target)
          assert snapshot_tree(ctx.tmp_dir) == before
        after
          File.write!(gate, "")
          Task.await(task, 10_000)
        end
      end

      test "#{name}: an explicit SQLite file symlink retains live physical database ownership",
           ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        ready = Path.join(ctx.tmp_dir, "sqlite-runtime-ready")
        gate = Path.join(ctx.tmp_dir, "sqlite-runtime-exit")
        database = Path.join(ctx.target, "store/state.sqlite3")
        alias_path = Path.join(ctx.tmp_dir, "alias/live.sqlite3")
        File.mkdir_p!(Path.dirname(database))
        File.mkdir_p!(Path.dirname(alias_path))
        conn = open_wal_db!(database)
        insert_item!(conn, 1)
        :ok = Sqlite3.close(conn)
        File.ln_s!(database, alias_path)
        assert {:ok, verified} = Backup.verify(ctx.fixture.bundle, target: ctx.target)

        task =
          Task.async(fn ->
            run_launcher(launcher, "start", [
              {"LEMON_STORE_PATH", alias_path},
              {"RUNTIME_READY", ready},
              {"RUNTIME_GATE", gate}
            ])
          end)

        try do
          await_file!(ready)
          paths = File.read!(Path.join(ctx.run, "lemon-#{launcher.port}.paths"))

          assert [home, logical_store, physical_database, pid_file] =
                   String.split(paths, "\n", trim: true)

          assert home == ctx.fixture.source
          assert logical_store == Path.dirname(alias_path)
          assert physical_database == database
          assert File.exists?(pid_file)
          before = snapshot_tree(ctx.tmp_dir)

          assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: ctx.target)
          assert snapshot_tree(ctx.tmp_dir) == before

          assert {:error, :daemon_running} =
                   restore(ctx.fixture.bundle,
                     target: ctx.target,
                     overwrite: true,
                     confirmation: verified.overwrite_confirmation
                   )

          assert snapshot_tree(ctx.tmp_dir) == before
        after
          File.write!(gate, "")
          Task.await(task, 10_000)
        end
      end

      for command <- ["start", "daemon"] do
        test "#{name} #{command}: custom PID startup is visible before health is available",
             ctx do
          launcher = launcher_fixture(ctx, unquote(relative))
          ready = Path.join(ctx.tmp_dir, "startup-ready")
          gate = Path.join(ctx.tmp_dir, "startup-exit")
          custom_pid = Path.join(ctx.tmp_dir, "custom-startup.pid")

          task =
            Task.async(fn ->
              run_launcher(launcher, unquote(command), [
                {"LEMON_STORE_PATH", Path.join(ctx.target, "store")},
                {"LEMON_RUNTIME_PID_FILE", custom_pid},
                {"STARTUP_READY", ready},
                {"STARTUP_GATE", gate}
              ])
            end)

          try do
            await_file!(ready)
            refute File.exists?(Path.join(ctx.run, "lemon-#{launcher.port}.pid"))
            paths = File.read!(Path.join(ctx.run, "lemon-#{launcher.port}.paths"))
            assert Enum.at(String.split(paths, "\n"), 3) == custom_pid
            before = snapshot_tree(ctx.tmp_dir)
            assert {:error, :daemon_running} = restore(ctx.fixture.bundle, target: ctx.target)
            assert snapshot_tree(ctx.tmp_dir) == before
          after
            File.write!(gate, "")
            Task.await(task, 10_000)
          end
        end
      end

      test "#{name}: restore-first lock rejects a synchronized startup until replacement finishes",
           ctx do
        launcher = launcher_fixture(ctx, unquote(relative))

        hook = fn ->
          [lock] = Path.wildcard(Path.join(ctx.run, "restore-*.lock"))
          assert File.read!(Path.join(lock, "owner")) == "#{System.pid()}\n"
          assert String.trim(File.read!(Path.join(lock, "target"))) == ctx.target

          assert {output, 1} =
                   run_launcher(launcher, "daemon", [
                     {"LEMON_STORE_PATH", Path.join(ctx.target, "store")}
                   ])

          assert output =~ "backup restore"
          refute File.exists?(Path.join(ctx.run, "lemon-#{launcher.port}.pid"))
          refute File.exists?(Path.join(ctx.run, "control-plane-#{launcher.port}.token"))
        end

        assert {:ok, _} =
                 restore(ctx.fixture.bundle, target: ctx.target, after_runtime_check: hook)

        assert Path.wildcard(Path.join(ctx.run, "restore-*.lock")) == []
      end

      test "#{name}: restore-first locks protect a target owned by a different launcher HOME",
           ctx do
        launcher = launcher_fixture(ctx, unquote(relative))
        launcher_home = Path.join(ctx.tmp_dir, "launcher-home")
        target = Path.join(launcher_home, ".lemon")
        target_run = Path.join(target, "run")
        File.mkdir_p!(target)
        File.write!(Path.join(target, "config.toml"), "before-restore")
        assert launcher_home != ctx.fixture.home
        assert {:ok, verified} = Backup.verify(ctx.fixture.bundle, target: target)

        hook = fn ->
          locks =
            for run <- [ctx.run, target_run] do
              [lock] = Path.wildcard(Path.join(run, "restore-*.lock"))
              assert File.read!(Path.join(lock, "owner")) == "#{System.pid()}\n"
              assert String.trim(File.read!(Path.join(lock, "target"))) == target
              lock
            end

          assert File.read!(Path.join(target, "config.toml")) == "before-restore"

          assert {output, 1} =
                   run_launcher(launcher, "daemon", [
                     {"HOME", launcher_home},
                     {"LEMON_STORE_PATH", nil}
                   ])

          assert output =~ "backup restore"
          refute File.exists?(Path.join(target_run, "lemon-#{launcher.port}.pid"))
          refute File.exists?(Path.join(target_run, "control-plane-#{launcher.port}.token"))

          for lock <- locks do
            assert File.read!(Path.join(lock, "owner")) == "#{System.pid()}\n"
            assert String.trim(File.read!(Path.join(lock, "target"))) == target
          end
        end

        assert {:ok, restored} =
                 restore(ctx.fixture.bundle,
                   target: target,
                   overwrite: true,
                   confirmation: verified.overwrite_confirmation,
                   after_runtime_check: hook
                 )

        assert File.read!(Path.join(target, "config.toml")) =~ "provider"
        assert File.read!(Path.join(restored.rollback_path, "config.toml")) == "before-restore"

        for run <- [ctx.run, target_run] do
          assert Path.wildcard(Path.join(run, "restore-*.lock")) == []
        end
      end
    end
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

      assert {:error, {:restore_conflicts, 2}} = restore(fixture.bundle, target: target)
      assert {:ok, verified} = Backup.verify(fixture.bundle, target: target)

      assert {:ok, restored} =
               restore(fixture.bundle,
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

      assert {:ok, restored} = restore(fixture.bundle, target: absent)
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

      assert {:error, {:restore_conflicts, 1}} = restore(fixture.bundle, target: differing)
      assert {:ok, verified} = Backup.verify(fixture.bundle, target: differing)

      assert {:ok, overwritten} =
               restore(fixture.bundle,
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

  defp write_pid!(path) do
    {born, 0} = System.cmd("ps", ["-p", System.pid(), "-o", "lstart="])
    File.write!(path, "#{System.pid()}\n#{String.trim_trailing(born, "\n")}\n")
    File.chmod!(path, 0o600)
  end

  defp register_runtime!(run, home, store) do
    write_pid!(Path.join(run, "lemon-4040.pid"))
    File.write!(Path.join(run, "lemon-4040.paths"), "#{home}\n#{store}\n")
  end

  defp snapshot_tree(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.sort()
    |> Enum.map(fn path ->
      stat = File.lstat!(path)

      contents =
        case stat.type do
          :regular -> File.read!(path)
          :symlink -> File.read_link!(path)
          _ -> nil
        end

      {path, stat.type, stat.mode, contents}
    end)
  end

  # Run the real launcher branches with stand-in runtime binaries. Gate files
  # synchronize startup with restore, without booting another umbrella runtime.
  defp launcher_fixture(ctx, relative) do
    root = Path.join(ctx.tmp_dir, "runtime-root")
    fakebin = Path.join(ctx.tmp_dir, "fakebin")
    cwd = Path.join(ctx.tmp_dir, "unrelated-cwd")
    script = Path.join(root, "bin/lemon")
    File.mkdir_p!(Path.dirname(script))
    File.mkdir_p!(fakebin)
    File.mkdir_p!(cwd)
    File.cp!(Path.expand("../../../../" <> relative, __DIR__), script)
    File.chmod!(script, 0o700)

    fake_runtime = """
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "${STARTUP_READY:-}" ]; then
      touch "$STARTUP_READY"
      until [ -f "$STARTUP_GATE" ]; do sleep 0.01; done
      exit 1
    fi
    if [ "${1:-}" = compile ]; then exit 0; fi
    if [ -n "${RUNTIME_READY:-}" ]; then
      printf '%s\\n' "${LEMON_STORE_PATH:-}" > "$RUNTIME_READY.store"
      touch "$RUNTIME_READY"
      until [ -f "$RUNTIME_GATE" ]; do sleep 0.01; done
    fi
    exit 1
    """

    for path <- [Path.join(fakebin, "mix"), Path.join(root, "bin/lemon_runtime_full")] do
      File.write!(path, fake_runtime)
      File.chmod!(path, 0o700)
    end

    for name <- ["elixir", "curl"] do
      path = Path.join(fakebin, name)
      File.write!(path, "#!/usr/bin/env bash\nexit 22\n")
      File.chmod!(path, 0o700)
    end

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    %{
      script: script,
      root: root,
      cwd: cwd,
      port: port,
      source?: relative == "bin/lemon",
      env: [
        {"HOME", ctx.fixture.home},
        {"PATH", fakebin <> ":" <> System.fetch_env!("PATH")},
        {"LEMON_CONTROL_PLANE_PORT", Integer.to_string(port)},
        {"LEMON_RUNTIME_PID_FILE", nil},
        {"LEMON_RUNTIME_LOG_FILE", nil},
        {"LEMON_CONTROL_PLANE_OPERATOR_TOKEN", nil},
        {"LEMON_WS_TOKEN", nil},
        {"LEMON_WEB_SECRET_KEY_BASE", String.duplicate("a", 64)},
        {"RELEASE_COOKIE", "test-cookie"},
        {"STARTUP_READY", nil},
        {"RUNTIME_READY", nil}
      ]
    }
  end

  defp run_launcher(launcher, command, env) do
    args =
      cond do
        is_list(command) -> command
        launcher.source? -> [command, "--no-distribution"]
        true -> [command]
      end

    env = Map.to_list(Map.merge(Map.new(launcher.env), Map.new(env)))

    System.cmd("bash", [launcher.script | args],
      env: env,
      cd: launcher.cwd,
      stderr_to_stdout: true
    )
  end

  defp await_file!(path, attempts \\ 500)
  defp await_file!(_path, 0), do: flunk("launcher did not reach the synchronized startup point")

  defp await_file!(path, attempts) do
    if not File.exists?(path) do
      Process.sleep(10)
      await_file!(path, attempts - 1)
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
