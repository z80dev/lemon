defmodule LemonCore.Update.ReceiptStoreTest do
  use ExUnit.Case, async: true

  alias LemonCore.Update.ReceiptStore

  @moduletag :tmp_dir

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

    assert_receive :locked
    assert {:error, :update_locked} = ReceiptStore.with_lock(opts, fn -> :unexpected end)
    send(task.pid, :release)
    assert Task.await(task) == :ok
  end

  test "rejects traversal-shaped receipt identifiers", %{tmp_dir: tmp_dir} do
    opts = [paths_opts: [home_dir: tmp_dir]]
    assert {:error, :invalid_receipt_id} = ReceiptStore.fetch_receipt("../../secret", opts)
  end
end
