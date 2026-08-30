defmodule LemonCore.ContextTest do
  use ExUnit.Case, async: false

  alias LemonCore.Context
  alias LemonCore.{RunStore, SessionLifecycle}

  setup do
    root =
      Path.join(System.tmp_dir!(), "lemon-context-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "docs/nested"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "preview and resolve share exact budgets while preview omits content", %{root: root} do
    File.write!(Path.join(root, "note.txt"), "token=secret-value\nvisible")

    assert {:ok, preview} = Context.preview("@file:note.txt", root: root, max_output_bytes: 500)
    assert {:ok, resolved} = Context.resolve("@file:note.txt", root: root, max_output_bytes: 500)

    assert preview.summary == resolved.summary
    assert preview.selected_text == nil
    refute Map.has_key?(hd(preview.sources), :content)
    assert resolved.selected_text =~ "token=[REDACTED]"
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

  test "resolves git diff without a shell", %{root: root} do
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

    File.write!(Path.join(root, "tracked.txt"), "two\n")

    assert {:ok, result} = Context.resolve("@git-diff", root: root)
    assert result.selected_text =~ "+two"

    assert {:ok, rejected} = Context.resolve("@git-diff:--output=/tmp/owned", root: root)
    assert [%{reason: "invalid_git_ref"}] = rejected.omissions
  end

  test "URL and session references reuse extract/redaction contracts", %{root: root} do
    request = fn _url, _headers, _http, _max ->
      {:ok,
       {{~c"HTTP/1.1", 200, ~c"OK"}, [{~c"content-type", ~c"text/plain"}],
        "password=hunter2\nremote"}}
    end

    session_export = fn "agent:test:main", [format: :markdown] ->
      {:ok, %{content: "api_key=abc123\nsession", bytes: 24, run_count: 1, omitted_run_count: 0}}
    end

    assert {:ok, result} =
             Context.resolve(["@url:https://example.test/doc", "@session:agent:test:main"],
               root: root,
               resolve_fun: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
               request_fun: request,
               session_export_fun: session_export
             )

    assert result.selected_text =~ "password=[REDACTED]"
    assert result.selected_text =~ "api_key=[REDACTED]"

    assert Enum.any?(
             result.sources,
             &(&1.type == "session" and String.starts_with?(&1.label, "session:"))
           )

    refute inspect(result) =~ "agent:test:main"
  end

  test "session references use the canonical redacted lifecycle export", %{root: root} do
    suffix = System.unique_integer([:positive])
    session_key = "agent:context_session_#{suffix}:main"
    run_id = "context-session-run-#{suffix}"
    secret = "context-session-secret-#{suffix}"
    on_exit(fn -> SessionLifecycle.delete(session_key) end)

    :ok =
      RunStore.finalize(run_id, %{
        session_key: session_key,
        agent_id: "context_session_#{suffix}",
        origin: :cli,
        prompt: "api_key=#{secret}",
        completed: %{ok: true, answer: "Bearer #{secret}"}
      })

    assert eventually(fn -> SessionLifecycle.get(session_key) != nil end)

    assert {:ok, result} = Context.resolve("@session:#{session_key}", root: root)
    assert result.selected_text =~ "Redacted export: yes"
    refute result.selected_text =~ secret
    refute inspect(result) =~ session_key
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
               request_fun: fn _, _, _, _ ->
                 Process.sleep(100)
                 {:error, :late}
               end
             )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
