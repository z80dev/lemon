defmodule CodingAgent.Tools.AnchoredEditTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.{AnchoredEdit, Edit, Read}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "ranged reads tag the complete snapshot and edits use original coordinates", %{
    tmp_dir: cwd
  } do
    path = Path.join(cwd, "repeated.txt")
    original = "alpha\nrepeat\nmiddle\nrepeat\nomega\n"
    File.write!(path, original)

    result =
      Read.execute("read", %{"path" => path, "offset" => 4, "limit" => 2}, nil, nil, cwd, [])

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
    assert details.total_lines == 5
    assert details.snapshot == AnchoredEdit.snapshot(original)
    assert text =~ "[#{path}##{details.snapshot}]"
    assert text =~ "4: repeat\n5: omega"
    refute text =~ "6: "

    result =
      Edit.execute(
        "edit",
        %{
          "path" => path,
          "snapshot" => details.snapshot,
          "edits" => [
            %{"start_line" => 4, "new_text" => "chosen\n"},
            %{"operation" => "insert_before", "start_line" => 1, "new_text" => "start"},
            %{"operation" => "delete", "start_line" => 3}
          ]
        },
        nil,
        nil,
        cwd,
        []
      )

    assert %AgentToolResult{trust: :untrusted, details: edited} = result
    assert File.read!(path) == "start\nalpha\nrepeat\nchosen\nomega\n"
    assert edited.snapshot == AnchoredEdit.snapshot(File.read!(path))
  end

  test "an unseen-line change invalidates a ranged snapshot without session tracking", %{
    tmp_dir: cwd
  } do
    path = Path.join(cwd, "stale.txt")
    File.write!(path, "outside\nselected\n")

    result =
      Read.execute("read", %{"path" => path, "offset" => 2, "limit" => 1}, nil, nil, cwd, [])

    File.write!(path, "user change\nselected\n")

    assert {:error, message} =
             Edit.execute(
               "edit",
               %{
                 "path" => path,
                 "snapshot" => result.details.snapshot,
                 "edits" => [%{"start_line" => 2, "new_text" => "replacement"}]
               },
               nil,
               nil,
               cwd,
               []
             )

    assert message =~ "Snapshot mismatch"
    assert File.read!(path) == "user change\nselected\n"
  end

  test "all overlaps and out-of-range edits are preflighted before writing", %{tmp_dir: cwd} do
    path = Path.join(cwd, "preflight.txt")
    content = "one\ntwo\nthree\n"
    File.write!(path, content)
    snapshot = AnchoredEdit.snapshot(content)

    for edits <- [
          [
            %{"start_line" => 1, "new_text" => "first"},
            %{"start_line" => 4, "new_text" => "bad"}
          ],
          [
            %{"start_line" => 1, "end_line" => 2, "new_text" => "span"},
            %{"start_line" => 2, "new_text" => "overlap"}
          ],
          [
            %{"operation" => "insert_after", "start_line" => 1, "new_text" => "a"},
            %{"operation" => "insert_before", "start_line" => 2, "new_text" => "b"}
          ],
          [%{"start_line" => 0, "new_text" => "invalid"}],
          [%{"start_line" => 1, "new_text" => <<0>>}]
        ] do
      assert {:error, _} =
               Edit.execute(
                 "edit",
                 %{"path" => path, "snapshot" => snapshot, "edits" => edits},
                 nil,
                 nil,
                 cwd,
                 []
               )

      assert File.read!(path) == content
    end
  end

  test "preserves BOM, CRLF, final newline, and accepts lowercase snapshot tags", %{tmp_dir: cwd} do
    path = Path.join(cwd, "format.txt")
    content = <<0xEF, 0xBB, 0xBF>> <> "one\r\ntwo\r\n"
    File.write!(path, content)

    assert %AgentToolResult{} =
             Edit.execute(
               "edit",
               %{
                 "path" => path,
                 "snapshot" => String.downcase(AnchoredEdit.snapshot(content)),
                 "edits" => [%{"start_line" => 2, "new_text" => "changed\n"}]
               },
               nil,
               nil,
               cwd,
               []
             )

    assert File.read!(path) == <<0xEF, 0xBB, 0xBF>> <> "one\r\nchanged\r\n"
  end

  test "supports append, blank replacement and deletion of all lines", %{tmp_dir: cwd} do
    path = Path.join(cwd, "boundaries.txt")
    File.write!(path, "one\ntwo")

    assert %AgentToolResult{} =
             Edit.execute(
               "append",
               %{
                 "path" => path,
                 "snapshot" => AnchoredEdit.snapshot("one\ntwo"),
                 "edits" => [
                   %{"operation" => "insert_after", "start_line" => 2, "new_text" => "three"}
                 ]
               },
               nil,
               nil,
               cwd,
               []
             )

    assert File.read!(path) == "one\ntwo\nthree"

    assert %AgentToolResult{} =
             Edit.execute(
               "blank",
               %{
                 "path" => path,
                 "snapshot" => AnchoredEdit.snapshot(File.read!(path)),
                 "edits" => [%{"start_line" => 2, "new_text" => ""}]
               },
               nil,
               nil,
               cwd,
               []
             )

    assert File.read!(path) == "one\n\nthree"

    assert %AgentToolResult{} =
             Edit.execute(
               "delete",
               %{
                 "path" => path,
                 "snapshot" => AnchoredEdit.snapshot(File.read!(path)),
                 "edits" => [%{"operation" => "delete", "start_line" => 1, "end_line" => 3}]
               },
               nil,
               nil,
               cwd,
               []
             )

    assert File.read!(path) == ""
  end

  test "rebases all uniquely unchanged anchors after unrelated disk changes", %{tmp_dir: cwd} do
    path = Path.join(cwd, "recover.txt")
    opts = [session_id: cwd]
    on_exit(fn -> CodingAgent.FileReadTracker.forget_session(cwd) end)
    File.write!(path, "first\nreplace\ninsert\nremove\nlast\n")
    read = Read.execute("read", %{"path" => path}, nil, nil, cwd, opts)
    File.write!(path, "user header\nfirst\nreplace\ninsert\nremove\nlast\n")

    assert %AgentToolResult{} =
             Edit.execute(
               "recover",
               %{
                 "path" => path,
                 "snapshot" => String.downcase(read.details.snapshot),
                 "edits" => [
                   %{"start_line" => 2, "new_text" => "replaced"},
                   %{"operation" => "insert_before", "start_line" => 3, "new_text" => "added"},
                   %{"operation" => "delete", "start_line" => 4}
                 ]
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert File.read!(path) == "user header\nfirst\nreplaced\nadded\ninsert\nlast\n"
  end

  test "refuses changed, ambiguous, and unknown historical anchors atomically", %{tmp_dir: cwd} do
    path = Path.join(cwd, "refuse.txt")
    opts = [session_id: cwd]
    on_exit(fn -> CodingAgent.FileReadTracker.forget_session(cwd) end)
    original = "first\nanchor\nlast\n"
    CodingAgent.FileReadTracker.record(opts, path, original)

    for {current, tag} <- [
          {"header\nfirst\nchanged\nlast\n", AnchoredEdit.snapshot(original)},
          {"anchor\nfirst\nanchor\nlast\n", AnchoredEdit.snapshot(original)},
          {"header\n" <> original, "0000000000000000"}
        ] do
      File.write!(path, current)

      assert {:error, message} =
               Edit.execute(
                 "refuse",
                 %{
                   "path" => path,
                   "snapshot" => tag,
                   "edits" => [
                     %{"start_line" => 1, "new_text" => "must not apply"},
                     %{"start_line" => 2, "new_text" => "replacement"}
                   ]
                 },
                 nil,
                 nil,
                 cwd,
                 opts
               )

      assert message =~ "Snapshot mismatch"
      assert File.read!(path) == current
    end
  end

  test "recovery compares raw bytes rather than normalized whitespace", %{tmp_dir: cwd} do
    path = Path.join(cwd, "raw.txt")
    opts = [session_id: cwd]
    on_exit(fn -> CodingAgent.FileReadTracker.forget_session(cwd) end)
    original = "first\n  anchor\nlast\n"
    CodingAgent.FileReadTracker.record(opts, path, original)
    File.write!(path, "header\nfirst\n anchor\nlast\n")

    assert {:error, message} =
             Edit.execute(
               "raw",
               %{
                 "path" => path,
                 "snapshot" => AnchoredEdit.snapshot(original),
                 "edits" => [%{"start_line" => 2, "new_text" => "replacement"}]
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert message =~ "Snapshot mismatch"
  end

  test "snapshot history is bounded and isolated by session and path", %{tmp_dir: cwd} do
    path = Path.join(cwd, "history.txt")
    opts = [session_id: cwd]
    on_exit(fn -> CodingAgent.FileReadTracker.forget_session(cwd) end)

    for n <- 1..9, do: CodingAgent.FileReadTracker.record(opts, path, "snapshot #{n}\n")

    assert CodingAgent.FileReadTracker.snapshot_lines(
             opts,
             path,
             AnchoredEdit.snapshot("snapshot 1\n")
           ) == nil

    tag = AnchoredEdit.snapshot("snapshot 2\n")
    assert CodingAgent.FileReadTracker.snapshot_lines(opts, path, tag) == ["snapshot 2"]
    assert CodingAgent.FileReadTracker.snapshot_lines([], path, tag) == nil
    assert CodingAgent.FileReadTracker.snapshot_lines([session_id: "other"], path, tag) == nil
    assert CodingAgent.FileReadTracker.snapshot_lines(opts, path <> ".other", tag) == nil

    oversized = String.duplicate("x", CodingAgent.FileReadTracker.snapshot_byte_limit() + 1)
    CodingAgent.FileReadTracker.record(opts, path, oversized)

    assert CodingAgent.FileReadTracker.snapshot_lines(
             opts,
             path,
             AnchoredEdit.snapshot(oversized)
           ) == nil

    CodingAgent.FileReadTracker.forget_session(cwd)
    assert CodingAgent.FileReadTracker.snapshot_lines(opts, path, tag) == nil
  end

  test "refuses unique historical ranges that would overlap after rebasing" do
    old = "a\nb\nseparator\nb\nc\n"
    current = "a\nb\nc\n"

    edits = [
      %{"start_line" => 1, "end_line" => 2, "new_text" => "first"},
      %{"start_line" => 4, "end_line" => 5, "new_text" => "second"}
    ]

    assert {:error, message} =
             AnchoredEdit.apply(
               current,
               current,
               AnchoredEdit.snapshot(old),
               edits,
               AnchoredEdit.lines(old)
             )

    assert message =~ "Snapshot mismatch"
  end
end
