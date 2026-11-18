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

  test "file rename refuses an existing destination without overwriting it", %{tmp: tmp} do
    File.write!(Path.join(tmp, "source.c"), "source\n")
    File.write!(Path.join(tmp, "target.c"), "target\n")

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [
          %{
            "kind" => "rename",
            "oldUri" => uri(tmp, "source.c"),
            "newUri" => uri(tmp, "target.c")
          }
        ]
      })

    assert {:error, message} =
             WorkspaceEdit.apply(ops, tmp, [filesystem_checkpoints: false], nil, %{
               tool: "lsp",
               action: "rename_file"
             })

    assert message =~ "already exists"
    assert File.read!(Path.join(tmp, "source.c")) == "source\n"
    assert File.read!(Path.join(tmp, "target.c")) == "target\n"
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

  test "resource operations refuse symlink parents before changing any file", %{tmp: tmp} do
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "keep.c"), "keep")
    File.ln_s!(outside, Path.join(tmp, "alias"))

    for change <- [
          %{"kind" => "delete", "uri" => uri(tmp, "alias/keep.c")},
          %{
            "kind" => "rename",
            "oldUri" => uri(tmp, "alias/keep.c"),
            "newUri" => uri(tmp, "new.c")
          }
        ] do
      {:ok, ops} =
        WorkspaceEdit.plan(%{
          "documentChanges" => [%{"kind" => "create", "uri" => uri(tmp, "first.c")}, change]
        })

      assert {:error, message} =
               WorkspaceEdit.apply(ops, tmp, [filesystem_checkpoints: false], nil, %{})

      assert message =~ "symlink"
      assert File.read!(Path.join(outside, "keep.c")) == "keep"
      refute File.exists?(Path.join(tmp, "first.c"))
      refute File.exists?(Path.join(tmp, "new.c"))
    end
  end

  test "refuses stale document bytes and versions before creating other files", %{tmp: tmp} do
    path = Path.join(tmp, "main.c")
    original = "int value;\n"
    File.write!(path, original)
    documents = %{path => %{version: 2, digest: :erlang.md5(original)}}
    opts = [filesystem_checkpoints: false, lsp_documents: documents]

    edit = %{
      "documentChanges" => [
        %{"kind" => "create", "uri" => uri(tmp, "new.c")},
        %{
          "textDocument" => %{"uri" => uri(tmp, "main.c"), "version" => 1},
          "edits" => [edit(0, 4, 9, "other")]
        }
      ]
    }

    {:ok, ops} = WorkspaceEdit.plan(edit)
    assert {:error, message} = WorkspaceEdit.apply(ops, tmp, opts, nil, %{})
    assert message =~ "version"
    refute File.exists?(Path.join(tmp, "new.c"))

    {:ok, ops} =
      WorkspaceEdit.plan(%{"changes" => %{uri(tmp, "main.c") => [edit(0, 4, 9, "other")]}})

    File.write!(path, "// user edit\n" <> original)
    assert {:error, message} = WorkspaceEdit.apply(ops, tmp, opts, nil, %{})
    assert message =~ "changed since"
    assert File.read!(path) == "// user edit\n" <> original
  end

  test "a partial write failure returns a complete recoverable checkpoint receipt", %{tmp: tmp} do
    paths = Application.get_env(:lemon_core, :paths, [])

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(paths, :checkpoint_dir, Path.join(tmp, "checkpoints"))
    )

    on_exit(fn -> Application.put_env(:lemon_core, :paths, paths) end)
    existing = Path.join(tmp, "existing.c")
    created = Path.join(tmp, "created.c")
    File.write!(existing, "keep")

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [
          %{"kind" => "create", "uri" => uri(tmp, "created.c")},
          %{"kind" => "create", "uri" => uri(tmp, "existing.c")}
        ]
      })

    opts = [
      session_id: "partial-#{System.unique_integer([:positive])}",
      filesystem_checkpoints: true
    ]

    assert {:error, _reason, receipt} = WorkspaceEdit.apply(ops, tmp, opts, nil, %{tool: "lsp"})
    assert receipt.changed == [created]
    assert length(receipt.applied) == 1
    assert File.exists?(created)
    assert File.read!(existing) == "keep"

    assert {:ok, _} =
             CodingAgent.Checkpoint.restore_filesystem(receipt.checkpoint.id, opts[:session_id])

    refute File.exists?(created)
    assert File.read!(existing) == "keep"
  end

  test "failed operations report every path they already wrote", %{tmp: tmp} do
    opts = [filesystem_checkpoints: false]
    first = Path.join(tmp, "first.c")
    nested = Path.join(tmp, "nested")

    # The rename creates destination parents before discovering its missing source.
    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [
          %{"kind" => "create", "uri" => uri(tmp, "first.c")},
          %{
            "kind" => "rename",
            "oldUri" => uri(tmp, "missing.c"),
            "newUri" => uri(tmp, "nested/deep/moved.c")
          }
        ]
      })

    assert {:error, reason, receipt} = WorkspaceEdit.apply(ops, tmp, opts, nil, %{tool: "lsp"})
    assert receipt.changed == [first, nested]
    assert receipt.applied == ["Created first.c"]
    assert reason =~ "2 path(s) were already changed: #{first}, #{nested}"
    assert File.dir?(Path.join(nested, "deep"))

    # A recursive delete can remove descendants before failing on a locked parent.
    tree = Path.join(tmp, "tree")
    locked = Path.join(tree, "locked")
    removed = Path.join([locked, "sub", "x.c"])
    File.mkdir_p!(Path.dirname(removed))
    File.write!(removed, "x")
    File.chmod!(locked, 0o555)
    on_exit(fn -> File.chmod(locked, 0o755) end)

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [
          %{"kind" => "delete", "uri" => uri(tmp, "tree"), "options" => %{"recursive" => true}}
        ]
      })

    assert {:error, reason, receipt} = WorkspaceEdit.apply(ops, tmp, opts, nil, %{tool: "lsp"})
    assert receipt.changed == [tree]
    assert receipt.applied == []
    assert reason =~ "1 path(s) were already changed: #{tree}"
    refute File.exists?(removed)
    assert File.dir?(Path.dirname(removed))
    File.chmod!(locked, 0o755)
  end

  test "abort after checkpoint publication retains the receipt without writing", %{tmp: tmp} do
    paths = Application.get_env(:lemon_core, :paths, [])

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(paths, :checkpoint_dir, Path.join(tmp, "checkpoints"))
    )

    on_exit(fn -> Application.put_env(:lemon_core, :paths, paths) end)
    signal = LemonAgent.AbortSignal.new()
    parent = self()

    opts = [
      session_id: "abort-#{System.unique_integer([:positive])}",
      filesystem_checkpoints: true,
      on_checkpoint: fn checkpoint ->
        send(parent, {:published, checkpoint.id})
        LemonAgent.AbortSignal.abort(signal)
      end
    ]

    {:ok, ops} =
      WorkspaceEdit.plan(%{
        "documentChanges" => [
          %{"kind" => "create", "uri" => uri(tmp, "never.c")}
        ]
      })

    assert {:error, _reason, receipt} =
             WorkspaceEdit.apply(ops, tmp, opts, signal, %{tool: "lsp"})

    assert_receive {:published, checkpoint_id}
    assert receipt.checkpoint.id == checkpoint_id
    assert receipt.changed == []
    assert receipt.applied == []
    refute File.exists?(Path.join(tmp, "never.c"))
    assert {:ok, _} = CodingAgent.Checkpoint.restore_filesystem(checkpoint_id, opts[:session_id])
  end

  describe "operations revalidated against earlier operations" do
    setup %{tmp: tmp} do
      ws = Path.join(tmp, "ws")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(Path.join(ws, "d"))
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.c"), "secret\n")
      File.ln_s!(outside, Path.join(ws, "d/sub"))
      File.ln_s!(Path.join(outside, "secret.c"), Path.join(ws, "d/file.c"))
      {:ok, ws: ws, outside: outside}
    end

    defp run(ws, changes) do
      {:ok, ops} = WorkspaceEdit.plan(%{"documentChanges" => changes})
      WorkspaceEdit.apply(ops, ws, [filesystem_checkpoints: false], nil, %{tool: "lsp"})
    end

    defp rename_d(ws),
      do: %{"kind" => "rename", "oldUri" => uri(ws, "d"), "newUri" => uri(ws, "e")}

    test "rename then text edit through a moved symlinked directory", %{ws: ws, outside: out} do
      File.write!(Path.join(out, "x.c"), "keep\n")

      result =
        run(ws, [
          rename_d(ws),
          %{"textDocument" => %{"uri" => uri(ws, "e/sub/x.c")}, "edits" => [edit(0, 0, 4, "PWN")]}
        ])

      assert {:error, message, _receipt} = result
      assert message =~ "symlink"
      assert File.read!(Path.join(out, "x.c")) == "keep\n"
    end

    test "rename then text edit of a moved file symlink", %{ws: ws, outside: out} do
      result =
        run(ws, [
          rename_d(ws),
          %{"textDocument" => %{"uri" => uri(ws, "e/file.c")}, "edits" => [edit(0, 0, 0, "x")]}
        ])

      assert {:error, message, _receipt} = result
      assert message =~ "symlink"
      assert File.read!(Path.join(out, "secret.c")) == "secret\n"
      assert File.read_link!(Path.join(ws, "e/file.c")) == Path.join(out, "secret.c")
    end

    test "rename then create or delete below a moved symlink", %{ws: ws, outside: out} do
      for change <- [
            %{"kind" => "create", "uri" => uri(ws, "e/sub/new.c")},
            %{"kind" => "delete", "uri" => uri(ws, "e/sub/secret.c")},
            %{
              "kind" => "rename",
              "oldUri" => uri(ws, "e/sub/secret.c"),
              "newUri" => uri(ws, "s.c")
            }
          ] do
        assert {:error, message, _receipt} = run(ws, [rename_d(ws), change])
        assert message =~ "symlink"
        assert File.read!(Path.join(out, "secret.c")) == "secret\n"
        refute File.exists?(Path.join(out, "new.c"))
        refute File.exists?(Path.join(ws, "s.c"))
        File.rename!(Path.join(ws, "e"), Path.join(ws, "d"))
      end
    end

    test "delete then rename a symlink-holding directory into its place", %{ws: ws, outside: out} do
      File.mkdir_p!(Path.join(ws, "e/sub"))
      File.write!(Path.join(ws, "e/sub/secret.c"), "inside\n")

      result =
        run(ws, [
          %{"kind" => "delete", "uri" => uri(ws, "e"), "options" => %{"recursive" => true}},
          rename_d(ws),
          %{
            "textDocument" => %{"uri" => uri(ws, "e/sub/secret.c")},
            "edits" => [edit(0, 0, 6, "PWN")]
          }
        ])

      assert {:error, message, _receipt} = result
      assert message =~ "symlink"
      assert File.read!(Path.join(out, "secret.c")) == "secret\n"
    end

    test "refuses targets outside the workspace before any write", %{ws: ws, outside: out} do
      File.write!(Path.join(ws, "in.c"), "in\n")
      File.mkdir_p!(Path.join(out, "tree"))
      File.write!(Path.join(out, "tree/t.c"), "t\n")
      ext = &Text.path_to_uri(Path.join(out, &1))
      first = %{"kind" => "create", "uri" => uri(ws, "first.c")}

      for change <- [
            %{"textDocument" => %{"uri" => ext.("secret.c")}, "edits" => [edit(0, 0, 6, "PWN")]},
            %{"kind" => "create", "uri" => ext.("new.c")},
            %{"kind" => "create", "uri" => ext.("secret.c"), "options" => %{"overwrite" => true}},
            %{"kind" => "delete", "uri" => ext.("secret.c")},
            %{"kind" => "delete", "uri" => ext.("tree"), "options" => %{"recursive" => true}},
            %{"kind" => "rename", "oldUri" => ext.("secret.c"), "newUri" => uri(ws, "s.c")},
            %{"kind" => "rename", "oldUri" => uri(ws, "in.c"), "newUri" => ext.("in.c")},
            %{
              "kind" => "rename",
              "oldUri" => uri(ws, "in.c"),
              "newUri" => ext.("secret.c"),
              "options" => %{"overwrite" => true}
            }
          ] do
        assert {:error, message} = run(ws, [first, change])
        assert message =~ "outside the workspace"
        refute File.exists?(Path.join(ws, "first.c"))
        assert File.read!(Path.join(out, "secret.c")) == "secret\n"
        assert File.read!(Path.join(out, "tree/t.c")) == "t\n"
        assert File.read!(Path.join(ws, "in.c")) == "in\n"
        refute File.exists?(Path.join(out, "new.c"))
        refute File.exists?(Path.join(out, "in.c"))
        refute File.exists?(Path.join(ws, "s.c"))
      end
    end

    test "session confinement stays stricter than the workspace", %{ws: ws} do
      {:ok, ops} =
        WorkspaceEdit.plan(%{
          "documentChanges" => [%{"kind" => "create", "uri" => uri(ws, "x.c")}]
        })

      opts = [filesystem_checkpoints: false, confine_mutations_to: Path.join(ws, "d")]
      assert {:error, message} = WorkspaceEdit.apply(ops, ws, opts, nil, %{})
      assert message =~ "confined"
      refute File.exists?(Path.join(ws, "x.c"))
    end
  end
end
