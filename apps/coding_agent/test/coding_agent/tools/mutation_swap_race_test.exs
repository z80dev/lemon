defmodule CodingAgent.Tools.MutationSwapRaceTest do
  @moduledoc """
  Deterministic check-then-use races against the local mutation tools.

  `FileServerTap` swaps `root/sub/inner` for a symlink to a directory outside
  the workspace at an exact file-server request, the way a concurrent local
  writer could. Validation is path-based, so the swaps are placed after the
  last validation check; the tools' file I/O must then stay inside the
  workspace (descriptor-bound) or refuse.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{Edit, Patch, Write}
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    root = Path.join(tmp, "root")
    sub = Path.join(root, "sub")
    inner = Path.join(sub, "inner")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(inner)
    File.mkdir_p!(Path.join(root, "a"))
    File.mkdir_p!(outside)

    for dir <- [inner, outside],
        name <- ["target.txt", "gone.txt"],
        do: File.write!(Path.join(dir, name), "original\n")

    File.write!(Path.join(outside, "sentinel.txt"), "sentinel\n")
    File.write!(Path.join(root, "a/src.txt"), "original\n")

    %{
      root: root,
      sub: sub,
      inner: inner,
      outside: outside,
      opts: [filesystem_checkpoints: false]
    }
  end

  describe "write" do
    test "a new file in an existing directory stays inside the workspace", ctx do
      # Validation lstats new.txt, inner, then sub; the swap follows that last check.
      result =
        race(ctx, [{{:read_link_info, ctx.sub, 1}, :swap}], fn ->
          write(ctx, "sub/inner/new.txt", "planted\n")
        end)

      assert_refused(ctx, result)
    end

    test "overwriting an existing file stays inside the workspace", ctx do
      result =
        race(ctx, [{{:read_link_info, ctx.sub, 1}, :swap}], fn ->
          write(ctx, "sub/inner/target.txt", "changed\n")
        end)

      assert_refused(ctx, result)
    end

    for suffix <- ["zip", "tar"] do
      test "an existing #{suffix} archive member write stays inside the workspace", ctx do
        name = "bundle.#{unquote(suffix)}"
        archive(Path.join(ctx.inner, name), "inside")
        archive(Path.join(ctx.outside, name), "outside")

        result =
          race(ctx, [{{:read_link_info, ctx.sub, 1}, :swap}], fn ->
            write(ctx, "sub/inner/#{name}:member.txt", "planted")
          end)

        assert_refused(ctx, result)
      end
    end
  end

  describe "edit" do
    test "a pinned source cannot be redirected by swapping around validation", ctx do
      target = Path.join(ctx.inner, "target.txt")

      # Swap before the source is pinned, restore for validation, and swap
      # again right after validation's last parent check. A descriptor-bound
      # pin is not redirected, so validation then sees the swap. The first
      # `sub` lstat is a component walk that runs while the first swap is in
      # place; validation's last parent check is the second.
      steps = [
        {{:read_link_info, target, 1}, :swap},
        {{:read_link_info, target, 2}, :restore},
        {{:read_link_info, ctx.sub, 2}, :swap}
      ]

      assert_refused(ctx, race(ctx, steps, fn -> edit(ctx) end))
    end

    test "a swap after validation is refused by the pinned read and write", ctx do
      # The target's access stat is validation's last check.
      target = Path.join(ctx.inner, "target.txt")
      result = race(ctx, [{{:read_file_info, target, 1}, :swap}], fn -> edit(ctx) end)

      assert_refused(ctx, result)
      assert File.read!(ctx.inner <> ".moved/target.txt") == "original\n"
    end
  end

  describe "patch" do
    test "an update stays inside the workspace", ctx do
      target = Path.join(ctx.inner, "target.txt")

      # The first lstat of the target is preflight validation, the second pins
      # the source and the sixth starts the commit-time recheck.
      steps = [
        {{:read_link_info, target, 2}, :swap},
        {{:read_link_info, target, 6}, :restore},
        {{:read_link_info, ctx.sub, 2}, :swap}
      ]

      result =
        race(ctx, steps, fn ->
          patch(ctx, "*** Update File: sub/inner/target.txt\n@@\n-original\n+patched\n")
        end)

      assert_refused(ctx, result)
    end

    test "an update swapped after the commit-time recheck is refused", ctx do
      # Preflight stats the target three times; the fourth is the recheck's.
      target = Path.join(ctx.inner, "target.txt")

      result =
        race(ctx, [{{:read_file_info, target, 4}, :swap}], fn ->
          patch(ctx, "*** Update File: sub/inner/target.txt\n@@\n-original\n+patched\n")
        end)

      assert_refused(ctx, result)
    end

    test "a delete stays inside the workspace", ctx do
      gone = Path.join(ctx.inner, "gone.txt")

      steps = [
        {{:read_link_info, gone, 2}, :swap},
        {{:read_link_info, gone, 6}, :restore},
        {{:read_link_info, ctx.sub, 2}, :swap}
      ]

      result = race(ctx, steps, fn -> patch(ctx, "*** Delete File: sub/inner/gone.txt\n") end)

      assert_refused(ctx, result)
    end

    test "a delete swapped after the commit-time recheck is refused", ctx do
      # Preflight stats the source twice; the third is the recheck's.
      gone = Path.join(ctx.inner, "gone.txt")

      result =
        race(ctx, [{{:read_file_info, gone, 3}, :swap}], fn ->
          patch(ctx, "*** Delete File: sub/inner/gone.txt\n")
        end)

      assert_refused(ctx, result)
      assert File.exists?(ctx.inner <> ".moved/gone.txt")
    end

    test "an added file stays inside the workspace", ctx do
      # The second lstat of sub is the commit-time recheck before the create.
      result =
        race(ctx, [{{:read_link_info, ctx.sub, 2}, :swap}], fn ->
          patch(ctx, "*** Add File: sub/inner/added.txt\n+planted\n")
        end)

      assert_refused(ctx, result)
    end

    test "a move destination stays inside the workspace and keeps the source", ctx do
      result =
        race(ctx, [{{:read_link_info, ctx.sub, 2}, :swap}], fn ->
          patch(
            ctx,
            "*** Update File: a/src.txt\n*** Move to: sub/inner/moved.txt\n@@\n-original\n+moved\n"
          )
        end)

      assert_refused(ctx, result)
      assert File.read!(Path.join(ctx.root, "a/src.txt")) == "original\n"
    end
  end

  defp edit(ctx) do
    Edit.execute(
      "edit",
      %{"path" => "sub/inner/target.txt", "old_text" => "original", "new_text" => "edited"},
      nil,
      nil,
      ctx.root,
      ctx.opts
    )
  end

  defp write(ctx, path, content) do
    Write.execute("write", %{"path" => path, "content" => content}, nil, nil, ctx.root, ctx.opts)
  end

  defp patch(ctx, body) do
    Patch.execute(
      "patch",
      %{"patch_text" => "*** Begin Patch\n" <> body <> "*** End Patch"},
      nil,
      nil,
      ctx.root,
      ctx.opts
    )
  end

  defp archive(path, content) do
    files = [{~c"member.txt", content}]

    if String.ends_with?(path, ".zip"),
      do: {:ok, _} = :zip.create(String.to_charlist(path), files),
      else: :ok = :erl_tar.create(String.to_charlist(path), files)
  end

  # Runs `fun` with a tap that performs each step's action (`:swap` or
  # `:restore` of `inner`) just before the step's nth `{op, path}` request is
  # served. Steps run in order; each one reports itself to the test process.
  defp race(ctx, steps, fun) do
    test = self()
    before = tree(ctx.outside)

    hook = fn request ->
      key = {elem(request, 0), FileServerTap.path(request)}
      count = (Process.get(key) || 0) + 1
      Process.put(key, count)

      case Process.get(:steps, steps) do
        [{{op, path, ^count}, action} | rest] when key == {op, path} ->
          if action == :swap,
            do: FileServerTap.swap_for_symlink(ctx.inner, ctx.outside),
            else: FileServerTap.restore(ctx.inner)

          send(test, {:race, action})
          Process.put(:steps, rest)

        _ ->
          :ok
      end
    end

    result = FileServerTap.with_tap(hook, fun)
    {result, before}
  end

  defp assert_refused(ctx, {result, before}) do
    assert_received {:race, :swap}
    assert tree(ctx.outside) == before
    assert {:error, message} = result
    assert message =~ "symlink"
  end

  defp tree(dir) do
    dir
    |> File.ls!()
    |> Map.new(&{&1, File.read!(Path.join(dir, &1))})
  end
end
