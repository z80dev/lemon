defmodule CodingAgent.Tools.Lsp.WorkspaceEditSwapTest do
  @moduledoc """
  Deterministic check-then-use races against `WorkspaceEdit.apply/5`, the
  function the `lsp` tool applies language-server edits with.

  `FileServerTap` swaps `root/sub/inner` for a symlink to a directory outside
  the workspace right after validation's last check, the way a concurrent
  local writer could. Every read, write, create, rename and delete must then
  stay inside the workspace (descriptor-bound) or refuse.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.Tools.Lsp.{Text, WorkspaceEdit}
  alias LemonPlatformTest.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    tmp = Text.realpath(tmp)
    root = Path.join(tmp, "root")
    sub = Path.join(root, "sub")
    inner = Path.join(sub, "inner")
    outside = Path.join(tmp, "outside")

    for dir <- [inner, outside] do
      File.mkdir_p!(Path.join(dir, "tree"))
      File.write!(Path.join(dir, "target.c"), "original\n")
      File.write!(Path.join(dir, "gone.c"), "original\n")
      File.write!(Path.join(dir, "tree/x.c"), "original\n")
    end

    File.mkdir_p!(Path.join(root, "a"))
    File.write!(Path.join(root, "a/src.c"), "source\n")
    File.write!(Path.join(outside, "sentinel.txt"), "sentinel\n")
    %{root: root, sub: sub, inner: inner, outside: outside}
  end

  test "a text edit swapped after validation stays inside the workspace", ctx do
    target = Path.join(ctx.inner, "target.c")

    change = %{
      "textDocument" => %{"uri" => Text.path_to_uri(target)},
      "edits" => [
        %{
          "range" => %{
            "start" => %{"line" => 0, "character" => 0},
            "end" => %{"line" => 0, "character" => 8}
          },
          "newText" => "planted"
        }
      ]
    }

    # The target's access stat is validation's last check.
    assert_refused(ctx, race(ctx, {:read_file_info, target}, [change]))
    assert File.read!(Path.join(ctx.inner <> ".moved", "target.c")) == "original\n"
  end

  test "a file delete swapped after validation stays inside the workspace", ctx do
    gone = Path.join(ctx.inner, "gone.c")
    change = %{"kind" => "delete", "uri" => Text.path_to_uri(gone)}

    assert_refused(ctx, race(ctx, {:read_file_info, gone}, [change]))
    assert File.exists?(Path.join(ctx.inner <> ".moved", "gone.c"))
  end

  test "a recursive delete swapped after validation stays inside the workspace", ctx do
    change = %{
      "kind" => "delete",
      "uri" => Text.path_to_uri(Path.join(ctx.inner, "tree")),
      "options" => %{"recursive" => true}
    }

    # Directory validation ends with the lstat of `sub`.
    assert_refused(ctx, race(ctx, {:read_link_info, ctx.sub}, [change]))
    assert File.exists?(Path.join(ctx.inner <> ".moved", "tree/x.c"))
  end

  test "a rename into a directory swapped after validation stays inside", ctx do
    source = Path.join(ctx.root, "a/src.c")

    change = %{
      "kind" => "rename",
      "oldUri" => Text.path_to_uri(source),
      "newUri" => Text.path_to_uri(Path.join(ctx.inner, "moved.c"))
    }

    # The destination is validated last; its walk ends with the lstat of `sub`.
    assert_refused(ctx, race(ctx, {:read_link_info, ctx.sub}, [change]))
    assert File.read!(source) == "source\n"
  end

  test "a create swapped after validation stays inside the workspace", ctx do
    change = %{"kind" => "create", "uri" => Text.path_to_uri(Path.join(ctx.inner, "new.c"))}

    assert_refused(ctx, race(ctx, {:read_link_info, ctx.sub}, [change]))
    refute File.exists?(Path.join(ctx.inner <> ".moved", "new.c"))
  end

  describe "a rename destination that appears after the existence check" do
    # `before_rename` runs after the destination lookup and just before the
    # rename: a concurrent writer creates the destination there.
    defp rename_racing_destination(ctx, options) do
      source = Path.join(ctx.root, "a/src.c")
      dest = Path.join(ctx.root, "a/dest.c")

      change =
        Map.merge(
          %{
            "kind" => "rename",
            "oldUri" => Text.path_to_uri(source),
            "newUri" => Text.path_to_uri(dest)
          },
          if(options == %{}, do: %{}, else: %{"options" => options})
        )

      {:ok, ops} = WorkspaceEdit.plan(%{"documentChanges" => [change]})
      test = self()

      appear = fn ->
        File.write!(dest, "theirs\n")
        send(test, :appeared)
      end

      opts = [filesystem_checkpoints: false, before_rename: appear]
      result = WorkspaceEdit.apply(ops, ctx.root, opts, nil, %{tool: "lsp"})
      assert_received :appeared
      {result, source, dest}
    end

    test "is not replaced without overwrite", ctx do
      {result, source, dest} = rename_racing_destination(ctx, %{})
      assert {:error, message} = result
      assert message =~ "already exists"
      assert File.read!(dest) == "theirs\n"
      assert File.read!(source) == "source\n"
    end

    test "is left alone with ignoreIfExists", ctx do
      {result, source, dest} = rename_racing_destination(ctx, %{"ignoreIfExists" => true})
      assert {:ok, _} = result
      assert File.read!(dest) == "theirs\n"
      assert File.read!(source) == "source\n"
    end

    test "is replaced only when overwrite is explicit", ctx do
      {result, source, dest} = rename_racing_destination(ctx, %{"overwrite" => true})
      assert {:ok, _} = result
      assert File.read!(dest) == "source\n"
      refute File.exists?(source)
    end
  end

  test "a rename to the same path still succeeds", ctx do
    source = Path.join(ctx.root, "a/src.c")
    uri = Text.path_to_uri(source)

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [%{"kind" => "rename", "oldUri" => uri, "newUri" => uri}]
      })

    opts = [filesystem_checkpoints: false]
    assert {:ok, _} = WorkspaceEdit.apply(ops, ctx.root, opts, nil, %{tool: "lsp"})
    assert File.read!(source) == "source\n"
  end

  # Applies `changes` with a tap that swaps `inner` for a symlink to
  # `outside` just before the first `{op, path}` file-server request.
  defp race(ctx, {op, path}, changes) do
    {:ok, ops} = WorkspaceEdit.plan(%{"documentChanges" => changes})
    test = self()
    before = tree(ctx.outside)

    hook = fn request ->
      if {elem(request, 0), FileServerTap.path(request)} == {op, path} and
           Process.get(:swapped) != true do
        Process.put(:swapped, true)
        FileServerTap.swap_for_symlink(ctx.inner, ctx.outside)
        send(test, :swapped)
      end
    end

    result =
      FileServerTap.with_tap(hook, fn ->
        WorkspaceEdit.apply(ops, ctx.root, [filesystem_checkpoints: false], nil, %{tool: "lsp"})
      end)

    {result, before}
  end

  defp assert_refused(ctx, {result, before}) do
    assert_received :swapped
    assert tree(ctx.outside) == before
    assert {:error, message} = result
    assert message =~ "symlink"
  end

  defp tree(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Map.new(fn path ->
      {Path.relative_to(path, dir), if(File.dir?(path), do: :dir, else: File.read!(path))}
    end)
  end
end
