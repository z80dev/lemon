defmodule LemonCore.ConfinedFSTest do
  use ExUnit.Case, async: true

  alias LemonCore.ConfinedFS
  alias LemonCore.ConfinedFS.Stat

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(Path.join(root, "sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "outside secret")
    {:ok, fs} = ConfinedFS.open(root)
    on_exit(fn -> ConfinedFS.close(fs) end)
    %{fs: fs, root: root, outside: outside}
  end

  describe "paths" do
    test "split refuses traversal, absolute paths and NUL" do
      assert {:ok, ["a", "b"]} = ConfinedFS.split("a/./b/")
      assert {:error, :einval} = ConfinedFS.split("a/../b")
      assert {:error, :einval} = ConfinedFS.split("/etc/passwd")
      assert {:error, :einval} = ConfinedFS.split("a\0b")
    end

    test "beneath splits a path below a root lexically" do
      assert {:ok, []} = ConfinedFS.beneath("/a/b", "/a/b")
      assert {:ok, ["c", "d"]} = ConfinedFS.beneath("/a/b", "/a/b/c/d")
      assert {:ok, ["a", "b"]} = ConfinedFS.beneath("/", "/a/b")
      assert :error = ConfinedFS.beneath("/a/b", "/a/bc")
      assert :error = ConfinedFS.beneath("/a/b", "/a/b/../c")
    end

    test "invalid components never reach the helper", %{fs: fs} do
      for name <- ["", ".", "..", "a/b", "a\0b", String.duplicate("x", 256)] do
        assert {:error, :einval} = ConfinedFS.open_dir(fs, :root, [name])
        assert {:error, :einval} = ConfinedFS.read(fs, :root, name, 10)
        assert {:error, :einval} = ConfinedFS.replace(fs, :root, name, "x")
      end
    end

    test "the root must be an absolute directory" do
      assert {:error, :einval} = ConfinedFS.open("relative")
      assert {:error, :enoent} = ConfinedFS.open("/nonexistent-lemon-confined-root")
    end
  end

  describe "operations" do
    test "create, read, replace and overwrite regular files", %{fs: fs, root: root} do
      {:ok, sub} = ConfinedFS.open_dir(fs, :root, ["sub"])
      assert {:ok, %Stat{type: :regular, size: 5}} = ConfinedFS.create(fs, sub, "a.txt", "hello")
      assert {:error, :eexist} = ConfinedFS.create(fs, sub, "a.txt", "again")
      assert {:ok, "hello", %Stat{} = stat} = ConfinedFS.read(fs, sub, "a.txt", 100)
      assert {:error, :too_large} = ConfinedFS.read(fs, sub, "a.txt", 4)
      assert {:ok, "hell", %Stat{size: 5}} = ConfinedFS.read(fs, sub, "a.txt", 4, prefix: true)
      assert {:ok, "hello", _} = ConfinedFS.read(fs, sub, "a.txt", 5, prefix: true)

      assert {:ok, %Stat{} = replaced} =
               ConfinedFS.replace(fs, sub, "a.txt", ["new ", "content"], expect: stat)

      refute Stat.same_object?(replaced, stat)
      assert File.read!(Path.join(root, "sub/a.txt")) == "new content"
      assert {:error, :changed} = ConfinedFS.replace(fs, sub, "a.txt", "x", expect: stat)
      assert {:error, :eexist} = ConfinedFS.replace(fs, sub, "a.txt", "x", expect: :absent)

      assert {:ok, %Stat{} = overwritten} =
               ConfinedFS.overwrite(fs, sub, "a.txt", "short", expect: replaced)

      assert Stat.same_object?(overwritten, replaced)
      assert File.read!(Path.join(root, "sub/a.txt")) == "short"
      assert {:error, :enoent} = ConfinedFS.overwrite(fs, sub, "missing", "x")
      assert {:ok, _} = ConfinedFS.replace(fs, sub, "fresh", "x", expect: :absent)
      refute Enum.any?(File.ls!(Path.join(root, "sub")), &String.starts_with?(&1, ".lemon-tmp"))
    end

    test "exact and preserved modes", %{fs: fs, root: root} do
      assert {:ok, %Stat{mode: 0o600}} =
               ConfinedFS.create(fs, :root, "m", "x", mode: 0o600, exact_mode: true)

      assert {:ok, %Stat{mode: 0o600}} =
               ConfinedFS.replace(fs, :root, "m", "y", preserve_mode: true)

      assert File.stat!(Path.join(root, "m")).mode |> Bitwise.band(0o777) == 0o600
    end

    test "directories, listing, rename, chmod, links and removal", %{fs: fs, root: root} do
      assert {:ok, deep} = ConfinedFS.open_dir(fs, :root, ["a", "b", "c"], create: true)
      assert {:ok, _} = ConfinedFS.create(fs, deep, "f", "1")
      assert :ok = ConfinedFS.mkdir(fs, :root, "d")
      assert {:error, :eexist} = ConfinedFS.mkdir(fs, :root, "d")
      assert :ok = ConfinedFS.symlink(fs, :root, "link", "/etc")
      assert {:ok, "/etc"} = ConfinedFS.readlink(fs, :root, "link")
      assert {:ok, %Stat{type: :symlink}} = ConfinedFS.stat(fs, :root, "link")
      assert {:ok, %Stat{type: :directory}} = ConfinedFS.stat(fs, deep)

      assert {:ok, entries} = ConfinedFS.list(fs, :root)
      assert Enum.sort(Enum.map(entries, &elem(&1, 0))) == ~w(a d link sub)
      assert {:error, :too_many} = ConfinedFS.list(fs, :root, max_entries: 2)
      assert {:ok, [{"link", %Stat{}}]} = ConfinedFS.list(fs, :root, prefix: "li")

      assert :ok = ConfinedFS.rename(fs, deep, "f", :root, "g")
      assert File.read!(Path.join(root, "g")) == "1"
      assert {:ok, _} = ConfinedFS.create(fs, :root, "h", "2")
      assert {:error, :eexist} = ConfinedFS.rename(fs, :root, "g", :root, "h", no_replace: true)
      assert :ok = ConfinedFS.chmod(fs, :root, "g", 0o640)
      assert {:ok, %Stat{mode: 0o640}} = ConfinedFS.stat(fs, :root, "g")
      assert {:error, :symlink} = ConfinedFS.chmod(fs, :root, "link", 0o600)
      assert {:error, :eisdir} = ConfinedFS.unlink(fs, :root, "d")
      assert :ok = ConfinedFS.rmdir(fs, :root, "d")
      assert :ok = ConfinedFS.unlink(fs, :root, "link")
      assert File.dir?("/etc")

      File.chmod!(Path.join(root, "a/b"), 0o500)
      assert :ok = ConfinedFS.remove_tree(fs, :root, "a")
      refute File.exists?(Path.join(root, "a"))
      assert :ok = ConfinedFS.close_dir(fs, deep)
      assert {:error, :bad_handle} = ConfinedFS.stat(fs, deep)
    end

    test "reads refuse FIFOs without blocking and refuse special files", %{fs: fs, root: root} do
      fifo = Path.join(root, "fifo")
      {_, 0} = System.cmd("mkfifo", [fifo])
      assert {:error, :not_regular} = ConfinedFS.read(fs, :root, "fifo", 10)
      assert {:error, :not_regular} = ConfinedFS.overwrite(fs, :root, "fifo", "x")
      assert {:error, :not_regular} = ConfinedFS.replace(fs, :root, "fifo", "x")
      assert {:error, :eisdir} = ConfinedFS.replace(fs, :root, "sub", "x")
    end
  end

  describe "symlinks below the root" do
    test "are refused in every walked component and leaf", %{fs: fs, root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "out"))
      File.ln_s!(Path.join(outside, "secret"), Path.join(root, "secret-link"))
      File.mkdir_p!(Path.join(root, "sub/inner"))
      File.ln_s!(outside, Path.join(root, "sub/inner/out"))

      assert {:error, :symlink} = ConfinedFS.open_dir(fs, :root, ["out"])
      assert {:error, :symlink} = ConfinedFS.open_dir(fs, :root, ["sub", "inner", "out", "x"])

      assert {:error, :symlink} =
               ConfinedFS.open_dir(fs, :root, ["out", "new"], create: true)

      assert {:error, :symlink} = ConfinedFS.read(fs, :root, "secret-link", 100)
      assert {:error, :symlink} = ConfinedFS.overwrite(fs, :root, "secret-link", "x")
      assert {:error, :symlink} = ConfinedFS.replace(fs, :root, "secret-link", "x")
      assert {:error, :eexist} = ConfinedFS.create(fs, :root, "secret-link", "x")

      assert :ok = ConfinedFS.remove_tree(fs, :root, "out")
      assert File.read!(Path.join(outside, "secret")) == "outside secret"
      refute File.exists?(Path.join(outside, "new"))
    end

    test "the root path itself may be reached through a symlink", %{tmp_dir: tmp, root: root} do
      alias_root = Path.join(tmp, "alias")
      File.ln_s!(root, alias_root)

      assert :ok =
               ConfinedFS.with_root(alias_root, fn fs ->
                 {:ok, _} = ConfinedFS.create(fs, :root, "via-alias", "x")
                 :ok
               end)

      assert File.read!(Path.join(root, "via-alias")) == "x"
    end
  end

  describe "deterministic swap after the walk" do
    # The attacker replaces a walked directory with a symlink to an outside
    # directory after the handle was opened. Every operation stays bound to
    # the original directory (now at sub.moved), never the symlink target.
    setup %{fs: fs, root: root, outside: outside} do
      File.write!(Path.join(root, "sub/inside"), "inside")
      File.write!(Path.join(outside, "inside"), "outside copy")
      {:ok, sub} = ConfinedFS.open_dir(fs, :root, ["sub"])
      :ok = :prim_file.rename(Path.join(root, "sub"), Path.join(root, "sub.moved"))
      :ok = :prim_file.make_symlink(outside, Path.join(root, "sub"))
      %{sub: sub, moved: Path.join(root, "sub.moved")}
    end

    test "reads, writes, renames and removals stay in the walked directory",
         %{fs: fs, sub: sub, moved: moved, outside: outside} do
      assert {:ok, "inside", _} = ConfinedFS.read(fs, sub, "inside", 100)
      assert {:error, :enoent} = ConfinedFS.read(fs, sub, "secret", 100)
      assert {:ok, _} = ConfinedFS.replace(fs, sub, "written", "payload")
      assert {:ok, _} = ConfinedFS.create(fs, sub, "created", "payload")
      assert :ok = ConfinedFS.rename(fs, sub, "created", sub, "renamed")
      assert :ok = ConfinedFS.unlink(fs, sub, "inside")
      assert :ok = ConfinedFS.mkdir(fs, sub, "dir")

      assert File.read!(Path.join(moved, "written")) == "payload"
      assert File.read!(Path.join(moved, "renamed")) == "payload"
      assert File.dir?(Path.join(moved, "dir"))
      assert Enum.sort(File.ls!(outside)) == ["inside", "secret"]
      assert File.read!(Path.join(outside, "inside")) == "outside copy"
    end

    test "a fresh walk through the swapped path is refused", %{fs: fs, outside: outside} do
      assert {:error, :symlink} = ConfinedFS.open_dir(fs, :root, ["sub"])
      assert {:error, :symlink} = ConfinedFS.open_dir(fs, :root, ["sub", "x"], create: true)
      assert :ok = ConfinedFS.remove_tree(fs, :root, "sub")
      assert File.read!(Path.join(outside, "secret")) == "outside secret"
    end
  end

  describe "sessions" do
    test "the helper session stops with its owner" do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, fs} = ConfinedFS.open(System.tmp_dir!())
          send(parent, {:session, fs.server})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:session, server}
      ref = Process.monitor(server)
      send(owner, :stop)
      assert_receive {:DOWN, ^ref, :process, ^server, _}
    end

    test "the session stops when its owner exits during a request", %{tmp_dir: tmp, root: root} do
      {notify, resume} = fifos(tmp)
      parent = self()

      owner =
        spawn(fn ->
          {:ok, fs} = ConfinedFS.open(root, stage_hook: {notify, resume})
          send(parent, {:session, fs.server})
          ConfinedFS.replace(fs, :root, "blocked", "x")
        end)

      assert_receive {:session, server}
      ref = Process.monitor(server)
      _stage = await_stage(notify)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server, _}, 2_000
      File.write!(resume, "x")
    end

    test "a missing helper fails closed" do
      assert {:error, :helper_unavailable} =
               ConfinedFS.Session.start("/nonexistent/lemon_confined_fs", self())
    end

    test "the compiled helper is available" do
      assert ConfinedFS.available?()
    end
  end

  describe "replace staging" do
    # The test-only stage hook pauses each replace after the staged contents
    # are written and before the mode is set or the file is published.
    setup %{tmp_dir: tmp, root: root} do
      {notify, resume} = fifos(tmp)
      {:ok, hooked} = ConfinedFS.open(root, stage_hook: {notify, resume})
      on_exit(fn -> ConfinedFS.close(hooked) end)
      %{hooked: hooked, notify: notify, resume: resume}
    end

    test "a private file's replacement is never readable by others while staged",
         %{hooked: fs, root: root, notify: notify, resume: resume} do
      target = Path.join(root, "private.zip")
      File.write!(target, "old archive")
      File.chmod!(target, 0o600)

      task =
        Task.async(fn ->
          ConfinedFS.replace(fs, :root, "private.zip", "new archive", preserve_mode: true)
        end)

      stage = Path.join(root, await_stage(notify))
      assert %File.Stat{type: :directory, mode: dir_mode} = File.lstat!(stage)
      assert Bitwise.band(dir_mode, 0o777) == 0o700
      assert %File.Stat{type: :regular, mode: file_mode} = File.lstat!(Path.join(stage, "f"))
      assert Bitwise.band(file_mode, 0o777) == 0o600
      File.write!(resume, "x")

      assert {:ok, %Stat{mode: 0o600}} = Task.await(task)
      assert File.read!(target) == "new archive"
      assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600
      refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".lemon-stage-"))
    end

    test "killing the staged credential writer leaves the previous file byte-identical",
         %{hooked: fs, root: root, notify: notify} do
      name = ".credentials.json"
      target = Path.join(root, name)
      original = ~s({ "claudeAiOauth": { "refreshToken": "fake-old" } }\n)
      replacement = ~s({"claudeAiOauth":{"refreshToken":"fake-new"}})
      File.write!(target, original)
      File.chmod!(target, 0o644)

      {helper, _owner_ref} = :sys.get_state(fs.server)
      session_ref = Process.monitor(fs.server)

      # A native reader can be killed even if the writer never opens the FIFO.
      # Do not block an OTP file I/O worker on the FIFO's open or read.
      reader =
        Port.open({:spawn_executable, System.find_executable("cat")}, [
          :binary,
          :exit_status,
          {:line, 256},
          args: [notify]
        ])

      task =
        Task.async(fn ->
          ConfinedFS.replace(fs, :root, name, replacement,
            mode: 0o600,
            exact_mode: true,
            sync: true
          )
        end)

      try do
        assert_receive {^reader, {:data, {:noeol, ".lemon-stage-" <> _ = stage}}}, 5_000
        staged = Path.join([root, stage, "f"])
        assert %File.Stat{type: :regular, mode: mode} = File.lstat!(staged)
        assert Bitwise.band(mode, 0o777) == 0o600
        assert File.read!(staged) == replacement
        assert File.read!(target) == original

        # Never open the resume FIFO. Kill the native writer rather than just
        # its BEAM caller, which cannot interrupt an open inside the helper.
        assert {"", 0} = kill_port_child(helper)
        assert {:error, :helper_failed} = Task.await(task)
        assert_receive {:DOWN, ^session_ref, :process, _, :normal}
        assert File.read!(target) == original
        assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o644
      after
        kill_port_child(helper)
        kill_port_child(reader)
      end
    end

    test "the final mode is applied before publication",
         %{hooked: fs, root: root, notify: notify, resume: resume} do
      task =
        Task.async(fn ->
          ConfinedFS.replace(fs, :root, "shared", "x", mode: 0o640, exact_mode: true)
        end)

      _stage = await_stage(notify)
      refute File.exists?(Path.join(root, "shared"))
      File.write!(resume, "x")
      assert {:ok, %Stat{mode: 0o640}} = Task.await(task)
      assert Bitwise.band(File.stat!(Path.join(root, "shared")).mode, 0o777) == 0o640
    end

    test "a staged file substituted before publication is never published",
         %{hooked: fs, root: root, notify: notify, resume: resume, outside: outside} do
      File.write!(Path.join(root, "target"), "original")
      task = Task.async(fn -> ConfinedFS.replace(fs, :root, "target", "lemon") end)

      staged = Path.join([root, await_stage(notify), "f"])
      File.rm!(staged)
      File.ln_s!(Path.join(outside, "secret"), staged)
      File.write!(resume, "x")

      assert {:error, :changed} = Task.await(task)
      assert {:ok, %File.Stat{type: :regular}} = File.lstat(Path.join(root, "target"))
      assert File.read!(Path.join(root, "target")) == "original"
      refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".lemon-stage-"))
    end

    test "expect: :absent never replaces an entry created before publication",
         %{hooked: fs, root: root, notify: notify, resume: resume} do
      task =
        Task.async(fn -> ConfinedFS.replace(fs, :root, "fresh", "lemon", expect: :absent) end)

      _stage = await_stage(notify)
      File.write!(Path.join(root, "fresh"), "theirs")
      File.write!(resume, "x")

      assert {:error, :eexist} = Task.await(task)
      assert File.read!(Path.join(root, "fresh")) == "theirs"
      refute Enum.any?(File.ls!(root), &String.starts_with?(&1, ".lemon-stage-"))
    end
  end

  describe "append" do
    test "creates, appends, binds identity and refuses symlinks", %{
      fs: fs,
      root: root,
      outside: outside
    } do
      assert {:ok, %Stat{mode: 0o600, size: 2} = stat} =
               ConfinedFS.append(fs, :root, "log", "a\n",
                 create: true,
                 mode: 0o600,
                 exact_mode: true
               )

      assert {:ok, %Stat{size: 4}} = ConfinedFS.append(fs, :root, "log", "b\n", expect: stat)
      assert File.read!(Path.join(root, "log")) == "a\nb\n"
      assert {:error, :enoent} = ConfinedFS.append(fs, :root, "missing", "x")

      File.ln_s!(Path.join(outside, "secret"), Path.join(root, "link"))
      assert {:error, :symlink} = ConfinedFS.append(fs, :root, "link", "x", create: true)
      assert File.read!(Path.join(outside, "secret")) == "outside secret"

      # A new inode (created before the old one is gone, so it cannot be reused).
      File.write!(Path.join(root, "log.new"), "other")
      File.rename!(Path.join(root, "log.new"), Path.join(root, "log"))
      assert {:error, :changed} = ConfinedFS.append(fs, :root, "log", "x", expect: stat)
    end
  end

  defp fifos(tmp) do
    notify = Path.join(tmp, "notify-#{System.unique_integer([:positive])}")
    resume = Path.join(tmp, "resume-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("mkfifo", [notify, resume])
    {notify, resume}
  end

  defp kill_port_child(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end
  end

  defp await_stage(notify) do
    {:ok, io} = File.open(notify, [:read, :binary])
    stage = IO.binread(io, :eof)
    File.close(io)
    stage
  end
end
