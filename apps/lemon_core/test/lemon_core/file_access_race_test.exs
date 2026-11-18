defmodule LemonCore.FileAccessRaceTest do
  # Deterministic directory-swap races (NEW-6): a concurrent writer inside the
  # root replaces a checked directory with a symlink to an outside directory
  # between FileAccess's checks and its I/O. FileServerTap performs the swap
  # at exactly that point for path-based code; descriptor-bound code performs
  # no path-based file-server I/O below the root at all.
  use ExUnit.Case, async: false

  alias LemonCore.FileAccess
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {:ok, base} = FileAccess.real_root(tmp)
    root = Path.join(base, "root")
    outside = Path.join(base, "outside")
    File.mkdir_p!(Path.join(root, "sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "sub/target.txt"), "inside")
    File.write!(Path.join(outside, "target.txt"), "outside secret")
    %{root: root, sub: Path.join(root, "sub"), outside: outside}
  end

  defp beneath?(path, dir), do: is_binary(path) and String.starts_with?(path, dir <> "/")

  # Records every file-server request below `root` and runs `swap` (once it
  # returns :swapped, it is not called again).
  defp swap_hook(root, swap) do
    test = self()

    fn request ->
      path = FileServerTap.path(request)

      if beneath?(path, root) or path == root do
        send(test, {:touched, elem(request, 0), path})

        unless Process.get(:done) do
          if swap.(request, path) == :swapped do
            Process.put(:done, true)
            send(test, :swapped)
          end
        end
      end
    end
  end

  defp touched do
    receive do
      {:touched, op, path} -> [{op, path} | touched()]
    after
      0 -> []
    end
  end

  test "an upload whose parent is swapped after the checks never lands outside the root",
       %{root: root, sub: sub, outside: outside} do
    hook =
      swap_hook(root, fn
        {:open, _path, _modes}, path ->
          if beneath?(path, sub) do
            FileServerTap.swap_for_symlink(sub, outside)
            :swapped
          end

        _request, _path ->
          nil
      end)

    result =
      FileServerTap.with_tap(hook, fn ->
        FileAccess.put(root, "sub/upload.txt", %{}, fn -> {:ok, "payload"} end, false, 1_000)
      end)

    assert Enum.sort(File.ls!(outside)) == ["target.txt"],
           "upload escaped the root: #{inspect(File.ls!(outside))} (result #{inspect(result)})"

    assert result == {:ok, "sub/upload.txt"}
    assert File.read!(Path.join(sub, "upload.txt")) == "payload"
    assert touched() == []
  end

  for {label, read} <- [
        {"read_file", quote(do: FileAccess.read_file(var!(root), "sub/target.txt", [], 1_000))},
        {"get", quote(do: FileAccess.get(var!(root), "sub/target.txt", %{}, 1_000))}
      ] do
    test "#{label} never returns a file reached through a parent swapped during the read",
         %{root: root, sub: sub, outside: outside} do
      target = Path.join(sub, "target.txt")
      test = self()

      # Swap just before the last leaf lstat (so the opened handle matches the
      # outside file), then swap back before the re-walk checks the parent.
      hook =
        fn request ->
          path = FileServerTap.path(request)
          if beneath?(path, root), do: send(test, {:touched, elem(request, 0), path})

          case {elem(request, 0), path} do
            {:read_link_info, ^target} ->
              count = Process.get(:leaf_lstats, 0) + 1
              Process.put(:leaf_lstats, count)

              if count == 3 do
                FileServerTap.swap_for_symlink(sub, outside)
                Process.put(:swapped, true)
                send(test, :swapped)
              end

            {:read_link_info, ^sub} ->
              if Process.get(:swapped) do
                FileServerTap.restore(sub)
                Process.delete(:swapped)
              end

            _ ->
              :ok
          end
        end

      result = FileServerTap.with_tap(hook, fn -> unquote(read) end)

      refute match?({:ok, _name, "outside secret"}, result),
             "read outside the root through a swapped parent: #{inspect(result)}"

      assert {:ok, "target.txt", "inside"} = result
      assert touched() == []
      assert File.read!(Path.join(outside, "target.txt")) == "outside secret"
    end
  end

  test "pruning outbound copies never follows a copy directory swapped for a symlink",
       %{outside: outside} do
    # retain_copy prunes stale `lemon-outbound-*` directories in the system
    # temp dir; a local user can rename their own stale directory to a
    # symlink between the lstat and the listing/removal.
    stale =
      Path.join(System.tmp_dir!(), "lemon-outbound-race-#{System.unique_integer([:positive])}")

    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "old"), "old copy")
    old = System.os_time(:second) - 2 * 24 * 60 * 60
    File.touch!(stale, old)
    on_exit(fn -> File.rm_rf(stale) end)
    on_exit(fn -> File.rm_rf(stale <> ".moved") end)
    test = self()

    hook = fn request ->
      path = FileServerTap.path(request)

      if is_binary(path) and (path == stale or beneath?(path, stale)) do
        send(test, {:touched, elem(request, 0), path})

        if elem(request, 0) == :list_dir and !Process.get(:done) do
          Process.put(:done, true)
          FileServerTap.swap_for_symlink(stale, outside)
          send(test, :swapped)
        end
      end
    end

    {:ok, copy} = FileServerTap.with_tap(hook, fn -> FileAccess.retain_copy("x.txt", "x") end)
    on_exit(fn -> File.rm_rf(Path.dirname(copy)) end)

    assert File.read!(Path.join(outside, "target.txt")) == "outside secret",
           "pruning removed a file outside the copy directory"

    refute Enum.any?(touched(), fn {op, _} -> op in [:delete, :del_dir, :list_dir] end)
  end
end
