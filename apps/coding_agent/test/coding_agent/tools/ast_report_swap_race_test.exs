defmodule CodingAgent.Tools.AstReportSwapRaceTest do
  @moduledoc """
  Deterministic check-then-use races against `ast_grep` replace and
  `report_issue`.

  `FileServerTap` swaps a checked entry for a symlink to a location outside
  the trusted root right after the last path-based validation, the way a
  concurrent local writer could. The tools' file I/O must then stay below the
  root (descriptor-bound) and refuse, leaving the outside untouched.
  """

  use ExUnit.Case, async: false

  alias CodingAgent.MutationLock
  alias CodingAgent.Tools.{AstGrep, ReportIssue}
  alias LemonCore.Testing.FileServerTap

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    if Process.whereis(MutationLock) == nil, do: start_supervised!(MutationLock)
    root = Path.join(tmp, "root")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "sentinel.txt"), "sentinel\n")
    %{tmp: tmp, root: root, outside: outside}
  end

  test "ast_grep replace never writes through an ancestor swapped after the recheck", ctx do
    sub = Path.join(ctx.root, "sub")
    inner = Path.join(sub, "inner")
    target = Path.join(inner, "target.ts")
    File.mkdir_p!(inner)
    File.write!(target, "oldApi(1)")
    File.write!(Path.join(ctx.outside, "target.ts"), "oldApi(1)")
    backend = fake_backend(ctx.tmp)
    before = tree(ctx.outside)
    test = self()

    # Scope expansion stats the target once; planning, the content recheck and
    # the commit then each validate it (lstat target and parents, then stat it
    # for write access). The swap happens at the commit validation's last check,
    # its stat (the fourth), after the content recheck.
    hook = fn request ->
      if {elem(request, 0), FileServerTap.path(request)} == {:read_file_info, target} do
        count = (Process.get(:stats) || 0) + 1
        Process.put(:stats, count)

        if count == 4 do
          FileServerTap.swap_for_symlink(inner, ctx.outside)
          send(test, :swapped)
        end
      end
    end

    result =
      FileServerTap.with_tap(hook, fn ->
        AstGrep.execute(
          "race",
          %{
            "action" => "replace",
            "pattern" => "oldApi(1)",
            "rewrite" => "newApi(1)",
            "paths" => ["sub/inner/target.ts"],
            "dry_run" => false,
            "expected_matches" => 1
          },
          nil,
          nil,
          ctx.root,
          ast_grep_executable: backend,
          filesystem_checkpoints: false,
          spill_dir: ctx.tmp
        )
      end)

    assert_received :swapped
    assert tree(ctx.outside) == before
    assert %{is_error: true, details: %{applied: false}} = result
    assert File.read!(Path.join(inner <> ".moved", "target.ts")) == "oldApi(1)"
  end

  test "report_issue never appends to or chmods a log entry swapped after validation", ctx do
    directory = Path.join(ctx.root, "spill")
    log = Path.join(directory, "tool-issues.jsonl")
    victim = Path.join(ctx.outside, "victim.txt")
    File.mkdir_p!(directory)
    File.write!(log, "")
    File.chmod!(log, 0o600)
    File.write!(victim, "victim\n")
    File.chmod!(victim, 0o644)
    before = tree(ctx.outside)
    test = self()

    # Validation lstats the log, then stats it for write access; the swap
    # happens at that last check, so the check itself follows the new symlink.
    hook = fn request ->
      if {elem(request, 0), FileServerTap.path(request)} == {:read_file_info, log} and
           not Process.get(:swapped, false) do
        FileServerTap.swap_for_symlink(log, victim)
        Process.put(:swapped, true)
        send(test, :swapped)
      end
    end

    opts = [session_id: "race", context_guardrails: [spill_dir: directory]]

    result =
      FileServerTap.with_tap(hook, fn ->
        ReportIssue.execute("race", %{"note" => "planted"}, nil, nil, ctx.root, opts)
      end)

    assert_received :swapped
    assert tree(ctx.outside) == before
    assert Bitwise.band(File.stat!(victim).mode, 0o777) == 0o644
    assert {:error, message} = result
    assert message =~ "symlink"
  end

  defp fake_backend(dir) do
    path = Path.join(dir, "fake-ast-grep")

    File.write!(path, """
    #!/bin/sh
    if [ "$1" = "--version" ]; then printf 'ast-grep 0.1.0\\n'; exit 0; fi
    for file; do :; done
    printf '{"file":"%s","text":"oldApi(1)","replacement":"newApi(1)","replacementOffsets":{"start":0,"end":9},"language":"TypeScript","range":{"byteOffset":{"start":0,"end":9},"start":{"line":0,"column":0},"end":{"line":0,"column":9}}}\\n' "$file"
    """)

    File.chmod!(path, 0o700)
    path
  end

  defp tree(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn name ->
      path = Path.join(dir, name)
      stat = File.lstat!(path)
      {name, stat.type, Bitwise.band(stat.mode, 0o777), File.read!(path)}
    end)
  end
end
