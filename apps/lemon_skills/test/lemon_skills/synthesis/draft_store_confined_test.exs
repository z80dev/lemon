defmodule LemonSkills.Synthesis.DraftStoreConfinedTest do
  @moduledoc """
  A concurrent local writer swaps the drafts root for a symlink to an outside
  directory after the path checks and before removal (shared finding NEW-6).
  Removal is descriptor-bound, so the outside tree survives.
  """
  use ExUnit.Case, async: false

  alias LemonCore.Testing.FileServerTap
  alias LemonSkills.Synthesis.DraftStore

  @moduletag :tmp_dir

  @key "synth-victim"

  setup %{tmp_dir: tmp} do
    cwd = Path.join(tmp, "project")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(cwd)
    File.mkdir_p!(Path.join(outside, @key))
    File.write!(Path.join([outside, @key, "precious.txt"]), "PRECIOUS")
    File.write!(Path.join(outside, ".#{@key}.draft_meta.json"), "{}")

    opts = [global: false, cwd: cwd]
    assert :ok = DraftStore.put(%{key: @key, content: "# draft"}, opts)
    {:ok, dir} = DraftStore.draft_dir(@key, opts)

    {:ok, opts: opts, outside: outside, root: Path.dirname(dir), dir: dir}
  end

  test "delete does not follow a drafts root swapped after the checks", ctx do
    # Swap at the draft directory's first lstat: every later path check (and,
    # pre-fix, `rm_rf`) then walks through the symlink to the outside tree.
    hook = fn request ->
      with {:read_link_info, _, _} <- request,
           path when path == ctx.dir <- FileServerTap.path(request),
           nil <- Process.get(:swapped) do
        Process.put(:swapped, true)
        FileServerTap.swap_for_symlink(ctx.root, ctx.outside)
      end
    end

    result = FileServerTap.with_tap(hook, fn -> DraftStore.delete(@key, ctx.opts) end)

    assert File.read!(Path.join([ctx.outside, @key, "precious.txt"])) == "PRECIOUS"
    assert File.read!(Path.join(ctx.outside, ".#{@key}.draft_meta.json")) == "{}"
    assert {:error, _} = result

    FileServerTap.restore(ctx.root)
    assert File.regular?(Path.join(ctx.dir, "SKILL.md"))
  end

  test "an unswapped draft is removed with its metadata", ctx do
    assert :ok = DraftStore.delete(@key, ctx.opts)
    refute File.exists?(ctx.dir)
    refute File.exists?(DraftStore.meta_path(ctx.dir))
    assert :ok = DraftStore.delete(@key, ctx.opts)
  end
end
