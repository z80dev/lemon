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

  test "full read permits every original line in one batch", ctx do
    tag = read(ctx).details.snapshot

    assert %AgentToolResult{} =
             edit(ctx, tag, [
               %{"start_line" => 1, "new_text" => "first"},
               %{"start_line" => 10, "end_line" => 11, "operation" => "delete"},
               %{"start_line" => 20, "operation" => "insert_after", "new_text" => "last"}
             ])

    assert File.read!(ctx.path) =~ "first\nline 2"
    refute File.read!(ctx.path) =~ "line 10\n"
    assert String.ends_with?(File.read!(ctx.path), "line 20\nlast\n")
  end

  test "window refusal is atomic and another read fills the gap", ctx do
    tag = read(ctx, %{"offset" => 1, "limit" => 2}).details.snapshot

    edits = [
      %{"start_line" => 1, "new_text" => "first"},
      %{"start_line" => 8, "end_line" => 10, "operation" => "delete"}
    ]

    assert {:error, message} = edit(ctx, tag, edits)
    assert message =~ "Unseen lines 8-10"
    assert message =~ "read #{ctx.path}:8-10"
    assert File.read!(ctx.path) == ctx.content
    assert read(ctx, %{"offset" => 8, "limit" => 3}).details.snapshot == tag
    assert %AgentToolResult{} = edit(ctx, tag, edits)
  end

  test "both insertion operations require their anchor to be seen", ctx do
    tag = read(ctx, %{"offset" => 1, "limit" => 1}).details.snapshot

    for operation <- ["insert_before", "insert_after"] do
      assert {:error, message} =
               edit(ctx, tag, [
                 %{"start_line" => 7, "operation" => operation, "new_text" => "inserted"}
               ])

      assert message =~ "Unseen lines 7"
      assert File.read!(ctx.path) == ctx.content
    end
  end

  test "single range context counts but comma window gaps do not", ctx do
    tag = read(ctx, %{"path" => ctx.path <> ":5-6"}).details.snapshot
    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) == MapSet.new(4..9)
    read(ctx, %{"path" => ctx.path <> ":12,16-17"})

    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) ==
             MapSet.new(Enum.to_list(4..9) ++ [12, 16, 17])

    assert {:error, message} =
             edit(ctx, tag, [%{"start_line" => 10, "end_line" => 17, "operation" => "delete"}])

    assert message =~ "Unseen lines 10-11,13-15"
    assert File.read!(ctx.path) == ctx.content
  end

  test "tail probe and budget-elided windows grant no hidden lines", ctx do
    tag = read(ctx, %{"path" => ctx.path <> ":-2"}).details.snapshot
    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) == MapSet.new([19, 20])
    limited = %{ctx | opts: Keyword.put(ctx.opts, :max_lines, 1)}
    read(limited, %{"path" => ctx.path <> ":5,10"})
    assert FileReadTracker.seen_lines(ctx.opts, ctx.path, tag) == MapSet.new([5, 19, 20])
  end

  test "partial long-line previews do not grant visibility", ctx do
    File.write!(ctx.path, String.duplicate("x", 500) <> "\nsecond\n")
    limited = %{ctx | opts: Keyword.put(ctx.opts, :max_bytes, 100)}
    result = read(limited)
    assert result.details.truncation.reason == "long_line"

    assert {:error, message} =
             edit(ctx, result.details.snapshot, [%{"start_line" => 1, "new_text" => "changed"}])

    assert message =~ "Unseen lines 1"
    assert File.read!(ctx.path) == String.duplicate("x", 500) <> "\nsecond\n"
  end

  test "structural summary records declarations but not omitted bodies", ctx do
    path = Path.join(ctx.cwd, "large.py")
    content = "def example():\n" <> Enum.map_join(2..320, "", &"    value_#{&1} = #{&1}\n")
    File.write!(path, content)
    ctx = %{ctx | path: path}
    summary = read(ctx)
    assert summary.details.summary
    assert summary.details.snapshot == nil
    tag = AnchoredEdit.snapshot(content)
    assert FileReadTracker.seen_lines(ctx.opts, path, tag) == MapSet.new([1])

    assert {:error, message} =
             edit(ctx, tag, [%{"start_line" => 120, "end_line" => 140, "operation" => "delete"}])

    assert message =~ "read #{path}:120-140"
    assert File.read!(path) == content
    assert read(ctx, %{"path" => path <> ":120-140"}).details.snapshot == tag

    assert %AgentToolResult{} =
             edit(ctx, tag, [%{"start_line" => 120, "end_line" => 140, "operation" => "delete"}])
  end

  test "setting off preserves edits outside a read window; default refuses them", ctx do
    tag = read(ctx, %{"limit" => 1}).details.snapshot
    disabled = %{ctx | opts: Keyword.put(ctx.opts, :enforce_seen_lines, false)}

    assert %AgentToolResult{} =
             edit(disabled, tag, [%{"start_line" => 12, "new_text" => "disabled"}])

    tag = AnchoredEdit.snapshot(File.read!(ctx.path))
    default = %{ctx | opts: Keyword.delete(ctx.opts, :enforce_seen_lines)}

    assert {:error, message} =
             edit(default, tag, [%{"start_line" => 13, "new_text" => "default"}])

    assert message =~ "Unseen lines"
  end

  test "plain text replacements are unaffected", ctx do
    read(ctx, %{"limit" => 1})

    assert %AgentToolResult{} =
             Edit.execute(
               "edit",
               %{"path" => ctx.path, "old_text" => "line 12", "new_text" => "text mode"},
               nil,
               nil,
               ctx.cwd,
               ctx.opts
             )
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

  test "recovery cannot use unseen original lines or visibility of another tag", ctx do
    tag = read(ctx, %{"offset" => 8, "limit" => 1}).details.snapshot
    current = "header\n" <> ctx.content
    File.write!(ctx.path, current)
    read(ctx)

    assert {:error, message} =
             edit(ctx, tag, [%{"start_line" => 7, "new_text" => "must not write"}])

    assert message =~ "Unseen lines 7"
    assert File.read!(ctx.path) == current
  end

  test "visibility is scoped by session and path and raw reads grant nothing", ctx do
    tag = read(ctx).details.snapshot
    other = %{ctx | opts: Keyword.put(ctx.opts, :session_id, ctx.cwd <> "-other")}
    on_exit(fn -> FileReadTracker.forget_session(ctx.cwd <> "-other") end)
    read(other, %{"path" => ctx.path <> ":raw"})
    assert {:error, _} = edit(other, tag, [%{"start_line" => 1, "new_text" => "hidden"}])
    path = Path.join(ctx.cwd, "other.txt")
    File.write!(path, ctx.content)

    assert {:error, _} =
             edit(%{ctx | path: path}, tag, [%{"start_line" => 1, "new_text" => "hidden"}])

    FileReadTracker.forget_session(ctx.cwd)
    assert {:error, _} = edit(ctx, tag, [%{"start_line" => 1, "new_text" => "hidden"}])
  end

  test "tool definition threads enforcement options into execution", ctx do
    tool = Edit.tool(ctx.cwd, ctx.opts)

    params = %{
      "path" => ctx.path,
      "snapshot" => AnchoredEdit.snapshot(ctx.content),
      "edits" => [%{"start_line" => 1, "new_text" => "hidden"}]
    }

    assert {:error, message} = tool.execute.("edit", params, nil, nil)
    assert message =~ "Unseen lines 1"
    assert File.read!(ctx.path) == ctx.content
  end

  defp read(ctx, params \\ %{}) do
    Read.execute("read", Map.merge(%{"path" => ctx.path}, params), nil, nil, ctx.cwd, ctx.opts)
  end

  defp edit(ctx, tag, edits) do
    Edit.execute(
      "edit",
      %{"path" => ctx.path, "snapshot" => tag, "edits" => edits},
      nil,
      nil,
      ctx.cwd,
      ctx.opts
    )
  end
end
