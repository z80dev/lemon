defmodule CodingAgent.Tools.EditFormatTest do
  use ExUnit.Case, async: true

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.{AnchoredEdit, Edit, Patch}
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  test "edit returns the formatted snapshot and accepts the next anchored edit", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "old\n")

    formatter = fn ^path, opts ->
      assert opts == [cwd: cwd, timeout_ms: 321]
      File.write!(path, "formatted\nnew\n")
      {:ok, :formatted}
    end

    opts = [session_id: cwd, format_file_fun: formatter, format_timeout_ms: 321]
    on_exit(fn -> FileReadTracker.forget_session(cwd) end)

    result =
      Edit.execute(
        "edit",
        %{"path" => path, "old_text" => "old", "new_text" => "new", "format" => true},
        nil,
        nil,
        cwd,
        opts
      )

    assert %AgentToolResult{details: %{formatted: true} = details} = result
    assert details.snapshot == AnchoredEdit.snapshot("formatted\nnew\n")
    assert details.newText == "formatted\nnew\n"
    assert hd(result.content).text =~ "Formatted the file"
    assert FileReadTracker.check(opts, path, File.read!(path)) == :ok

    assert %AgentToolResult{} =
             Edit.execute(
               "next",
               %{
                 "path" => path,
                 "snapshot" => details.snapshot,
                 "edits" => [%{"start_line" => 2, "new_text" => "next"}]
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert File.read!(path) == "formatted\nnext\n"
  end

  test "format defaults and explicit overrides match write semantics", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "old\n")

    formatter = fn ^path, _ ->
      File.write!(path, "formatted\n")
      {:ok, :formatted}
    end

    opts = [format: true, format_file_fun: formatter]
    params = %{"path" => path, "old_text" => "old", "new_text" => "new"}

    assert %AgentToolResult{details: %{formatted: false}} =
             Edit.execute("off", Map.put(params, "format", false), nil, nil, cwd, opts)

    assert File.read!(path) == "new\n"
    params = %{params | "old_text" => "new", "new_text" => "changed"}

    assert %AgentToolResult{details: %{formatted: true}} =
             Edit.execute("default", params, nil, nil, cwd, opts)

    assert File.read!(path) == "formatted\n"

    assert {:error, "format must be a boolean"} =
             Edit.execute("bad", Map.put(params, "format", "yes"), nil, nil, cwd, opts)
  end

  test "patch formats add update and move targets but not deletions", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "update.txt"), "old\n")
    File.write!(Path.join(cwd, "source.txt"), "source\n")
    File.write!(Path.join(cwd, "delete.txt"), "delete\n")

    formatter = fn path, _ ->
      assert Path.basename(path) in ["add.txt", "update.txt", "moved.txt"]
      File.write!(path, "formatted\n" <> File.read!(path))
      {:ok, :formatted}
    end

    opts = [session_id: cwd, format: true, format_file_fun: formatter]
    on_exit(fn -> FileReadTracker.forget_session(cwd) end)

    patch =
      "*** Begin Patch\n*** Add File: add.txt\n+added\n*** Update File: update.txt\n@@\n-old\n+updated\n*** Update File: source.txt\n*** Move to: moved.txt\n@@\n-source\n+moved\n*** Delete File: delete.txt\n*** End Patch"

    assert %AgentToolResult{details: %{formatted: true} = details} =
             result = Patch.execute("patch", %{"patch_text" => patch}, nil, nil, cwd, opts)

    for name <- ["add.txt", "update.txt", "moved.txt"] do
      path = Path.join(cwd, name)
      entry = Enum.find(details.perFileResults, &(&1.path == path))
      assert entry.formatted
      assert entry.snapshot == AnchoredEdit.snapshot(File.read!(path))
      assert entry.newText == File.read!(path)
      assert hd(result.content).text =~ "[#{path}##{entry.snapshot}]"
      assert FileReadTracker.check(opts, path, File.read!(path)) == :ok
    end

    refute File.exists?(Path.join(cwd, "source.txt"))
    refute File.exists?(Path.join(cwd, "delete.txt"))
    entry = Enum.find(details.perFileResults, &(&1.path == Path.join(cwd, "update.txt")))

    assert %AgentToolResult{} =
             Edit.execute(
               "next",
               %{
                 "path" => entry.path,
                 "snapshot" => entry.snapshot,
                 "edits" => [%{"start_line" => 2, "new_text" => "next"}],
                 "format" => false
               },
               nil,
               nil,
               cwd,
               opts
             )

    assert File.read!(entry.path) == "formatted\nnext\n"
  end

  test "formatter errors do not undo successful edits or advertise stale tags", %{tmp_dir: cwd} do
    path = Path.join(cwd, "file.txt")
    File.write!(path, "old\n")
    opts = [format_file_fun: fn _, _ -> {:error, "formatter failed"} end]

    assert %AgentToolResult{details: details} =
             Edit.execute(
               "edit",
               %{"path" => path, "old_text" => "old", "new_text" => "new", "format" => true},
               nil,
               nil,
               cwd,
               opts
             )

    assert details.format_error == "formatter failed"
    refute details.formatted
    assert details.snapshot == AnchoredEdit.snapshot(File.read!(path))
  end

  test "local edit invokes the real Elixir formatter", %{tmp_dir: cwd} do
    path = Path.join(cwd, "example.ex")
    File.write!(path, "value = 1\n")

    assert %AgentToolResult{details: details} =
             Edit.execute(
               "edit",
               %{"path" => path, "old_text" => "1", "new_text" => "[1,2]", "format" => true},
               nil,
               nil,
               cwd,
               []
             )

    assert details.formatted
    assert File.read!(path) == "value = [1, 2]\n"
    assert details.snapshot == AnchoredEdit.snapshot(File.read!(path))
  end
end
