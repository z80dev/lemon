defmodule CodingAgent.Tools.Lsp.WorkspaceEditTest do
  use ExUnit.Case, async: false

  alias CodingAgent.FileReadTracker
  alias CodingAgent.Tools.Lsp.{Text, WorkspaceEdit}

  setup do
    tmp = Path.join(System.tmp_dir!(), "lsp_wedit_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    tmp = Text.realpath(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp uri(tmp, name), do: Text.path_to_uri(Path.join(tmp, name))

  defp edit(line, from, to, text) do
    %{
      "range" => %{
        "start" => %{"line" => line, "character" => from},
        "end" => %{"line" => line, "character" => to}
      },
      "newText" => text
    }
  end

  test "plans documentChanges in order, flushing text edits before resource ops", %{tmp: tmp} do
    edit = %{
      "documentChanges" => [
        %{
          "textDocument" => %{"uri" => uri(tmp, "a.c"), "version" => 1},
          "edits" => [edit(0, 0, 1, "A")]
        },
        %{
          "textDocument" => %{"uri" => uri(tmp, "b.c"), "version" => 1},
          "edits" => [edit(0, 0, 1, "B")]
        },
        %{"kind" => "rename", "oldUri" => uri(tmp, "a.c"), "newUri" => uri(tmp, "dir/c.c")},
        %{
          "textDocument" => %{"uri" => uri(tmp, "dir/c.c"), "version" => 2},
          "edits" => [edit(0, 1, 2, "C")]
        },
        %{"kind" => "create", "uri" => uri(tmp, "new.c")}
      ]
    }

    assert {:ok, ops} = WorkspaceEdit.plan(edit)

    assert Enum.map(ops, &{&1.kind, Map.get(&1, :path) || Path.basename(&1.to)}) == [
             {:text, Path.join(tmp, "a.c")},
             {:rename, "c.c"},
             {:create, Path.join(tmp, "new.c")},
             {:text, Path.join(tmp, "b.c")},
             {:text, Path.join(tmp, "dir/c.c")}
           ]

    assert WorkspaceEdit.describe(ops, tmp) == [
             "a.c: 1 edit (line 1)",
             "RENAME: a.c → dir/c.c",
             "CREATE: new.c",
             "b.c: 1 edit (line 1)",
             "dir/c.c: 1 edit (line 1)"
           ]
  end

  test "applies text, rename, create and delete operations and refreshes the read tracker", %{
    tmp: tmp
  } do
    File.write!(Path.join(tmp, "a.c"), "aaa\n")
    File.write!(Path.join(tmp, "b.c"), "bbb\n")
    File.write!(Path.join(tmp, "gone.c"), "x")
    File.chmod!(Path.join(tmp, "b.c"), 0o640)
    session_id = "wedit-#{System.unique_integer([:positive])}"
    opts = [session_id: session_id, filesystem_checkpoints: false]
    FileReadTracker.record(opts, Path.join(tmp, "b.c"), "bbb\n")

    edit = %{
      "documentChanges" => [
        %{"textDocument" => %{"uri" => uri(tmp, "a.c")}, "edits" => [edit(0, 0, 1, "A")]},
        %{"kind" => "rename", "oldUri" => uri(tmp, "a.c"), "newUri" => uri(tmp, "dir/c.c")},
        %{"textDocument" => %{"uri" => uri(tmp, "dir/c.c")}, "edits" => [edit(0, 1, 2, "C")]},
        %{"textDocument" => %{"uri" => uri(tmp, "b.c")}, "edits" => [edit(0, 0, 3, "BBB")]},
        %{"kind" => "create", "uri" => uri(tmp, "new.c")},
        %{"kind" => "delete", "uri" => uri(tmp, "gone.c")}
      ]
    }

    {:ok, ops} = WorkspaceEdit.plan(edit)

    assert {:ok, %{changed: changed, applied: applied}} =
             WorkspaceEdit.apply(ops, tmp, opts, nil, %{tool: "lsp", action: "rename"})

    assert File.read!(Path.join(tmp, "dir/c.c")) == "ACa\n"
    refute File.exists?(Path.join(tmp, "a.c"))
    assert File.read!(Path.join(tmp, "b.c")) == "BBB\n"
    assert File.stat!(Path.join(tmp, "b.c")).mode |> Bitwise.band(0o777) == 0o640
    assert File.read!(Path.join(tmp, "new.c")) == ""
    refute File.exists?(Path.join(tmp, "gone.c"))
    assert Path.join(tmp, "dir/c.c") in changed
    assert "Renamed a.c → dir/c.c" in applied
    assert "Deleted gone.c" in applied
    assert Path.wildcard(Path.join(tmp, "**/.*.tmp"), match_dot: true) == []

    # The tracker now holds the post-edit bytes, so a later `edit` is not stale.
    assert :ok = FileReadTracker.check(opts, Path.join(tmp, "b.c"), "BBB\n")
  end

  test "rejects invalid edits before writing any file", %{tmp: tmp} do
    File.write!(Path.join(tmp, "a.c"), "abcdef\n")
    File.write!(Path.join(tmp, "b.c"), "xyz\n")

    edit = %{
      "changes" => %{
        uri(tmp, "a.c") => [edit(0, 0, 1, "Q")],
        uri(tmp, "b.c") => [edit(0, 0, 2, "1"), edit(0, 1, 3, "2")]
      }
    }

    {:ok, ops} = WorkspaceEdit.plan(edit)

    assert {:error, message} =
             WorkspaceEdit.apply(ops, tmp, [filesystem_checkpoints: false], nil, %{tool: "lsp"})

    assert message =~ "overlapping"
    assert File.read!(Path.join(tmp, "a.c")) == "abcdef\n"
    assert File.read!(Path.join(tmp, "b.c")) == "xyz\n"
  end

  test "refuses to create over an existing file unless allowed", %{tmp: tmp} do
    File.write!(Path.join(tmp, "a.c"), "keep")
    create = %{"kind" => "create", "uri" => uri(tmp, "a.c")}

    {:ok, ops} = WorkspaceEdit.plan(%{"documentChanges" => [create]})

    assert {:error, message} =
             WorkspaceEdit.apply(ops, tmp, [filesystem_checkpoints: false], nil, %{})

    assert message =~ "already exists"

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [Map.put(create, "options", %{"ignoreIfExists" => true})]
      })

    assert {:ok, %{changed: []}} =
             WorkspaceEdit.apply(ops, tmp, [filesystem_checkpoints: false], nil, %{})

    assert File.read!(Path.join(tmp, "a.c")) == "keep"
  end
end
