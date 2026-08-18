defmodule CodingAgent.PrivateTmpTest do
  @moduledoc """
  The private-temp boundary behind every secret-bearing temporary object the
  coding agent creates: exact creation modes, containment, exclusive
  publication, and fail-closed behavior on every mktemp failure shape.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias CodingAgent.PrivateTmp
  alias CodingAgent.PythonRepl.Output

  @moduletag :tmp_dir

  describe "root/0" do
    test "is a cached 0700 directory directly beneath the system temp dir" do
      {:ok, root} = PrivateTmp.root()

      assert Path.dirname(root) == System.tmp_dir!()
      assert String.starts_with?(Path.basename(root), "lemon-private-")

      stat = File.lstat!(root)
      assert stat.type == :directory
      assert band(stat.mode, 0o777) == 0o700

      assert PrivateTmp.root() == {:ok, root}
    end

    test "serializes concurrent first callers onto one root", %{tmp_dir: tmp_dir} do
      isolate_system_tmp(tmp_dir)
      parent = self()

      tasks =
        for _ <- 1..16 do
          Task.async(fn ->
            send(parent, {:root_ready, self()})

            receive do
              :create_root -> PrivateTmp.root()
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:root_ready, _})
      Enum.each(tasks, &send(&1.pid, :create_root))

      roots = Enum.map(tasks, &Task.await(&1, 5_000))
      assert [{:ok, root}] = Enum.uniq(roots)

      assert [^root] =
               tmp_dir
               |> File.ls!()
               |> Enum.filter(&String.starts_with?(&1, "lemon-private-"))
               |> Enum.map(&Path.join(tmp_dir, &1))
    end
  end

  describe "spill reaping" do
    setup do
      {:ok, previous_root} = PrivateTmp.root()

      {:ok, root} =
        PrivateTmp.reserve_dir(System.tmp_dir!(), "lemon-private-spill-reaper")

      :persistent_term.put({PrivateTmp, :root}, root)
      :persistent_term.erase({PrivateTmp, :spill_sweep_at})

      on_exit(fn ->
        :persistent_term.put({PrivateTmp, :root}, previous_root)
        :persistent_term.erase({PrivateTmp, :spill_sweep_at})
        File.rm_rf(root)
      end)

      %{root: root}
    end

    test "removes only expired regular Python REPL spills", %{root: root, tmp_dir: tmp_dir} do
      expired = stale_file(root, "pi-python-repl-expired")
      recent = write_file(root, "pi-python-repl-recent")
      wrong_prefix = stale_file(root, "bash-output-expired")
      spill_directory = Path.join(root, "pi-python-repl-directory")
      File.mkdir!(spill_directory)

      symlink_target = Path.join(tmp_dir, "spill-symlink-target")
      File.write!(symlink_target, "target remains")
      File.touch!(symlink_target, System.os_time(:second) - 24 * 60 * 60 - 60)
      spill_symlink = Path.join(root, "pi-python-repl-symlink")
      File.ln_s!(symlink_target, spill_symlink)

      assert {:ok, ^root} = PrivateTmp.root()

      refute File.exists?(expired)
      assert File.read!(recent) == "contents"
      assert File.read!(wrong_prefix) == "contents"
      assert File.dir?(spill_directory)
      assert File.lstat!(spill_symlink).type == :symlink
      assert File.read!(symlink_target) == "target remains"
    end

    test "runs at most once per retention window", %{root: root} do
      first = stale_file(root, "pi-python-repl-first")

      assert {:ok, ^root} = PrivateTmp.root()
      refute File.exists?(first)

      second = stale_file(root, "pi-python-repl-second")

      assert {:ok, ^root} = PrivateTmp.root()
      assert File.exists?(second)

      :persistent_term.put(
        {PrivateTmp, :spill_sweep_at},
        System.monotonic_time(:second) - 24 * 60 * 60 - 1
      )

      assert {:ok, ^root} = PrivateTmp.root()
      refute File.exists?(second)
    end

    test "resumes the reaper after its bounded entry batch", %{root: root} do
      for index <- 1..1_001 do
        stale_file(root, "pi-python-repl-batch-#{index}")
      end

      assert {:ok, ^root} = PrivateTmp.root()
      assert [_remaining] = File.ls!(root)

      :persistent_term.put(
        {PrivateTmp, :spill_sweep_at},
        System.monotonic_time(:second) - 24 * 60 * 60 - 1
      )

      assert {:ok, ^root} = PrivateTmp.root()
      assert File.ls!(root) == []
    end

    test "keeps live spills until their capture finishes", %{root: root} do
      output =
        Output.new(10)
        |> Output.append(:stdout, String.duplicate("x", 11))

      path = output.spill_path
      File.touch!(path, System.os_time(:second) - 24 * 60 * 60 - 60)

      :persistent_term.put(
        {PrivateTmp, :spill_sweep_at},
        System.monotonic_time(:second) - 24 * 60 * 60 - 1
      )

      assert {:ok, ^root} = PrivateTmp.root()
      assert File.exists?(path)

      result = Output.finish(output)
      assert result.full_output_path == path

      :persistent_term.put(
        {PrivateTmp, :spill_sweep_at},
        System.monotonic_time(:second) - 24 * 60 * 60 - 1
      )

      assert {:ok, ^root} = PrivateTmp.root()
      refute File.exists?(path)
    end

    test "prunes spills when their tracking owner dies", %{root: root} do
      path = stale_file(root, "pi-python-repl-dead-owner")
      parent = self()

      owner =
        spawn(fn ->
          send(parent, {:live_spill_registered, PrivateTmp.register_live_spill(path)})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:live_spill_registered, :ok}
      force_sweep_window()
      assert {:ok, ^root} = PrivateTmp.root()
      assert File.exists?(path)

      monitor = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}

      force_sweep_window()
      assert {:ok, ^root} = PrivateTmp.root()
      refute File.exists?(path)
    end

    test "sweeps only dead-owner sibling roots once per node boot", %{tmp_dir: tmp_dir} do
      isolate_system_tmp(tmp_dir)

      {:ok, emptied_root} = PrivateTmp.reserve_dir(tmp_dir, "lemon-private-stale-empty")
      dead_owner_marker(emptied_root)
      stale_file(emptied_root, "pi-python-repl-expired")

      {:ok, nonempty_root} = PrivateTmp.reserve_dir(tmp_dir, "lemon-private-stale-nonempty")
      dead_owner_marker(nonempty_root)
      expired = stale_file(nonempty_root, "pi-python-repl-expired")
      recent = write_file(nonempty_root, "pi-python-repl-recent")
      wrong_prefix = stale_file(nonempty_root, "bash-output-expired")
      spill_directory = Path.join(nonempty_root, "pi-python-repl-directory")
      File.mkdir!(spill_directory)

      symlink_target = stale_file(tmp_dir, "expired-symlink-target")
      spill_symlink = Path.join(nonempty_root, "pi-python-repl-symlink")
      File.ln_s!(symlink_target, spill_symlink)

      {:ok, live_owner_root} = PrivateTmp.reserve_dir(tmp_dir, "lemon-private-live-owner")
      live_owner_marker(live_owner_root)
      live_owner_spill = stale_file(live_owner_root, "pi-python-repl-expired")

      {:ok, missing_owner_root} = PrivateTmp.reserve_dir(tmp_dir, "lemon-private-missing-owner")
      missing_owner_spill = stale_file(missing_owner_root, "pi-python-repl-expired")

      {:ok, current_root} = PrivateTmp.root()
      force_sweep_window()
      assert {:ok, ^current_root} = PrivateTmp.root()

      refute File.exists?(emptied_root)
      refute File.exists?(expired)
      assert File.read!(recent) == "contents"
      assert File.read!(wrong_prefix) == "contents"
      assert File.dir?(spill_directory)
      assert File.lstat!(spill_symlink).type == :symlink
      assert File.dir?(nonempty_root)
      assert File.exists?(live_owner_spill)
      assert File.exists?(missing_owner_spill)
    end
  end

  describe "reserve_dir/3" do
    test "reserves an exactly-0700 directory beneath the given parent" do
      {:ok, root} = PrivateTmp.root()
      {:ok, dir} = PrivateTmp.reserve_dir(root, "test-dir")
      on_exit(fn -> File.rm_rf(dir) end)

      assert Path.dirname(dir) == root
      assert String.starts_with?(Path.basename(dir), "test-dir")

      stat = File.lstat!(dir)
      assert stat.type == :directory
      assert band(stat.mode, 0o777) == 0o700
    end

    test "concurrent reservations are distinct" do
      {:ok, root} = PrivateTmp.root()

      dirs =
        1..8
        |> Task.async_stream(
          fn _ -> PrivateTmp.reserve_dir(root, "test-race") end,
          max_concurrency: 8,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, {:ok, dir}} -> dir end)

      assert length(dirs) == 8
      assert length(Enum.uniq(dirs)) == 8
      on_exit(fn -> Enum.each(dirs, &File.rm_rf/1) end)
    end
  end

  describe "reserve_file/3" do
    test "reserves an exactly-0600 empty regular file beneath the parent" do
      {:ok, root} = PrivateTmp.root()
      {:ok, file} = PrivateTmp.reserve_file(root, "test-file")
      on_exit(fn -> File.rm(file) end)

      assert Path.dirname(file) == root
      assert String.starts_with?(Path.basename(file), "test-file")

      stat = File.lstat!(file)
      assert stat.type == :regular
      assert band(stat.mode, 0o777) == 0o600
      assert File.read!(file) == ""
    end
  end

  describe "write_file/4" do
    setup do
      {:ok, root} = PrivateTmp.root()
      {:ok, parent} = PrivateTmp.reserve_dir(root, "test-write")
      on_exit(fn -> File.rm_rf(parent) end)
      {:ok, parent: parent}
    end

    test "publishes a named 0600 file with no reservation leftovers", %{parent: parent} do
      :ok = PrivateTmp.write_file(parent, "payload.txt", "secret bytes")

      path = Path.join(parent, "payload.txt")
      assert File.read!(path) == "secret bytes"
      assert band(File.stat!(path).mode, 0o777) == 0o600
      assert File.ls!(parent) == ["payload.txt"]
    end

    test "replaces a planted symlink at the final name instead of following it", %{
      parent: parent,
      tmp_dir: tmp_dir
    } do
      victim = Path.join(tmp_dir, "victim-#{System.unique_integer([:positive])}.txt")
      File.write!(victim, "untouched")
      on_exit(fn -> File.rm(victim) end)
      File.ln_s!(victim, Path.join(parent, "payload.txt"))

      :ok = PrivateTmp.write_file(parent, "payload.txt", "replacement")

      assert File.read!(victim) == "untouched"
      assert File.lstat!(Path.join(parent, "payload.txt")).type == :regular
      assert File.read!(Path.join(parent, "payload.txt")) == "replacement"
    end

    test "refuses a final name occupied by a directory and removes only its reservation", %{
      parent: parent
    } do
      File.mkdir!(Path.join(parent, "payload.txt"))

      assert {:error, _reason} = PrivateTmp.write_file(parent, "payload.txt", "x")

      # The planted directory is untouched; the reservation is gone.
      assert File.ls!(parent) == ["payload.txt"]
      assert File.dir?(Path.join(parent, "payload.txt"))
    end
  end

  describe "copy_file/4" do
    setup do
      {:ok, root} = PrivateTmp.root()
      {:ok, parent} = PrivateTmp.reserve_dir(root, "test-copy")
      on_exit(fn -> File.rm_rf(parent) end)
      {:ok, parent: parent}
    end

    test "keeps the reservation's 0600 mode instead of the source's mode", %{
      parent: parent,
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "source-#{System.unique_integer([:positive])}.py")
      File.write!(source, "print(1)\n")
      File.chmod!(source, 0o644)
      on_exit(fn -> File.rm(source) end)

      :ok = PrivateTmp.copy_file(source, parent, "runner.py")

      path = Path.join(parent, "runner.py")
      assert File.read!(path) == "print(1)\n"
      assert band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "a missing source returns the POSIX reason and leaves nothing behind", %{
      parent: parent
    } do
      assert {:error, :enoent} =
               PrivateTmp.copy_file(Path.join(parent, "does-not-exist.py"), parent, "runner.py")

      assert File.ls!(parent) == []
    end
  end

  describe "mktemp failure shapes fail closed" do
    setup do
      {:ok, root} = PrivateTmp.root()
      {:ok, parent} = PrivateTmp.reserve_dir(root, "test-fail")
      on_exit(fn -> File.rm_rf(parent) end)
      {:ok, parent: parent}
    end

    test "a missing mktemp executable", %{parent: parent} do
      assert {:error, {:mktemp_unavailable, _}} =
               PrivateTmp.reserve_dir(parent, "nope", mktemp: "/nonexistent-mktemp")

      assert {:error, {:mktemp_unavailable, _}} =
               PrivateTmp.reserve_file(parent, "nope", mktemp: "/nonexistent-mktemp")

      assert File.ls!(parent) == []
    end

    test "a nonzero mktemp exit", %{parent: parent} do
      false_path = System.find_executable("false") || flunk("false is required")

      assert {:error, {:mktemp_failed, _, _}} =
               PrivateTmp.reserve_dir(parent, "nope", mktemp: false_path)

      assert File.ls!(parent) == []
    end

    test "a relative mktemp output", %{parent: parent} do
      assert {:error, {:mktemp_relative_path, "not-a-path"}} =
               PrivateTmp.reserve_file(parent, "nope",
                 runner: fn _argv -> {"not-a-path\n", 0} end
               )

      assert File.ls!(parent) == []
    end

    test "an absolute mktemp output outside the parent is rejected, never deleted", %{
      parent: parent
    } do
      assert {:error, {:invalid_reservation_path, "/etc"}} =
               PrivateTmp.reserve_dir(parent, "nope", runner: fn _argv -> {"/etc\n", 0} end)

      # The claimed absolute path still exists: a rejected reservation never
      # authorizes deleting an unproven path.
      assert File.dir?("/etc")
      assert File.ls!(parent) == []
    end

    test "a multi-line mktemp output", %{parent: parent} do
      assert {:error, {:mktemp_unexpected_output, _}} =
               PrivateTmp.reserve_dir(parent, "nope", runner: fn _argv -> {"/etc\n/tmp\n", 0} end)

      assert File.ls!(parent) == []
    end
  end

  defp isolate_system_tmp(tmp_dir) do
    keys = [
      {PrivateTmp, :root},
      {PrivateTmp, :spill_sweep_at},
      {PrivateTmp, :spill_sweep_continuations},
      {PrivateTmp, :live_spills},
      {PrivateTmp, :stale_root_sweep_done},
      {PrivateTmp, :stale_roots}
    ]

    saved = Map.new(keys, &{&1, :persistent_term.get(&1, nil)})
    previous_tmp_dir = System.get_env("TMPDIR")

    System.put_env("TMPDIR", tmp_dir)
    Enum.each(keys, &:persistent_term.erase/1)

    on_exit(fn ->
      restore_tmp_dir(previous_tmp_dir)

      Enum.each(saved, fn
        {key, nil} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)
  end

  defp restore_tmp_dir(nil), do: System.delete_env("TMPDIR")
  defp restore_tmp_dir(path), do: System.put_env("TMPDIR", path)

  defp dead_owner_marker(root) do
    :ok = PrivateTmp.write_file(root, ".lemon-owner", "stale@node\n999999\n")
  end

  defp live_owner_marker(root) do
    :ok = PrivateTmp.write_file(root, ".lemon-owner", "#{node()}\n#{System.pid()}\n")
  end

  defp force_sweep_window do
    :persistent_term.put(
      {PrivateTmp, :spill_sweep_at},
      System.monotonic_time(:second) - 24 * 60 * 60 - 1
    )
  end

  defp stale_file(root, name) do
    path = write_file(root, name)
    File.touch!(path, System.os_time(:second) - 24 * 60 * 60 - 60)
    path
  end

  defp write_file(root, name) do
    path = Path.join(root, name)
    File.write!(path, "contents")
    path
  end
end
