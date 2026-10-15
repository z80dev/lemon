defmodule LemonCli.UpdateCommandTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias LemonCli.CLI

  alias LemonCore.Update.{ManagedInstall, ReceiptStore, Version}

  @moduletag :tmp_dir

  setup do
    previous = System.get_env("LEMON_CLI_LAUNCHER")
    System.put_env("LEMON_CLI_LAUNCHER", "source")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_CLI_LAUNCHER", previous),
        else: System.delete_env("LEMON_CLI_LAUNCHER")
    end)

    :ok
  end

  test "source checkout refuses packaged plan, apply, and rollback before mutation" do
    for command <- ~w(plan apply rollback) do
      error =
        capture_io(:stderr, fn ->
          assert CLI.run(["update", command]) == 1
        end)

      assert error =~ "Source checkouts cannot plan, apply, or roll back release artifacts"
      assert error =~ "reviewed git pull workflow"
    end
  end

  test "invalid combinations return a stable usage exit" do
    error =
      capture_io(:stderr, fn ->
        assert CLI.run(["update", "plan", "apply"]) == 2
      end)

    assert error =~ "Usage: lemon update"
  end

  test "both update CLIs report committed rollback restart failure with exit one and a receipt",
       %{
         tmp_dir: tmp_dir
       } do
    preserve_release_env()

    for {cli, prefix} <- [{CLI, ["update"]}, {LemonCore.Update.CLI, []}] do
      dir = Path.join(tmp_dir, inspect(cli))
      receipt = rollback_fixture(dir, String.duplicate("a", 64), 1)

      args =
        prefix ++
          [
            "rollback",
            "--receipt",
            receipt["id"],
            "--confirm",
            receipt["rollback_digest"],
            "--json"
          ]

      stdout =
        capture_io(fn ->
          stderr = capture_io(:stderr, fn -> assert cli.run(args) == 1 end)
          error = Jason.decode!(stderr)
          assert error["ok"] == false
          assert error["error"]["kind"] == "daemon_restart_failed"
          assert error["error"]["message"] =~ "were committed"
          result = error["error"]["result"]
          assert result["active"] == "1900.01.0"
          assert result["restart_required"] == true
          assert result["restart"] == "failed"
          assert result["receipt"]["status"] == "rolled_back"
          refute stderr =~ dir
        end)

      assert stdout == ""
      assert ManagedInstall.active([]) == "1900.01.0"
    end
  end

  test "a stopped rollback reports no daemon started and succeeds in both CLIs", %{
    tmp_dir: tmp_dir
  } do
    preserve_release_env()

    for {cli, prefix} <- [{CLI, ["update"]}, {LemonCore.Update.CLI, []}] do
      receipt = rollback_fixture(Path.join(tmp_dir, inspect(cli)), "stopped", 1)

      args =
        prefix ++
          ["rollback", "--receipt", receipt["id"], "--confirm", receipt["rollback_digest"]]

      output = capture_io(fn -> assert cli.run(args) == 0 end)
      assert output =~ "No daemon was running; none was started."
      refute output =~ "Managed daemon restarted."
    end
  end

  defp preserve_release_env do
    names = ~w(HOME RELEASE_ROOT LEMON_CLI_LAUNCHER)
    previous = Map.take(System.get_env(), names)

    on_exit(fn ->
      Enum.each(names, &System.delete_env/1)
      System.put_env(previous)
    end)
  end

  defp rollback_fixture(home, snapshot, restart_status) do
    current = Version.current()
    versions = Path.join([home, ".lemon", "versions"])
    System.put_env("HOME", home)
    System.put_env("RELEASE_ROOT", Path.join(versions, current))
    System.put_env("LEMON_CLI_LAUNCHER", "release")

    for version <- [current, "1900.01.0"] do
      root = Path.join(versions, version)
      File.mkdir_p!(Path.join(root, "bin"))
      launcher = Path.join(root, "bin/lemon")

      File.write!(launcher, """
      #!/bin/sh
      case "$1:$2" in
        version:) echo #{version} ;;
        __update-daemon:snapshot) echo #{snapshot} ;;
        __update-daemon:restart) echo private-runtime-output >&2; exit #{restart_status} ;;
        *) exit 1 ;;
      esac
      """)

      File.chmod!(launcher, 0o755)
    end

    File.ln_s!(current, Path.join(versions, "current"))
    {:ok, sha256} = ManagedInstall.launcher_sha256("1900.01.0", [])
    plan_digest = String.duplicate("b", 64)

    {:ok, checkpoint} =
      ReceiptStore.put_checkpoint(
        %{
          "status" => "verified",
          "from_version" => "1900.01.0",
          "plan_digest" => plan_digest,
          "launcher_sha256" => sha256
        },
        []
      )

    {:ok, receipt} =
      ReceiptStore.put_receipt(
        %{
          "action" => "apply",
          "status" => "applied",
          "checkpoint_id" => checkpoint["id"],
          "plan_digest" => plan_digest,
          "from_version" => "1900.01.0",
          "to_version" => current,
          "rollback_digest" => String.duplicate("c", 64)
        },
        []
      )

    receipt
  end
end
