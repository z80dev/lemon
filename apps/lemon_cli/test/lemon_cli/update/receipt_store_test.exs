defmodule LemonCli.Update.ReceiptStoreTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias LemonCli.Update.{ManagedInstall, ReceiptStore}

  @moduletag :tmp_dir

  test "a holder killed without cleanup is recovered and the recovery is logged", %{
    tmp_dir: tmp_dir
  } do
    opts = [paths_opts: [home_dir: tmp_dir]]
    parent = self()

    {holder, monitor} =
      spawn_monitor(fn ->
        ReceiptStore.with_lock(opts, fn ->
          send(parent, {:locked, self()})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:locked, ^holder}, 5_000
    assert {:error, :update_locked} = ReceiptStore.with_lock(opts, fn -> :unexpected end)

    # `:kill` skips every `after` block, like a SIGKILL or VM halt mid-download.
    stranded = Path.join(ManagedInstall.versions_dir(opts), "9.9.9.partial")
    File.mkdir_p!(Path.join(stranded, "bin"))
    Process.exit(holder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :killed}, 1_000

    log =
      capture_log(fn ->
        assert :recovered = ReceiptStore.with_lock(opts, fn -> :recovered end)
      end)

    assert log =~ "Recovered a stale lock"
    refute File.exists?(stranded)
    assert :again = ReceiptStore.with_lock(opts, fn -> :again end)
  end

  test "a holder whose OS process died is recovered", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]
    {pid, 0} = System.cmd("sh", ["-c", "echo $$"])
    lock = Path.join(ReceiptStore.root(opts), "operation.lock")
    File.mkdir_p!(lock)
    File.chmod!(ReceiptStore.root(opts), 0o700)
    owner = Path.join(lock, "owner.#{String.duplicate("a", 32)}.json")

    File.write!(
      owner,
      Jason.encode!(%{
        pid: String.to_integer(String.trim(pid)),
        started_at: "Tue Nov 10 12:00:00 2026",
        beam_pid: "<0.1.0>",
        node: "halted@host"
      })
    )

    File.chmod!(owner, 0o600)

    capture_log(fn ->
      assert :recovered = ReceiptStore.with_lock(opts, fn -> :recovered end)
    end)

    refute File.exists?(lock)
  end

  test "a fresh lock file from an earlier release still blocks, a stale one is recovered", %{
    tmp_dir: tmp_dir
  } do
    opts = [paths_opts: [home_dir: tmp_dir]]
    legacy = Path.join(ReceiptStore.root(opts), ".operation.lock")
    File.mkdir_p!(ReceiptStore.root(opts))
    File.write!(legacy, "lemon-update-lock-v1\n")

    assert {:error, :update_locked} = ReceiptStore.with_lock(opts, fn -> :unexpected end)
    assert File.exists?(legacy)

    File.touch!(legacy, System.os_time(:second) - 7_200)

    log =
      capture_log(fn ->
        assert :recovered = ReceiptStore.with_lock(opts, fn -> :recovered end)
      end)

    assert log =~ "stale update lock"
    refute File.exists?(legacy)
  end

  test "callback failures release the lock without leaking the exception", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]

    assert {:error, :update_operation_failed} =
             ReceiptStore.with_lock(opts, fn -> raise "boom /private/path" end)

    assert {:error, :lock_timeout} =
             ReceiptStore.with_lock(opts, fn -> {:error, :lock_timeout} end)

    assert File.ls!(ReceiptStore.root(opts)) == []
  end

  test "stores private content-free receipts and serializes operations", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]

    assert {:ok, receipt} =
             ReceiptStore.put_receipt(
               %{
                 "action" => "apply",
                 "created_at_ms" => 1,
                 "from_version" => "1.0.0",
                 "to_version" => "2.0.0",
                 "status" => "applied",
                 "prompt" => "PLANTED_PROMPT_SECRET",
                 "path" => "/private/user/path",
                 "token" => "PLANTED_TOKEN_SECRET"
               },
               opts
             )

    [path] = Path.wildcard(Path.join([ReceiptStore.root(opts), "receipts", "*.json"]))
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    bytes = File.read!(path)
    refute bytes =~ "PLANTED"
    refute bytes =~ "/private/user/path"

    assert {:ok, [history]} = ReceiptStore.history(Keyword.put(opts, :limit, 1))
    assert history["id"] == receipt["id"]

    parent = self()

    task =
      Task.async(fn ->
        ReceiptStore.with_lock(opts, fn ->
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)
      end)

    # Taking the lock fsyncs the lock file (F_FULLFSYNC on macOS), which can
    # exceed the default 100ms receive window under a loaded full-suite run.
    assert_receive :locked, 5_000
    assert {:error, :update_locked} = ReceiptStore.with_lock(opts, fn -> :unexpected end)
    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "rejects traversal-shaped receipt identifiers", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]
    assert {:error, :invalid_receipt_id} = ReceiptStore.fetch_receipt("../../secret", opts)
  end

  test "keeps the backend version identity and still drops unknown fields", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]

    assert {:ok, receipt} =
             ReceiptStore.put_receipt(
               %{
                 "action" => "apply",
                 "created_at_ms" => 1,
                 "from_version" => "1.0.0",
                 "to_version" => "2.0.0",
                 "from_bot_version" => "1.0.0-stable-darwin-arm64",
                 "to_bot_version" => "2.0.0-stable-darwin-arm64",
                 "bot_path" => "/Users/someone/.lemon/lemon_bot",
                 "status" => "applied"
               },
               opts
             )

    assert receipt["from_bot_version"] == "1.0.0-stable-darwin-arm64"
    assert receipt["to_bot_version"] == "2.0.0-stable-darwin-arm64"
    refute Map.has_key?(receipt, "bot_path")

    [path] = Path.wildcard(Path.join([ReceiptStore.root(opts), "receipts", "*.json"]))
    refute File.read!(path) =~ "/Users/someone"
  end
end
