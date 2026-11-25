defmodule LemonSkills.ContextTest do
  use ExUnit.Case, async: false

  alias LemonSkills.Context

  setup do
    root =
      Path.join(System.tmp_dir!(), "lemon-context-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "docs/nested"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "the context service ships in lemon_skills, not the published lemon_core package" do
    assert Application.get_application(Context) == :lemon_skills
    assert Application.get_application(Context.Document) == :lemon_skills
    assert Application.get_application(Context.URLFetcher) == :lemon_skills

    {:ok, core_modules} = :application.get_key(:lemon_core, :modules)

    refute Enum.any?(
             core_modules,
             &String.starts_with?(Atom.to_string(&1), "Elixir.LemonCore.Context")
           )
  end

  test "preview and resolve share exact budgets while preview omits content", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "token=secret-value\nvisible")

    assert {:ok, preview} = Context.preview("@file:note.txt", root: root, max_output_bytes: 500)
    assert {:ok, resolved} = Context.resolve("@file:note.txt", root: root, max_output_bytes: 500)

    assert preview.summary == resolved.summary
    assert preview.selected_text == nil
    refute Map.has_key?(hd(preview.sources), :content)
    refute resolved.selected_text =~ "secret-value"
    assert resolved.summary.redaction_count == 1
    assert resolved.redacted
  end

  test "rejects traversal and every symlink component", %{root: root} do
    outside =
      Path.join(
        System.tmp_dir!(),
        "lemon-context-outside-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(outside, "outside")
    File.ln_s!(outside, Path.join(root, "linked.txt"))
    on_exit(fn -> File.rm(outside) end)

    assert {:ok, traversal} = Context.resolve("@file:../outside.txt", root: root)
    assert [%{reason: "path_traversal"}] = traversal.omissions

    assert {:ok, symlink} = Context.resolve("@file:linked.txt", root: root)
    assert [%{reason: "symlink"}] = symlink.omissions
  end

  test "rejects a symlink supplied as the root itself", %{root: root} do
    symlink_root = root <> "-link"
    File.ln_s!(root, symlink_root)
    on_exit(fn -> File.rm(symlink_root) end)

    assert {:error, :symlink_root} = Context.resolve("@file:note.txt", root: symlink_root)
  end

  test "folder walks are deterministic, depth bounded, and omit symlinks", %{root: root} do
    File.write!(Path.join(root, "docs/a.txt"), "A")
    File.write!(Path.join(root, "docs/nested/b.txt"), "B")
    File.ln_s!(Path.join(root, "docs/a.txt"), Path.join(root, "docs/link.txt"))

    assert {:ok, result} = Context.resolve("@folder:docs", root: root, max_depth: 1)
    assert result.selected_text =~ "docs/a.txt"
    assert result.selected_text =~ "docs/nested/b.txt"
    assert Enum.any?(result.omissions, &(&1.reason == "symlink"))
  end

  test "resolves git diff without a shell, textconv or fsmonitor", %{root: root} do
    System.cmd("git", ["init", "-q", root])
    File.write!(Path.join(root, "tracked.txt"), "one\n")
    System.cmd("git", ["-C", root, "add", "tracked.txt"])

    System.cmd("git", [
      "-C",
      root,
      "-c",
      "user.name=Lemon",
      "-c",
      "user.email=lemon@example.test",
      "commit",
      "-qm",
      "base"
    ])

    marker = Path.join(root, "program-ran")
    textconv = git_config_program!(root, "textconv", marker, ~s(cat "$1"))
    fsmonitor = git_config_program!(root, "fsmonitor", marker, "exit 1")
    {_, 0} = System.cmd("git", ["-C", root, "config", "diff.evil.textconv", textconv])
    {_, 0} = System.cmd("git", ["-C", root, "config", "core.fsmonitor", fsmonitor])
    File.write!(Path.join(root, ".git/info/attributes"), "* diff=evil\n")
    File.write!(Path.join(root, "tracked.txt"), "two\n")

    assert {:ok, result} = Context.resolve("@git-diff", root: root)
    assert result.selected_text =~ "+two"
    refute File.exists?(marker), "@git-diff ran a program named by repository config"

    assert {:ok, rejected} = Context.resolve("@git-diff:--output=/tmp/owned", root: root)
    assert [%{reason: "invalid_git_ref"}] = rejected.omissions
  end

  test "URL and session references reuse extract/redaction contracts", %{root: root} do
    send_fun = fn _request ->
      {:ok,
       %{status: 200, headers: [{"content-type", "text/plain"}], body: "password=hunter2\nremote"}}
    end

    session_export = fn "agent:test:main", [format: :markdown] ->
      {:ok, %{content: "api_key=abc123\nsession", bytes: 24, run_count: 1, omitted_run_count: 0}}
    end

    assert {:ok, result} =
             Context.resolve(["@url:https://example.test/doc", "@session:agent:test:main"],
               root: root,
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               send_fun: send_fun,
               session_export_fun: session_export
             )

    refute result.selected_text =~ "hunter2"
    refute result.selected_text =~ "abc123"

    assert Enum.any?(
             result.sources,
             &(&1.type == "session" and String.starts_with?(&1.label, "session:"))
           )

    refute inspect(result) =~ "agent:test:main"
  end

  test "global output and operation time are hard bounded", %{root: root} do
    File.write!(Path.join(root, "big.txt"), String.duplicate("x", 1_000))
    assert {:ok, result} = Context.resolve("@file:big.txt", root: root, max_output_bytes: 100)
    assert result.summary.selected_bytes == 100
    assert Enum.any?(result.omissions, &(&1.reason == "output_budget"))

    assert {:error, :timeout} =
             Context.resolve("@url:https://example.test/slow",
               root: root,
               timeout_ms: 10,
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               # Never answers; Context must cut it off at timeout_ms
               send_fun: fn _request -> Process.sleep(:infinity) end
             )
  end

  defp git_config_program!(root, name, marker, command) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{command}\n")
    File.chmod!(path, 0o755)
    path
  end
end
