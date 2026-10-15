defmodule CodingAgent.Tools.PatchStaleTest do
  use ExUnit.Case, async: false

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.Patch
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup do
    if Process.whereis(FileReadTracker) == nil, do: start_supervised!(FileReadTracker)
    session = "patch-stale-#{System.unique_integer([:positive])}"
    on_exit(fn -> FileReadTracker.forget_session(session) end)
    {:ok, opts: [session_id: session, filesystem_checkpoints: false]}
  end

  for operation <- [:update, :delete, :move] do
    test "refuses stale #{operation} before any write", %{tmp_dir: cwd, opts: opts} do
      path = Path.join(cwd, "source.txt")
      File.write!(path, "old\n")
      FileReadTracker.record(opts, path, "old\n")
      File.write!(path, "current\n")

      patch =
        "*** Begin Patch\n*** Add File: added.txt\n+untouched\n" <>
          operation_patch(unquote(operation)) <> "*** End Patch\n"

      assert {:error, message} = run(cwd, patch, opts)
      assert message =~ "modified on disk since you last read it"
      assert message =~ "Re-read"
      refute message =~ ":stale"
      assert File.read!(path) == "current\n"
      refute File.exists?(Path.join(cwd, "added.txt"))
      refute File.exists?(Path.join(cwd, "moved.txt"))
    end

    test "allows unread #{operation}", %{tmp_dir: cwd, opts: opts} do
      path = Path.join(cwd, "source.txt")
      File.write!(path, "current\n")

      assert %AgentToolResult{} =
               run(
                 cwd,
                 "*** Begin Patch\n" <> operation_patch(unquote(operation)) <> "*** End Patch\n",
                 opts
               )

      case unquote(operation) do
        :update ->
          assert File.read!(path) == "new\n"

        :delete ->
          refute File.exists?(path)

        :move ->
          refute File.exists?(path)
          assert File.read!(Path.join(cwd, "moved.txt")) == "new\n"
      end
    end
  end

  test "re-reading permits a previously stale update", %{tmp_dir: cwd, opts: opts} do
    path = Path.join(cwd, "source.txt")
    File.write!(path, "current\n")
    FileReadTracker.record(opts, path, "old\n")
    FileReadTracker.record(opts, path, File.read!(path))

    assert %AgentToolResult{} =
             run(cwd, "*** Begin Patch\n" <> operation_patch(:update) <> "*** End Patch\n", opts)

    assert File.read!(path) == "new\n"
  end

  test "missing files report an actionable error", %{tmp_dir: cwd, opts: opts} do
    assert {:error, message} =
             run(cwd, "*** Begin Patch\n*** Delete File: absent.txt\n*** End Patch\n", opts)

    assert message =~ "File not found"
    refute message =~ ":enoent"
  end

  defp operation_patch(:delete), do: "*** Delete File: source.txt\n"
  defp operation_patch(:update), do: "*** Update File: source.txt\n@@\n-current\n+new\n"

  defp operation_patch(:move),
    do: "*** Update File: source.txt\n*** Move to: moved.txt\n@@\n-current\n+new\n"

  defp run(cwd, patch, opts),
    do: Patch.execute("patch", %{"patch_text" => patch}, nil, nil, cwd, opts)
end
