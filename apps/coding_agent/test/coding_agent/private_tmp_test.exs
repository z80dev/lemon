defmodule CodingAgent.PrivateTmpTest do
  @moduledoc """
  The private-temp boundary behind every secret-bearing temporary object the
  coding agent creates: exact creation modes, containment, exclusive
  publication, and fail-closed behavior on every mktemp failure shape.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias CodingAgent.PrivateTmp

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
