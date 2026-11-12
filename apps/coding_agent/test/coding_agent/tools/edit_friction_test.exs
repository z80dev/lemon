defmodule CodingAgent.Tools.EditFrictionTest do
  use ExUnit.Case, async: true

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.{AnchoredEdit, Edit, FileValidation, Patch, Read}
  alias CodingAgent.Tools.Task.StructuredOutput
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "first\noriginal\nlast\n")
    on_exit(fn -> FileReadTracker.forget_session(cwd) end)
    %{cwd: cwd, path: path, opts: [session_id: cwd, filesystem_checkpoints: false]}
  end

  test "provider-valid schema describes both modes; runtime rejects mixed or incomplete calls",
       ctx do
    schema = Edit.tool(ctx.cwd).parameters
    refute Map.has_key?(schema, "oneOf")
    refute Map.has_key?(schema, "anyOf")
    refute Map.has_key?(schema, "allOf")
    assert schema["properties"]["mode"]["enum"] == ["anchored", "text"]

    anchored = %{
      "path" => ctx.path,
      "snapshot" => AnchoredEdit.snapshot(File.read!(ctx.path)),
      "edits" => [%{"start_line" => 2, "new_text" => "changed"}]
    }

    text = %{"path" => ctx.path, "old_text" => "original", "new_text" => "changed"}

    for params <- [
          anchored,
          text,
          Map.put(anchored, "mode", "anchored"),
          Map.put(text, "mode", "text")
        ] do
      assert {:ok, ^params} = StructuredOutput.decode(Jason.encode!(params), schema)
    end

    for params <- [
          Map.merge(anchored, text),
          Map.put(anchored, "old_text", "original"),
          Map.put(anchored, "new_text", "changed"),
          Map.put(text, "snapshot", anchored["snapshot"]),
          Map.put(text, "edits", anchored["edits"]),
          Map.delete(anchored, "snapshot"),
          Map.delete(text, "new_text")
        ] do
      assert {:error, _} = Edit.execute("edit", params, nil, nil, ctx.cwd, ctx.opts)
      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
    end
  end

  test "explicit modes reject conflicting fields with actionable drop instructions", ctx do
    for {mode, fields, drop} <- [
          {"anchored", %{"old_text" => "original", "new_text" => "unsafe"},
           "drop top-level old_text and new_text"},
          {"text",
           %{
             "snapshot" => AnchoredEdit.snapshot(File.read!(ctx.path)),
             "edits" => [%{"start_line" => 2, "new_text" => "unsafe"}]
           }, "drop snapshot and edits"}
        ] do
      params = Map.merge(%{"path" => ctx.path, "mode" => mode}, fields)
      assert {:error, message} = Edit.execute("edit", params, nil, nil, ctx.cwd, ctx.opts)
      assert message =~ drop
      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
    end
  end

  test "copied headers bind the tag to their named target even for identical bytes", ctx do
    other = Path.join(ctx.cwd, "other.txt")
    File.write!(other, File.read!(ctx.path))
    read = Read.execute("read", %{"path" => other}, nil, nil, ctx.cwd, ctx.opts)

    for header <- ["[#{other}##{read.details.snapshot}]", "[other.txt##{read.details.snapshot}]"] do
      assert {:error, message} = anchored(ctx, header, 2, "unsafe")
      assert message =~ "header path does not name"
      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
      assert File.read!(other) == "first\noriginal\nlast\n"
    end

    assert %AgentToolResult{} =
             anchored(ctx, "[./file.txt##{read.details.snapshot}]", 2, "same target")
  end

  test "pinned mutation reads and writes refuse swapped symlinks and replacement inodes", ctx do
    secret = Path.join(ctx.cwd, "private.txt")
    File.write!(secret, "private content must not be disclosed")

    for replacement <- [:symlink, :regular] do
      {:ok, identity} = FileValidation.regular_file_identity(ctx.path)
      original = ctx.path <> ".original"
      File.rename!(ctx.path, original)

      if replacement == :symlink,
        do: File.ln_s!(secret, ctx.path),
        else: File.write!(ctx.path, "replacement contents")

      assert {:error, message} = FileValidation.read_regular_file(ctx.path, identity)
      assert message =~ "identity changed"
      refute message =~ "private content"
      refute message =~ "replacement contents"
      assert {:error, _} = FileValidation.write_regular_file(ctx.path, identity, "unsafe")
      assert File.read!(secret) == "private content must not be disclosed"
      assert File.read!(original) == "first\noriginal\nlast\n"
      File.rm!(ctx.path)
      File.rename!(original, ctx.path)
    end
  end

  test "copied headers, bracketed tags and whitespace normalize without weakening snapshots",
       ctx do
    original = File.read!(ctx.path)
    tag = AnchoredEdit.snapshot(original)

    for value <- [
          tag,
          String.downcase(tag),
          "  #{tag}\n",
          "[#{tag}]",
          " [ #{tag} ] ",
          "[#{ctx.path}##{tag}]",
          "file.txt##{tag}"
        ] do
      File.write!(ctx.path, original)
      assert %AgentToolResult{} = anchored(ctx, value, 2, "accepted")
      assert File.read!(ctx.path) == "first\naccepted\nlast\n"
    end

    for value <- [
          "[file##{tag}] [other##{tag}]",
          "#{tag} extra",
          "#{tag}#{tag}",
          "[file##{tag}#0000000000000000]",
          nil,
          123
        ] do
      File.write!(ctx.path, original)
      assert {:error, _} = anchored(ctx, value, 2, "unsafe")
      assert File.read!(ctx.path) == original
    end

    File.write!(ctx.path, "first\nuser change\nlast\n")
    assert {:error, message} = anchored(ctx, "[file.txt##{tag}]", 2, "unsafe")
    assert message =~ "Current snapshot"
    assert message =~ "2: user change"
    assert File.read!(ctx.path) == "first\nuser change\nlast\n"
  end

  test "text stale errors supply a fresh tag and relevant lines for a direct anchored retry",
       ctx do
    Read.execute("read", %{"path" => ctx.path}, nil, nil, ctx.cwd, ctx.opts)
    current = "first\nuser changed\nlast\n"
    File.write!(ctx.path, current)

    assert {:error, message} =
             Edit.execute(
               "edit",
               %{"path" => ctx.path, "old_text" => "original", "new_text" => "unsafe"},
               nil,
               nil,
               ctx.cwd,
               ctx.opts
             )

    tag = AnchoredEdit.snapshot(current)
    assert message =~ "modified on disk since you last read it"
    assert message =~ "[#{ctx.path}##{tag}]"
    assert message =~ "2: user changed"
    assert File.read!(ctx.path) == current
    assert %AgentToolResult{} = anchored(ctx, tag, 2, "reviewed")
    assert File.read!(ctx.path) == "first\nreviewed\nlast\n"
  end

  test "retry feedback remains bounded and includes a distant targeted line", ctx do
    old = Enum.map_join(1..1000, "", &"line #{&1}\n")
    File.write!(ctx.path, old)
    Read.execute("read", %{"path" => ctx.path, "limit" => 1}, nil, nil, ctx.cwd, ctx.opts)
    current = String.replace(old, "line 900\n", "user changed 900\n")
    File.write!(ctx.path, current)
    assert {:error, message} = anchored(ctx, AnchoredEdit.snapshot(old), 900, "unsafe")
    assert message =~ "900: user changed 900"
    refute message =~ "1: line 1\n"
    assert byte_size(message) < 10_000
    assert File.read!(ctx.path) == current
  end

  test "repeated canonical updates apply in order and return one original-to-final result", ctx do
    patch =
      "*** Update File: file.txt\n@@\n-original\n+intermediate\n*** Update File: ./file.txt\n@@\n-intermediate\n+final\n"

    assert %AgentToolResult{details: details} = patch(ctx, patch)
    assert File.read!(ctx.path) == "first\nfinal\nlast\n"
    path = ctx.path

    assert [
             %{
               path: ^path,
               oldText: "first\noriginal\nlast\n",
               newText: "first\nfinal\nlast\n",
               snapshot: tag
             }
           ] = details.perFileResults

    assert tag == AnchoredEdit.snapshot(File.read!(path))
    assert details.changed == [path]
  end

  test "add, update, move, update, delete and add may share paths", ctx do
    patch = """
    *** Add File: new.txt
    +one
    *** Update File: new.txt
    @@
    -one
    +two
    *** Update File: new.txt
    *** Move to: moved.txt
    *** Update File: moved.txt
    @@
    -two
    +three
    *** Delete File: moved.txt
    *** Add File: moved.txt
    +final
    """

    assert %AgentToolResult{details: details} = patch(ctx, patch)
    refute File.exists?(Path.join(ctx.cwd, "new.txt"))
    moved = Path.join(ctx.cwd, "moved.txt")
    assert File.read!(moved) == "final"
    assert [%{path: ^moved, oldText: nil, newText: "final"}] = details.perFileResults
  end

  test "a bad later same-path operation never commits the valid prefix", ctx do
    for suffix <- [
          "*** Update File: file.txt\n@@\n-not present\n+unsafe\n",
          "*** Delete File: file.txt\n*** Update File: file.txt\n@@\n-intermediate\n+unsafe\n",
          "*** Add File: ./file.txt\n+unsafe\n"
        ] do
      assert {:error, _} =
               patch(ctx, "*** Update File: file.txt\n@@\n-original\n+intermediate\n" <> suffix)

      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
    end
  end

  test "ordinary git unified diffs support multiple hunks and final snapshots", ctx do
    File.write!(ctx.path, "first\noriginal\nmiddle\nother\nlast\n")

    diff = """
    diff --git a/file.txt b/file.txt
    index 1234567..7654321 100644
    --- a/file.txt
    +++ b/file.txt
    @@ -1,2 +1,2 @@
     first
    -original
    +changed
    @@ -4,2 +4,2 @@ section
    -other
    +updated
     last
    """

    assert {:ok, ["file.txt"]} = Patch.affected_paths(diff)
    assert %AgentToolResult{} = patch(ctx, diff)
    assert File.read!(ctx.path) == "first\nchanged\nmiddle\nupdated\nlast\n"
  end

  test "unified counts may be omitted and newline markers are respected", ctx do
    File.write!(ctx.path, "old")

    diff =
      "--- file.txt\n+++ file.txt\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"

    assert %AgentToolResult{} = patch(ctx, diff)
    assert File.read!(ctx.path) == "new"

    assert %AgentToolResult{} =
             patch(
               ctx,
               "--- file.txt\n+++ file.txt\n@@ -1 +1 @@\n-new\n\\ No newline at end of file\n+newline\n"
             )

    assert File.read!(ctx.path) == "newline\n"
  end

  test "removal-only EOF hunks preserve the surviving line terminator", ctx do
    for {old, expected} <- [
          {"first\nlast\n", "first\n"},
          {"first\r\nlast\r\n", "first\r\n"},
          {"first\nlast", "first\n"}
        ] do
      File.write!(ctx.path, old)
      FileReadTracker.record(ctx.opts, ctx.path, old)
      marker = if String.ends_with?(old, "\n"), do: "", else: "\\ No newline at end of file\n"

      assert %AgentToolResult{} =
               patch(ctx, "--- file.txt\n+++ file.txt\n@@ -2 +1,0 @@\n-last\n" <> marker)

      assert File.read!(ctx.path) == expected
    end
  end

  test "no-newline markers reject interior old, added, and kept lines", ctx do
    for body <- [
          "@@ -2 +2 @@\n-original\n\\ No newline at end of file\n+changed\n",
          "@@ -2 +2 @@\n-original\n+changed\n\\ No newline at end of file\n",
          "@@ -2,2 +2,2 @@\n original\n\\ No newline at end of file\n-last\n+changed\n",
          "@@ -2,2 +2,2 @@\n-original\n+changed\n\\ No newline at end of file\n last\n"
        ] do
      assert {:error, message} = patch(ctx, "--- file.txt\n+++ file.txt\n" <> body)
      assert message =~ "no-newline marker"
      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
    end
  end

  test "unified additions, insertions, deletions and repeated paths preflight together", ctx do
    diff =
      "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,1 @@\n+created\n--- a/new.txt\n+++ b/new.txt\n@@ -1,0 +2,1 @@\n+appended\n--- a/file.txt\n+++ /dev/null\n@@ -1,3 +0,0 @@\n-first\n-original\n-last\n"

    assert %AgentToolResult{} = patch(ctx, diff)
    assert File.read!(Path.join(ctx.cwd, "new.txt")) == "created\nappended\n"
    refute File.exists?(ctx.path)
  end

  test "unified hunk coordinates do not disambiguate repeated context", ctx do
    File.write!(ctx.path, "same\nseparator\nsame\n")

    assert {:error, message} =
             patch(ctx, "--- file.txt\n+++ file.txt\n@@ -3 +3 @@\n-same\n+changed\n")

    assert message =~ "Ambiguous patch hunk"
    assert message =~ "lines 1, 3"
    assert message =~ "1: same"
    assert message =~ "3: same"
    assert File.read!(ctx.path) == "same\nseparator\nsame\n"
  end

  test "malformed, unsafe and context-mismatching unified diffs never mutate", ctx do
    for diff <- [
          "--- file.txt\n+++ file.txt\n@@ -2,2 +2,1 @@\n-original\n+unsafe\n",
          "--- file.txt\n+++ file.txt\n@@ -2 +2 @@\n-not original\n+unsafe\n",
          "--- ../outside.txt\n+++ ../outside.txt\n@@ -1 +1 @@\n-a\n+b\n",
          "--- file.txt\n+++ /dev/null\n@@ -2 +0,0 @@\n-original\n",
          "--- file.txt\n+++ file.txt\n@@ -3 +3 @@\n-last\n\\ No newline at end of file\n+unsafe\n"
        ] do
      assert {:error, _} = patch(ctx, diff)
      assert File.read!(ctx.path) == "first\noriginal\nlast\n"
    end
  end

  defp anchored(ctx, tag, line, text),
    do:
      Edit.execute(
        "edit",
        %{
          "path" => ctx.path,
          "snapshot" => tag,
          "edits" => [%{"start_line" => line, "new_text" => text}]
        },
        nil,
        nil,
        ctx.cwd,
        ctx.opts
      )

  defp patch(ctx, text),
    do: Patch.execute("patch", %{"patch_text" => text}, nil, nil, ctx.cwd, ctx.opts)
end
