defmodule CodingAgent.Tools.AnchoredEditSeenLinesTest do
  use ExUnit.Case, async: true

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.{AnchoredEdit, Edit, Read}
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    path = Path.join(cwd, "lines.txt")
    content = Enum.map_join(1..20, "", &"line #{&1}\n")
    File.write!(path, content)
    opts = [session_id: cwd, enforce_seen_lines: true]
    on_exit(fn -> FileReadTracker.forget_session(cwd) end)
    %{cwd: cwd, path: path, content: content, opts: opts}
  end

  test "current ranged snapshots permit omitted lines atomically", ctx do
    tag = read(ctx, %{"limit" => 2}).details.snapshot
    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) == MapSet.new([1, 2])

    assert %AgentToolResult{} =
             edit(ctx, tag, [
               %{"start_line" => 1, "new_text" => "first"},
               %{"start_line" => 8, "end_line" => 10, "operation" => "delete"}
             ])

    assert File.read!(ctx.path) ==
             "first\n" <>
               Enum.map_join(Enum.to_list(2..7) ++ Enum.to_list(11..20), "", &"line #{&1}\n")
  end

  test "current snapshots allow both insertion operations outside the read window", ctx do
    for operation <- ["insert_before", "insert_after"] do
      File.write!(ctx.path, ctx.content)
      tag = read(ctx, %{"limit" => 1}).details.snapshot

      assert %AgentToolResult{} =
               edit(ctx, tag, [
                 %{"start_line" => 7, "operation" => operation, "new_text" => "inserted"}
               ])

      expected = if operation == "insert_before", do: "inserted\nline 7", else: "line 7\ninserted"
      assert File.read!(ctx.path) =~ expected
    end
  end

  test "selector gaps and elided long-line previews do not invalidate current tags", ctx do
    tag = read(ctx, %{"path" => ctx.path <> ":5,10"}).details.snapshot
    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) == MapSet.new([5, 10])
    assert %AgentToolResult{} = edit(ctx, tag, [%{"start_line" => 7, "new_text" => "gap"}])

    File.write!(ctx.path, String.duplicate("x", 500) <> "\nsecond\n")
    limited = %{ctx | opts: Keyword.put(ctx.opts, :max_bytes, 100)}
    result = read(limited)
    assert result.details.truncation.reason == "long_line"

    assert %AgentToolResult{} =
             edit(ctx, result.details.snapshot, [%{"start_line" => 1, "new_text" => "changed"}])

    assert File.read!(ctx.path) == "changed\nsecond\n"
  end

  test "structural summaries stay untagged; an explicit ranged tag permits omitted bodies", ctx do
    path = Path.join(ctx.cwd, "large.py")
    content = "def example():\n" <> Enum.map_join(2..320, "", &"    value_#{&1} = #{&1}\n")
    File.write!(path, content)
    ctx = %{ctx | path: path}
    summary = read(ctx)
    assert summary.details.summary
    assert summary.details.snapshot == nil
    tag = read(ctx, %{"path" => path <> ":1-2"}).details.snapshot
    assert tag == AnchoredEdit.snapshot(content)

    assert %AgentToolResult{} =
             edit(ctx, tag, [%{"start_line" => 120, "end_line" => 140, "operation" => "delete"}])

    refute File.read!(path) =~ "value_120 ="
    assert File.read!(path) =~ "value_141 ="
  end

  test "recovery follows seen original ranges to shifted byte-identical anchors", ctx do
    tag = read(ctx, %{"offset" => 8, "limit" => 2}).details.snapshot
    File.write!(ctx.path, "header\n" <> ctx.content)

    assert %AgentToolResult{} =
             edit(ctx, String.downcase(tag), [
               %{"start_line" => 8, "end_line" => 9, "new_text" => "recovered"}
             ])

    assert File.read!(ctx.path) ==
             "header\n" <> String.replace(ctx.content, "line 8\nline 9\n", "recovered\n")
  end

  test "stale unseen anchors refuse with fresh context that supports retry without read", ctx do
    tag = read(ctx, %{"limit" => 1}).details.snapshot
    current = String.replace(ctx.content, "line 8\n", "user changed eight\n")
    File.write!(ctx.path, current)
    assert {:error, message} = edit(ctx, tag, [%{"start_line" => 8, "new_text" => "retry"}])
    fresh = AnchoredEdit.snapshot(current)
    assert message =~ "Unseen lines 8"
    assert message =~ "[#{ctx.path}##{fresh}]"
    assert message =~ "8: user changed eight"
    assert File.read!(ctx.path) == current
    assert %AgentToolResult{} = edit(ctx, fresh, [%{"start_line" => 8, "new_text" => "retry"}])
    assert File.read!(ctx.path) =~ "retry\n"
  end

  test "fresh tags work without visibility records but unknown stale tags never do", ctx do
    tag = AnchoredEdit.snapshot(ctx.content)

    assert %AgentToolResult{} =
             edit(%{ctx | opts: []}, tag, [%{"start_line" => 1, "new_text" => "first"}])

    current = File.read!(ctx.path)

    assert {:error, message} =
             edit(%{ctx | opts: []}, tag, [%{"start_line" => 2, "new_text" => "unsafe"}])

    assert message =~ "Current snapshot"
    assert File.read!(ctx.path) == current
  end

  test "configured tool constructors permit current snapshots even with enforcement", ctx do
    tool = Edit.tool(ctx.cwd, ctx.opts)

    assert %AgentToolResult{} =
             tool.execute.(
               "edit",
               %{
                 "path" => ctx.path,
                 "snapshot" => AnchoredEdit.snapshot(ctx.content),
                 "edits" => [%{"start_line" => 12, "new_text" => "changed"}]
               },
               nil,
               nil
             )

    assert File.read!(ctx.path) =~ "changed\n"
  end

  defp read(ctx, params \\ %{}),
    do:
      Read.execute("read", Map.merge(%{"path" => ctx.path}, params), nil, nil, ctx.cwd, ctx.opts)

  defp edit(ctx, tag, edits),
    do:
      Edit.execute(
        "edit",
        %{"path" => ctx.path, "snapshot" => tag, "edits" => edits},
        nil,
        nil,
        ctx.cwd,
        ctx.opts
      )
end
