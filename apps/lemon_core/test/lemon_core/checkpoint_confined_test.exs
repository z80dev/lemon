defmodule LemonCore.CheckpointConfinedTest do
  @moduledoc """
  NEW-6 regressions: a concurrent writer that swaps a checked parent directory
  for a symlink while a restore runs must not redirect the restore's removal,
  writes or chmods outside the captured root.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Checkpoint
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "root")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(Path.join(root, "ws/sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "file.txt"), "outside sentinel\n")
    File.write!(Path.join(outside, "keep.txt"), "keep\n")
    File.chmod!(outside, 0o755)
    session_id = "confined-#{System.unique_integer([:positive])}"
    on_exit(fn -> Checkpoint.delete_all(session_id) end)
    %{root: root, outside: outside, session_id: session_id}
  end

  defp outside_state(outside) do
    {File.ls!(outside) |> Enum.sort(), File.read!(Path.join(outside, "file.txt")),
     File.read!(Path.join(outside, "keep.txt")), File.lstat!(outside).mode}
  end

  # Swap `sub` for a symlink to `outside` once, at the first file-server request
  # matching `trigger?` (the last path check before the vulnerable operation).
  defp swap_hook(sub, outside, trigger?) do
    fn request ->
      path = FileServerTap.path(request)

      if is_binary(path) and trigger?.(request, path) and !Process.get(:swapped) do
        Process.put(:swapped, true)
        FileServerTap.swap_for_symlink(sub, outside)
      end
    end
  end

  # Swap `sub` for a symlink to `outside` before the leaf lstat and swap it back
  # before the parent re-walk, so path-based reads pass every check while
  # reading the outside file.
  defp swap_and_back_hook(sub, target, outside) do
    fn request ->
      case {elem(request, 0), FileServerTap.path(request), Process.get(:swap_state)} do
        {:read_link_info, ^target, nil} ->
          Process.put(:swap_state, :swapped)
          FileServerTap.swap_for_symlink(sub, outside)

        {:read_link_info, ^sub, :swapped} ->
          Process.put(:swap_state, :done)
          FileServerTap.restore(sub)

        _ ->
          :ok
      end
    end
  end

  defp secret_setup(root, outside) do
    sub = Path.join(root, "ws/sub")
    target = Path.join(sub, "file.txt")
    File.write!(target, "inside\n")
    File.write!(Path.join(outside, "file.txt"), "SECRET outside\n")
    {sub, target}
  end

  test "capture never stores content read through a parent swapped mid-capture",
       %{root: root, outside: outside, session_id: session_id} do
    {sub, target} = secret_setup(root, outside)

    result =
      FileServerTap.with_tap(swap_and_back_hook(sub, target, outside), fn ->
        Checkpoint.create_filesystem(session_id, [target], cwd: root)
      end)

    if File.exists?(sub <> ".moved"), do: FileServerTap.restore(sub)

    case result do
      {:ok, checkpoint} ->
        refute inspect(checkpoint, limit: :infinity) =~ "SECRET"
        refute inspect(checkpoint, limit: :infinity) =~ Base.encode64("SECRET outside\n")
        [snapshot] = checkpoint.state.filesystem.files
        assert Base.decode64!(snapshot.content_b64) == "inside\n"

      {:error, _} ->
        :ok
    end
  end

  test "diff never returns content read through a parent swapped mid-diff",
       %{root: root, outside: outside, session_id: session_id} do
    {sub, target} = secret_setup(root, outside)
    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [target], cwd: root)
    File.write!(target, "inside edited\n")

    result =
      FileServerTap.with_tap(swap_and_back_hook(sub, target, outside), fn ->
        Checkpoint.diff_filesystem(checkpoint.id, session_id)
      end)

    if File.exists?(sub <> ".moved"), do: FileServerTap.restore(sub)

    refute inspect(result, limit: :infinity) =~ "SECRET"
    assert {:ok, %{output: output}} = result
    assert output =~ "+inside edited"
  end

  test "fingerprints of checkpoints with File.lstat modes still match an unchanged tree",
       %{root: root, session_id: session_id} do
    ws = Path.join(root, "ws")
    File.write!(Path.join(ws, "sub/a.txt"), "a\n")
    File.chmod!(Path.join(ws, "sub/a.txt"), 0o640)
    File.ln_s!("sub/a.txt", Path.join(ws, "link"))

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [ws], cwd: root)
    [%{entries: entries, mode: ws_mode}] = checkpoint.state.filesystem.files
    assert ws_mode == File.lstat!(ws).mode
    sub_entry = Enum.find(entries, &(&1.name == "sub"))
    assert sub_entry.snapshot.mode == File.lstat!(Path.join(ws, "sub")).mode
    [a] = sub_entry.snapshot.entries
    assert a.snapshot.mode == File.lstat!(Path.join(ws, "sub/a.txt")).mode

    assert {:ok, %{changed: [], output: "No filesystem changes since checkpoint."}} =
             Checkpoint.diff_filesystem(checkpoint.id, session_id)
  end

  test "restoring a file root never writes through a parent swapped mid-restore",
       %{root: root, outside: outside, session_id: session_id} do
    sub = Path.join(root, "ws/sub")
    target = Path.join(sub, "file.txt")
    File.write!(target, "checkpointed\n")

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [target], cwd: root)
    File.write!(target, "edited\n")
    before = outside_state(outside)

    # The last path check before the write is the lstat of the leaf.
    hook = swap_hook(sub, outside, fn _request, path -> path == target end)

    result =
      FileServerTap.with_tap(hook, fn -> Checkpoint.trusted_restore_filesystem(checkpoint.id) end)

    if File.exists?(sub <> ".moved"), do: FileServerTap.restore(sub)

    assert outside_state(outside) == before
    assert {:ok, %{restored: [^target]}} = result
    assert File.read!(target) == "checkpointed\n"
  end

  test "removing a directory root never deletes through a subdirectory swapped mid-removal",
       %{root: root, outside: outside, session_id: session_id} do
    ws = Path.join(root, "ws")
    sub = Path.join(ws, "sub")
    File.write!(Path.join(sub, "a.txt"), "a\n")
    File.chmod!(sub, 0o750)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [ws], cwd: root)
    File.write!(Path.join(sub, "a.txt"), "changed\n")
    File.write!(Path.join(sub, "new.txt"), "new\n")
    before = outside_state(outside)

    # Removal lists `sub` before deleting its children.
    hook =
      swap_hook(sub, outside, fn request, path ->
        elem(request, 0) == :list_dir and path == sub
      end)

    result =
      FileServerTap.with_tap(hook, fn ->
        Checkpoint.restore_filesystem(checkpoint.id, session_id)
      end)

    if File.exists?(sub <> ".moved"), do: FileServerTap.restore(sub)

    assert outside_state(outside) == before
    assert {:ok, %{restored: [^ws]}} = result
    assert File.ls!(sub) == ["a.txt"]
    assert File.read!(Path.join(sub, "a.txt")) == "a\n"
    assert Bitwise.band(File.lstat!(sub).mode, 0o777) == 0o750
  end
end
