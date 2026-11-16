defmodule LemonCore.DurableTest do
  use ExUnit.Case, async: true

  alias LemonCore.Durable

  @moduletag :tmp_dir

  test "a directory flush is claimed only where it is synchronous", %{tmp_dir: dir} do
    dir = Path.join(dir, "literal 'quoted' 雪")
    File.mkdir!(dir)
    parent = self()

    worker =
      spawn(fn ->
        receive do
          :sync ->
            send(parent, {:synced, Durable.sync_directory(dir)})

            receive do
              :stop -> :ok
            end
        end
      end)

    :erlang.trace(worker, true, [:ports])
    send(worker, :sync)
    assert_receive {:synced, :ok}
    ref = :erlang.trace_delivered(worker)
    assert_receive {:trace_delivered, ^worker, ^ref}
    refute_received {:trace, ^worker, :open, _, _}
    send(worker, :stop)
  end

  test "a file flush syncs an existing file", %{tmp_dir: dir} do
    path = Path.join(dir, "data 'literal' 雪")
    File.write!(path, "contents")
    assert Durable.sync_file(path) == :ok
    assert {:error, :enoent} = Durable.sync_file(Path.join(dir, "missing"))
  end

  test "file flushes leave a trapping caller's mailbox empty", %{tmp_dir: dir} do
    if match?({:unix, :darwin}, :os.type()) do
      path = Path.join(dir, "data")
      File.write!(path, "contents")
      parent = self()

      {caller, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)

          results = [
            Durable.sync_file(path),
            Durable.sync_file(path),
            Durable.sync_file(Path.join(dir, "missing")),
            Durable.sync_file(dir)
          ]

          send(parent, {:sync_results, results, Process.info(self(), :messages)})
        end)

      assert_receive {:sync_results, results, messages}, 5_000
      assert results == [:ok, :ok, {:error, :enoent}, {:error, {:full_sync_failed, 65}}]
      assert messages == {:messages, []}

      assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    end
  end

  test "Darwin rejects wrong descriptor kinds instead of claiming a weaker barrier", %{
    tmp_dir: dir
  } do
    if match?({:unix, :darwin}, :os.type()) do
      path = Path.join(dir, "regular")
      File.write!(path, "contents")
      assert {:error, _} = Durable.sync_directory(path)
      assert {:error, {:full_sync_failed, _}} = Durable.sync_file(dir)
      link = Path.join(dir, "link")
      File.ln_s!(path, link)
      assert {:error, {:full_sync_failed, _}} = Durable.sync_file(link)
    end
  end
end
