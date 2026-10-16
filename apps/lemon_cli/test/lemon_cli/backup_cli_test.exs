defmodule LemonCli.BackupCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lemon_backup_cli_#{System.unique_integer([:positive])}")

    home = Path.join(tmp_dir, "home")
    lemon_home = Path.join(home, ".lemon")
    File.mkdir_p!(Path.join(lemon_home, "store"))
    File.write!(Path.join(lemon_home, "config.toml"), "provider_token = \"CONFIG_SECRET_42\"\n")
    File.write!(Path.join(lemon_home, "store/state.db"), "durable-state")
    File.write!(Path.join(lemon_home, "cookie"), "COOKIE_SECRET_42")

    original_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, home: home, lemon_home: lemon_home}
  end

  test "create, verify, guarded overwrite, restore, and list use stable JSON", context do
    create_json =
      capture_io(fn ->
        assert CLI.run(["backup", "create", "--json"]) == 0
      end)

    create = Jason.decode!(create_json)
    assert create["ok"]
    assert create["operation"] == "create"
    assert create["result"]["verified"]
    assert create["result"]["includes_credentials"] == false
    refute create_json =~ "CONFIG_SECRET_42"
    refute create_json =~ "COOKIE_SECRET_42"

    bundle = create["result"]["path"]
    refute File.exists?(Path.join(bundle, "data/cookie"))

    target = Path.join(context.tmp_dir, "restore/.lemon")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "config.toml"), "current-config")
    File.chmod!(Path.join(target, "config.toml"), 0o600)

    verify_json =
      capture_io(fn ->
        assert CLI.run(["backup", "verify", bundle, "--target", target, "--json"]) == 0
      end)

    verify = Jason.decode!(verify_json)
    assert verify["ok"]
    assert verify["result"]["verified"]
    confirmation = verify["result"]["overwrite_confirmation"]
    assert byte_size(confirmation) == 64

    conflict_json =
      capture_io(:stderr, fn ->
        assert CLI.run(["backup", "restore", bundle, "--target", target, "--json"]) == 1
      end)

    conflict = Jason.decode!(conflict_json)
    assert conflict["ok"] == false
    assert conflict["error"]["code"] == "restore_conflicts"
    assert File.read!(Path.join(target, "config.toml")) == "current-config"

    restore_json =
      capture_io(fn ->
        assert CLI.run([
                 "backup",
                 "restore",
                 bundle,
                 "--target",
                 target,
                 "--overwrite",
                 "--confirm",
                 confirmation,
                 "--json"
               ]) == 0
      end)

    restore = Jason.decode!(restore_json)
    assert restore["ok"]
    assert restore["operation"] == "restore"
    assert restore["result"]["overwritten_count"] == 1
    assert File.read!(Path.join(target, "config.toml")) =~ "CONFIG_SECRET_42"
    assert File.read!(Path.join(target, "store/state.db")) == "durable-state"

    list_json =
      capture_io(fn ->
        assert CLI.run(["backup", "list", "--json"]) == 0
      end)

    listed = Jason.decode!(list_json)
    assert listed["ok"]
    assert [%{"id" => _id, "file_count" => 2}] = listed["result"]
    refute list_json =~ "CONFIG_SECRET_42"
    refute list_json =~ "COOKIE_SECRET_42"
  end

  test "running target daemon returns an actionable error without changing state", context do
    create_json = capture_io(fn -> assert CLI.run(["backup", "create", "--json"]) == 0 end)
    bundle = Jason.decode!(create_json)["result"]["path"]
    target = Path.join(context.tmp_dir, "daemon-target")
    run = Path.join(target, "run")
    File.mkdir_p!(run)
    File.write!(Path.join(run, "lemon-4040.pid"), "#{System.pid()}\n")

    stderr =
      capture_io(:stderr, fn ->
        assert CLI.run(["backup", "restore", bundle, "--target", target, "--json"]) == 1
      end)

    error = Jason.decode!(stderr)
    assert error["ok"] == false
    assert error["error"]["code"] == "daemon_running"
    assert error["error"]["message"] =~ "lemon stop"
    assert error["error"]["message"] =~ "control-plane port"
    assert File.ls!(target) == ["run"]
    assert File.ls!(run) == ["lemon-4040.pid"]
    refute File.exists?(Path.join(context.lemon_home, "run"))
  end

  test "custom PID files protect relocated stores without echoing their path", context do
    create_json = capture_io(fn -> assert CLI.run(["backup", "create", "--json"]) == 0 end)
    bundle = Jason.decode!(create_json)["result"]["path"]
    target = Path.join(context.tmp_dir, "relocated")
    store = Path.join(target, "store")
    pid_file = Path.join(context.tmp_dir, "PRIVATE_RUNTIME_PID_PATH")
    run = Path.join(context.lemon_home, "run")
    File.mkdir_p!(run)
    File.mkdir_p!(store)
    File.write!(pid_file, "#{System.pid()}\n")

    record = "#{context.lemon_home}\n#{store}\n#{pid_file}\n"
    File.write!(Path.join(run, "lemon-4040.paths"), record)

    stderr =
      capture_io(:stderr, fn ->
        assert CLI.run(["backup", "restore", bundle, "--target", target, "--json"]) == 1
      end)

    error = Jason.decode!(stderr)
    assert error["error"]["code"] == "daemon_running"
    assert error["error"]["message"] =~ "LEMON_RUNTIME_PID_FILE"
    refute stderr =~ pid_file
    assert File.ls!(store) == []
    assert File.ls!(target) == ["store"]
    assert File.ls!(run) == ["lemon-4040.paths"]
    assert File.read!(Path.join(run, "lemon-4040.paths")) == record
  end

  test "invalid confirmation syntax exits 2 without echoing the token" do
    token = "DO_NOT_ECHO_CONFIRMATION"

    stderr =
      capture_io(:stderr, fn ->
        assert CLI.run(["backup", "restore", "bundle", "--confirm", token, "--json"]) == 2
      end)

    assert stderr =~ "Usage: lemon backup"
    refute stderr =~ token
  end

  test "credential inclusion is explicit and still metadata-only", %{tmp_dir: tmp_dir} do
    output = Path.join(tmp_dir, "credentials.lemonbackup")

    json =
      capture_io(fn ->
        assert CLI.run([
                 "backup",
                 "create",
                 "--output",
                 output,
                 "--include-credentials",
                 "--json"
               ]) == 0
      end)

    result = Jason.decode!(json)
    assert result["result"]["includes_credentials"]
    assert File.read!(Path.join(output, "data/cookie")) == "COOKIE_SECRET_42"
    refute json =~ "COOKIE_SECRET_42"
  end
end
