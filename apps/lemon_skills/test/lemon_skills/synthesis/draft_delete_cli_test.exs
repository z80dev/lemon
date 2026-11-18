defmodule LemonSkills.Synthesis.DraftDeleteCLITest do
  @moduledoc """
  `lemon skill draft delete` through the real CLI entry point against real
  project draft directories.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias LemonCore.CLI.Error
  alias LemonSkills.CLI
  alias LemonSkills.Synthesis.DraftStore

  setup do
    tmp = Path.join(System.tmp_dir!(), "draft_delete_cli_#{System.unique_integer([:positive])}")
    project = Path.join(tmp, "project")
    drafts = Path.join([project, ".lemon", "skill_drafts"])
    File.mkdir_p!(drafts)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp, project: project, drafts: drafts}
  end

  test "declining or EOF at the prompt keeps the draft and exits normally", ctx do
    put_draft!(ctx, "keep-me")

    for answer <- ["n\n", "\n", "", "no\n"] do
      output = capture_io(answer, fn -> assert :ok == delete(ctx, "keep-me") end)

      assert output =~ "Cancelled."
      refute output =~ "Deleted draft"
      assert File.regular?(Path.join([ctx.drafts, "keep-me", "SKILL.md"])), inspect(answer)
    end
  end

  test "confirming deletes exactly that draft directory", ctx do
    put_draft!(ctx, "doomed")
    put_draft!(ctx, "sibling")

    capture_io("y\n", fn -> delete(ctx, "doomed") end)

    refute File.exists?(Path.join(ctx.drafts, "doomed"))
    assert File.regular?(Path.join([ctx.drafts, "sibling", "SKILL.md"]))
    assert File.dir?(ctx.drafts)
  end

  test "traversal and absolute keys are rejected and remove nothing", ctx do
    sentinel = Path.join([ctx.project, ".lemon", "keep.txt"])
    File.write!(sentinel, "keep")
    outside = Path.join(ctx.tmp, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.txt"), "keep")
    put_draft!(ctx, "sibling")

    for key <- ["..", "a/../..", "../../outside", outside, ".", "", "UPPER", "-lead"] do
      assert_raise Error, fn ->
        capture_io(:stderr, fn -> capture_io("y\n", fn -> delete(ctx, key, ["--force"]) end) end)
      end

      assert File.read!(sentinel) == "keep", "key #{inspect(key)} removed the agent dir"
      assert File.read!(Path.join(outside, "keep.txt")) == "keep"
      assert File.regular?(Path.join([ctx.drafts, "sibling", "SKILL.md"]))
    end
  end

  test "a symlinked draft directory is rejected and nothing is removed", ctx do
    target = Path.join(ctx.tmp, "victim")
    File.mkdir_p!(target)
    File.write!(Path.join(target, "SKILL.md"), "victim")
    link = Path.join(ctx.drafts, "linked")
    File.ln_s!(target, link)

    assert_raise Error, fn ->
      capture_io(:stderr, fn -> capture_io(fn -> delete(ctx, "linked", ["--force"]) end) end)
    end

    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    assert File.read!(Path.join(target, "SKILL.md")) == "victim"
    assert {:error, _} = DraftStore.get("linked", global: false, cwd: ctx.project)
  end

  test "a symlinked drafts root is rejected and nothing is removed", ctx do
    outside = Path.join(ctx.tmp, "elsewhere")
    File.mkdir_p!(Path.join(outside, "victim"))
    File.write!(Path.join([outside, "victim", "data"]), "victim")
    File.rm_rf!(ctx.drafts)
    File.ln_s!(outside, ctx.drafts)

    assert_raise Error, fn ->
      capture_io(:stderr, fn -> capture_io(fn -> delete(ctx, "victim", ["--force"]) end) end)
    end

    assert File.read!(Path.join([outside, "victim", "data"])) == "victim"
  end

  test "every DraftStore entry point rejects keys outside the drafts root", ctx do
    opts = [global: false, cwd: ctx.project]
    sentinel = Path.join([ctx.project, ".lemon", "keep.txt"])
    File.write!(sentinel, "keep")

    for key <- ["..", "a/../..", "/etc", "../x", nil] do
      assert {:error, :invalid_draft_key} = DraftStore.draft_dir(key, opts)
      assert {:error, :invalid_draft_key} = DraftStore.delete(key, opts)
      assert {:error, :invalid_draft_key} = DraftStore.get(key, opts)
      assert {:error, :invalid_draft_key} = DraftStore.promote(key, opts)

      assert {:error, :invalid_draft_key} =
               DraftStore.put(%{key: key || "", content: "x"}, opts)

      assert {:error, :invalid_draft_key} =
               DraftStore.put_new(%{key: key || "", content: "x"}, opts)

      if is_binary(key),
        do: assert({:error, :invalid_draft_key} = DraftStore.record_audit(key, %{}, opts))
    end

    assert File.read!(sentinel) == "keep"
    refute File.exists?(Path.join([ctx.project, ".lemon", "SKILL.md"]))
  end

  defp delete(ctx, key, extra \\ []) do
    CLI.run(["draft", "delete", key, "--local", "--cwd=#{ctx.project}" | extra])
  end

  defp put_draft!(ctx, key) do
    dir = Path.join(ctx.drafts, key)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{key}\n---\n")
  end
end
