defmodule CodingAgent.SessionRewindTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.Rewind
  alias CodingAgent.SessionManager
  alias CodingAgent.Tools.Lsp.Text
  alias LemonCore.Checkpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "session-rewind-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir = Text.realpath(dir)
    paths = Application.get_env(:lemon_core, :paths, [])

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(paths, :checkpoint_dir, Path.join(dir, "checkpoints"))
    )

    session = SessionManager.new(dir) |> SessionManager.persist(Path.join(dir, "session.jsonl"))

    on_exit(fn ->
      Application.put_env(:lemon_core, :paths, paths)
      LemonCore.Store.delete(:session_rewinds, session.header.id)
      File.rm_rf!(dir)
    end)

    %{dir: dir, session: session}
  end

  test "rewind drops selected prompt and suffix from active context but retains a navigable branch",
       %{session: session} do
    base = user(session, "keep this decision")
    target = user(base, "replace this prompt")
    full = assistant(target, "abandoned answer")
    assert {:ok, preview, ^full} = Rewind.run(full, target.leaf_id)
    assert preview["prompt"] == "replace this prompt"
    assert preview["discardedMessages"] == 2
    assert SessionManager.get_branch(full) |> length() == 3

    assert {:ok, result, rewound} =
             Rewind.run(full, target.leaf_id,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert result["leafId"] == base.leaf_id

    assert SessionManager.build_session_context(rewound).messages == [
             %{"role" => "user", "content" => "keep this decision"}
           ]

    branched = user(rewound, "replacement prompt")
    assert length(Rewind.tree(branched)["branches"]) == 2
    old = Enum.find(Rewind.tree(branched)["entries"], &(&1["id"] == target.leaf_id))
    refute old["isActive"]
    refute old["rewindable"]
    assert {:ok, restored} = SessionManager.load_from_file(full.file_path)
    assert restored.leaf_id == branched.leaf_id
    assert Enum.any?(SessionManager.entries(restored), &(&1.id == full.leaf_id))
  end

  test "persisted prompt replay metadata inspects original mixed and separate media", %{
    session: session
  } do
    image = %LemonAi.Types.ImageContent{
      data: Base.encode64("original image"),
      mime_type: "image/png"
    }

    for {message, unsafe} <- [
          {%{"role" => "user", "content" => "same text"}, false},
          {%{role: :user, content: [%LemonAi.Types.TextContent{text: "same text"}]}, false},
          {%LemonAi.Types.UserMessage{
             content: [%LemonAi.Types.TextContent{text: "same text"}, image]
           }, true},
          {%{"role" => "user", "content" => [%{"type" => "image", "data" => "bytes"}]}, true},
          {%{
             "role" => "user",
             "content" => [
               %{"type" => "text", "text" => "same text"},
               %{"type" => "future_media", "data" => "unknown"}
             ]
           }, true},
          {%{"role" => "user", "content" => "same text", "images" => [image]}, true},
          {%{role: :user, content: "same text", image: image}, true},
          {%{"role" => "user", "content" => %{"type" => "unknown"}}, true},
          {%{"role" => "user", "content" => [%{"type" => "text", "text" => 42}]}, true}
        ] do
      target = SessionManager.append_message(session, message)
      full = assistant(target, "failed turn")
      {:ok, resumed} = SessionManager.load_from_file(full.file_path)
      before = File.read!(full.file_path)
      assert {:ok, preview, ^resumed} = Rewind.run(resumed, target.leaf_id)
      assert preview["promptContainsNonText"] == unsafe
      assert File.read!(full.file_path) == before
      assert SessionManager.get_entry(resumed, target.leaf_id).message != nil
      changed = user(resumed, "later turn")

      assert {:error, :stale_confirmation} =
               Rewind.run(changed, target.leaf_id,
                 dry_run: false,
                 confirmation_token: preview["confirmationToken"]
               )
    end
  end

  test "restores each path to its earliest checkpoint and removes newly created files", %{
    dir: dir,
    session: session
  } do
    existing = Path.join(dir, "existing.txt")
    created = Path.join(dir, "created.txt")
    File.write!(existing, "original")
    target = user(session, "edit files")
    {:ok, first} = Checkpoint.create_filesystem(session.header.id, [existing, created], cwd: dir)
    File.write!(existing, "first edit")
    File.write!(created, "new file")
    after_first = tool_result(target, "write", first.id)
    {:ok, second} = Checkpoint.create_filesystem(session.header.id, [existing], cwd: dir)
    File.write!(existing, "second edit")
    full = tool_result(after_first, "edit", second.id)
    assert {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    assert Enum.sort(preview["restorePaths"]) == Enum.sort([existing, created])
    assert preview["unrestorableTools"] == []
    assert File.read!(existing) == "second edit"

    assert {:ok, result, rewound} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert File.read!(existing) == "original"
    refute File.exists?(created)
    assert length(result["restoredPaths"]) == 2
    assert SessionManager.build_session_context(rewound).messages == []
    assert {:ok, reloaded} = SessionManager.load_from_file(full.file_path)
    assert reloaded.leaf_id == nil
  end

  test "one LSP result restores every checkpoint in order", %{dir: dir, session: session} do
    existing = Path.join(dir, "existing.c")
    created = Path.join(dir, "created.c")
    File.write!(existing, "original")
    target = user(session, "apply refactor")
    {:ok, first} = Checkpoint.create_filesystem(session.header.id, [existing], cwd: dir)
    File.write!(existing, "first edit")
    {:ok, second} = Checkpoint.create_filesystem(session.header.id, [existing, created], cwd: dir)
    File.write!(existing, "second edit")
    File.write!(created, "new file")

    full =
      SessionManager.append_message(target, %{
        "role" => "tool_result",
        "tool_name" => "lsp",
        "tool_call_id" => "refactor",
        "content" => [%{"type" => "text", "text" => "applied"}],
        "details" => %{"checkpoint_id" => second.id, "checkpoint_ids" => [first.id, second.id]}
      })

    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    assert Enum.sort(preview["restorePaths"]) == Enum.sort([existing, created])
    assert preview["unrestorableTools"] == []

    assert {:ok, _, _} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert File.read!(existing) == "original"
    refute File.exists?(created)
  end

  test "confirmation refuses changed files and changed branches", %{dir: dir, session: session} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "original")
    target = user(session, "edit")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [path], cwd: dir)
    File.write!(path, "model edit")
    full = tool_result(target, "write", checkpoint.id)
    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    File.write!(path, "user edit after preview")

    assert {:error, :stale_confirmation} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert File.read!(path) == "user edit after preview"
    {:ok, preview, _} = Rewind.run(full, target.leaf_id)
    changed = user(full, "new turn")

    assert {:error, :stale_confirmation} =
             Rewind.run(changed, target.leaf_id,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )
  end

  test "missing checkpoints cannot silently claim filesystem restoration", %{session: session} do
    target = user(session, "edit without checkpoint")
    full = tool_result(target, "write", nil)
    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    assert preview["unrestorableTools"] == ["write"]

    assert {:error, :checkpoint_missing} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    {:ok, history_only, _} = Rewind.run(full, target.leaf_id)

    assert {:ok, _, _} =
             Rewind.run(full, target.leaf_id,
               dry_run: false,
               confirmation_token: history_only["confirmationToken"]
             )
  end

  test "partial restoration requires fresh explicit consent and leaves shell effects intact", %{
    session: session,
    dir: dir
  } do
    path = Path.join(dir, "tracked.txt")
    File.write!(path, "original")
    target = user(session, "edit and verify")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [path], cwd: dir)
    File.write!(path, "edited")
    edited = tool_result(target, "write", checkpoint.id)
    command = "printf shell-side-effect > shell.txt"
    {"", 0} = System.cmd("sh", ["-c", command], cd: dir)
    full = shell_call(edited, command)

    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    assert preview["unrestorableCommands"] == [command]
    assert preview["unrestorableCommandCount"] == 1
    assert preview["canAllowPartialRestore"]
    refute preview["allowPartialRestore"]

    assert {:error, :unrestorable_effects} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert File.read!(path) == "edited"

    assert {:error, :stale_confirmation} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               allow_partial_restore: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    {:ok, partial, _} =
      Rewind.run(full, target.leaf_id, restore_files: true, allow_partial_restore: true)

    assert {:ok, receipt, rewound} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               allow_partial_restore: true,
               dry_run: false,
               confirmation_token: partial["confirmationToken"]
             )

    assert receipt["partialRestore"]
    assert receipt["confirmationToken"] == partial["confirmationToken"]
    assert receipt["restoreFiles"] and receipt["allowPartialRestore"]
    assert receipt["unrestorableCommands"] == [command]
    assert receipt["restoredPaths"] == [path]
    assert File.read!(path) == "original"
    assert File.read!(Path.join(dir, "shell.txt")) == "shell-side-effect"
    assert rewound.leaf_id == target.by_id[target.leaf_id].parent_id
    assert length(SessionManager.entries(rewound)) == length(SessionManager.entries(full))
  end

  test "partial consent cannot bypass missing file checkpoints or unreviewable commands", %{
    session: session
  } do
    target = user(session, "unsafe partial restore")
    missing = tool_result(target, "write", nil)

    {:ok, preview, _} =
      Rewind.run(missing, target.leaf_id, restore_files: true, allow_partial_restore: true)

    refute preview["canAllowPartialRestore"]

    assert {:error, :checkpoint_missing} =
             Rewind.run(missing, target.leaf_id,
               restore_files: true,
               allow_partial_restore: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    long = shell_call(target, String.duplicate("x", 2049))

    {:ok, preview, _} =
      Rewind.run(long, target.leaf_id, restore_files: true, allow_partial_restore: true)

    refute preview["canAllowPartialRestore"]
    assert preview["unrestorableCommandCount"] == 1

    assert {:error, :partial_restore_unreviewable} =
             Rewind.run(long, target.leaf_id,
               restore_files: true,
               allow_partial_restore: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert {:error, :invalid_partial_restore} =
             Rewind.run(long, target.leaf_id, allow_partial_restore: true)

    secret = "sk-" <> String.duplicate("x", 40)
    redacted = shell_call(target, "API_KEY=#{secret} printf ok")
    {:ok, preview, _} = Rewind.run(redacted, target.leaf_id, restore_files: true)
    refute Enum.join(preview["unrestorableCommands"]) =~ secret
    assert preview["canAllowPartialRestore"]
  end

  test "AST search and previews stay read-only, but missing applied-rewrite checkpoints fail closed",
       %{
         session: session
       } do
    target = user(session, "Rewrite syntax")

    for {arguments, mutating?} <- [
          {%{"action" => "search"}, false},
          {%{"action" => "replace"}, false},
          {%{"action" => "replace", "dry_run" => true}, false},
          {%{"action" => "replace", "dry_run" => false}, true}
        ],
        outcome <- [:interrupted, :failed] do
      called =
        SessionManager.append_message(target, %{
          "role" => "assistant",
          "content" => [
            %{
              "type" => "tool_call",
              "id" => "ast",
              "name" => "ast_grep",
              "arguments" => arguments
            }
          ]
        })

      full =
        if outcome == :failed do
          SessionManager.append_message(called, %{
            "role" => "tool_result",
            "tool_name" => "ast_grep",
            "tool_call_id" => "ast",
            "is_error" => true,
            "content" => [%{"type" => "text", "text" => "replacement failed"}]
          })
        else
          called
        end

      {:ok, preview, _} =
        Rewind.run(full, target.leaf_id, restore_files: true, allow_partial_restore: true)

      if mutating? do
        assert preview["unrestorableTools"] == ["ast_grep"]
        refute preview["canAllowPartialRestore"]

        assert {:error, :checkpoint_missing} =
                 Rewind.run(full, target.leaf_id,
                   restore_files: true,
                   allow_partial_restore: true,
                   dry_run: false,
                   confirmation_token: preview["confirmationToken"]
                 )
      else
        assert preview["unrestorableTools"] == []
      end
    end
  end

  test "arbitrary code effects fail closed after success, failure or interruption", %{
    session: session,
    dir: dir
  } do
    path = Path.join(dir, "tracked.txt")
    File.write!(path, "original")
    target = user(session, "edit and execute")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [path], cwd: dir)
    File.write!(path, "edited")
    edited = tool_result(target, "write", checkpoint.id)

    for {name, arguments} <- [
          {"eval", %{"code" => "write_file()"}},
          {"debug", %{"action" => "evaluate", "expression" => "write_file()"}},
          {"debug", %{"action" => "launch"}},
          {"debug", %{"action" => "continue"}},
          {"debug", %{"action" => "custom_request"}},
          {"debug", %{"action" => "variables"}},
          {"debug", %{"action" => "unknown"}},
          {"debug", %{}}
        ],
        outcome <- [:success, :failed, :interrupted] do
      called = code_call(edited, name, arguments)

      full =
        if outcome == :interrupted do
          called
        else
          SessionManager.append_message(called, %{
            "role" => "tool_result",
            "tool_name" => name,
            "tool_call_id" => "code",
            "is_error" => outcome == :failed,
            "details" => Map.put(arguments, "checkpoint_id", checkpoint.id),
            "content" => []
          })
        end

      {:ok, preview, _} =
        Rewind.run(full, target.leaf_id, restore_files: true, allow_partial_restore: true)

      assert name in preview["unrestorableTools"]
      refute preview["canAllowPartialRestore"]

      assert {:error, :unrestorable_effects} =
               Rewind.run(full, target.leaf_id,
                 restore_files: true,
                 allow_partial_restore: true,
                 dry_run: false,
                 confirmation_token: preview["confirmationToken"]
               )

      assert File.read!(path) == "edited"
    end
  end

  test "precise debug inspection is not mistaken for execution", %{session: session} do
    target = user(session, "inspect")

    for action <- ~w(status sessions output threads stack_trace scopes) do
      called = code_call(target, "debug", %{"action" => action})
      {:ok, preview, _} = Rewind.run(called, target.leaf_id, restore_files: true)
      assert preview["unrestorableTools"] == []

      inspected =
        SessionManager.append_message(called, %{
          "role" => "tool_result",
          "tool_name" => "debug",
          "tool_call_id" => "code",
          "is_error" => true,
          "content" => []
        })

      {:ok, preview, _} = Rewind.run(inspected, target.leaf_id, restore_files: true)
      assert preview["unrestorableTools"] == []
    end

    # A result without persisted arguments must not infer inspection or purity.
    unknown = tool_result(target, "debug", nil)
    {:ok, preview, _} = Rewind.run(unknown, target.leaf_id, restore_files: true)
    assert preview["unrestorableTools"] == ["debug"]

    unidentified =
      SessionManager.append_message(target, %{
        "role" => "assistant",
        "content" => [%{"type" => "tool_call", "name" => "eval", "arguments" => %{}}]
      })

    {:ok, preview, _} = Rewind.run(unidentified, target.leaf_id, restore_files: true)
    assert preview["unrestorableTools"] == ["eval"]
  end

  test "error receipts reverse overlapping directory and file batches without losing resources",
       %{
         session: session,
         dir: dir
       } do
    root = Path.join(dir, "source")
    destination = Path.join(dir, "renamed")
    empty = Path.join(root, "empty")
    file = Path.join(root, "file")
    outside = Path.join(dir, "outside")
    File.mkdir_p!(empty)
    File.chmod!(empty, 0o750)
    File.chmod!(root, 0o751)
    File.write!(file, "original")
    File.chmod!(file, 0o640)
    File.write!(outside, "untouched")
    File.ln_s!(outside, Path.join(root, "link"))
    target = user(session, "edit then rename")
    {:ok, first} = Checkpoint.create_filesystem(session.header.id, [file], cwd: dir)
    File.write!(file, "intermediate")
    {:ok, second} = Checkpoint.create_filesystem(session.header.id, [root, destination], cwd: dir)
    File.rename!(root, destination)
    File.write!(Path.join(destination, "extra"), "created")
    File.chmod!(destination, 0o550)

    full =
      SessionManager.append_message(target, %{
        "role" => "tool_result",
        "tool_name" => "lsp",
        "tool_call_id" => "resource",
        "is_error" => true,
        "details" => %{"checkpoint_ids" => [first.id, second.id], "success" => false},
        "content" => []
      })

    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    assert preview["unrestorableTools"] == []

    assert {:ok, _, _} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    assert File.read!(file) == "original"
    assert File.dir?(empty)
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o751
    assert Bitwise.band(File.stat!(empty).mode, 0o777) == 0o750
    assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o640
    assert File.read_link!(Path.join(root, "link")) == outside
    assert File.read!(outside) == "untouched"
    refute File.exists?(destination)
  end

  test "directory deletion restores the full tree and nested changes invalidate consent", %{
    session: session,
    dir: dir
  } do
    root = Path.join(dir, "tree")
    File.mkdir_p!(Path.join(root, "empty"))
    path = Path.join(root, "file")
    File.write!(path, "original")
    target = user(session, "delete tree")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [root], cwd: dir)
    File.rm_rf!(root)
    full = tool_result(target, "lsp", checkpoint.id)
    {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    File.mkdir_p!(root)
    File.write!(path, "new user content")

    assert {:error, :stale_confirmation} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    {:ok, fresh, _} = Rewind.run(full, target.leaf_id, restore_files: true)
    File.write!(path, "changed nested content")

    assert {:error, :stale_confirmation} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: fresh["confirmationToken"]
             )

    {:ok, final, _} = Rewind.run(full, target.leaf_id, restore_files: true)

    assert {:ok, _, _} =
             Rewind.run(full, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: final["confirmationToken"]
             )

    assert File.read!(path) == "original"
    assert File.dir?(Path.join(root, "empty"))
  end

  test "tree capture bounds refuse before recording and symlinks never capture their targets", %{
    session: session,
    dir: dir
  } do
    root = Path.join(dir, "bounded")
    File.mkdir_p!(Path.join(root, "empty"))
    File.write!(Path.join(root, "file"), "12345")

    for limits <- [
          [max_bytes: 4],
          [max_total_bytes: 4],
          [max_entries: 2],
          [max_depth: 0]
        ] do
      assert {:error, _} =
               Checkpoint.create_filesystem(session.header.id, [root], [cwd: dir] ++ limits)
    end

    fifo = Path.join(root, "pipe")
    assert {"", 0} = System.cmd("mkfifo", [fifo], stderr_to_stdout: true)

    assert {:error, {:unsupported_file_type, ^fifo, _}} =
             Checkpoint.create_filesystem(session.header.id, [root], cwd: dir)

    File.rm!(fifo)
    assert Checkpoint.list(session.header.id) == []
    outside = Path.join(dir, "outside")
    File.write!(outside, String.duplicate("x", 100))
    link = Path.join(dir, "link")
    File.ln_s!(outside, link)

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session.header.id, [link], cwd: dir, max_bytes: 0)

    File.rm!(link)
    File.write!(link, "replacement")
    assert {:ok, _} = Checkpoint.restore_filesystem(checkpoint.id)
    assert File.read_link!(link) == outside
    assert File.read!(outside) == String.duplicate("x", 100)
  end

  test "restore validates all selected trees and refuses symlink parents before deletion", %{
    session: session,
    dir: dir
  } do
    path = Path.join(dir, "kept")
    root = Path.join(dir, "tree")
    File.write!(path, "keep current")
    File.mkdir_p!(root)
    {:ok, captured} = Checkpoint.create_filesystem(session.header.id, [path, root], cwd: dir)
    [file_snapshot, tree_snapshot] = captured.state.filesystem.files
    corrupt = %{tree_snapshot | entries: [%{name: "../escape", snapshot: file_snapshot}]}

    {:ok, invalid} =
      Checkpoint.create(session.header.id,
        metadata: %{kind: "filesystem"},
        state: %{filesystem: %{cwd: dir, files: [file_snapshot, corrupt]}}
      )

    File.write!(path, "new content")
    assert {:error, _} = Checkpoint.restore_filesystem(invalid.id)
    assert File.read!(path) == "new content"
    assert File.dir?(root)
    nested = Path.join(root, "file")
    File.write!(nested, "original")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [nested], cwd: dir)
    other = Path.join(dir, "other")
    File.mkdir_p!(other)
    File.write!(Path.join(other, "file"), "external content")
    File.rm_rf!(root)
    File.ln_s!(other, root)
    assert {:error, _} = Checkpoint.restore_filesystem(checkpoint.id)
    assert File.read!(Path.join(other, "file")) == "external content"
    assert {:error, _} = Checkpoint.create_filesystem(session.header.id, [nested], cwd: dir)
  end

  test "persisted bridge and direct effects have identical refusal and redacted shell review", %{
    session: session,
    dir: dir
  } do
    tracked = Path.join(dir, "tracked")
    File.write!(tracked, "original")
    target = user(session, "write and execute")
    {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [tracked], cwd: dir)
    File.write!(tracked, "edited")
    base = tool_result(target, "write", checkpoint.id)
    secret = "sk-" <> String.duplicate("x", 40)

    for {name, arguments, refusal} <- [
          {"bash", %{"command" => "API_KEY=#{secret} printf ok"}, :unrestorable_effects},
          {"eval", %{"code" => "write_file()"}, :unrestorable_effects},
          {"debug", %{"action" => "evaluate"}, :unrestorable_effects},
          {"debug", %{"action" => "unknown"}, :unrestorable_effects},
          {"write", %{"path" => "untracked", "content" => "new"}, :checkpoint_missing}
        ],
        outcome <- [:success, :failed, :interrupted] do
      reviews =
        for bridged <- [false, true] do
          full = persisted_invocation(base, name, arguments, bridged, outcome)
          {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
          assert preview["unrestorableTools"] == [name]
          assert preview["restorePaths"] == [tracked]
          refute Enum.join(preview["unrestorableCommands"]) =~ secret

          assert {:error, ^refusal} =
                   Rewind.run(full, target.leaf_id,
                     restore_files: true,
                     dry_run: false,
                     confirmation_token: preview["confirmationToken"]
                   )

          assert File.read!(tracked) == "edited"

          Map.take(preview, [
            "unrestorableTools",
            "restorePaths",
            "unrestorableCommands",
            "unrestorableCommandCount",
            "canAllowPartialRestore"
          ])
        end

      assert Enum.at(reviews, 0) == Enum.at(reviews, 1)
    end
  end

  test "persisted bridge write errors keep recoverable receipts and inspection matches its outer ID",
       %{
         session: session,
         dir: dir
       } do
    path = Path.join(dir, "file")

    for bridged <- [false, true], outcome <- [:success, :failed] do
      File.write!(path, "original")
      target = user(session, "write")
      {:ok, checkpoint} = Checkpoint.create_filesystem(session.header.id, [path], cwd: dir)
      File.write!(path, "edited before result")

      full =
        persisted_invocation(
          target,
          "write",
          %{"path" => path, "content" => "edit"},
          bridged,
          outcome,
          %{"checkpoint_ids" => [checkpoint.id]}
        )

      {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
      assert preview["unrestorableTools"] == []

      assert {:ok, _, _} =
               Rewind.run(full, target.leaf_id,
                 restore_files: true,
                 dry_run: false,
                 confirmation_token: preview["confirmationToken"]
               )

      assert File.read!(path) == "original"
    end

    target = user(session, "inspect")

    for bridged <- [false, true], outcome <- [:success, :failed, :interrupted] do
      full = persisted_invocation(target, "debug", %{"action" => "status"}, bridged, outcome)
      {:ok, preview, _} = Rewind.run(full, target.leaf_id, restore_files: true)
      assert preview["unrestorableTools"] == []
    end
  end

  test "unidentified persisted bridges fail closed and missing shell arguments cannot get partial consent",
       %{
         session: session
       } do
    target = user(session, "unknown invocation")

    orphan =
      SessionManager.append_message(target, %{
        "role" => "tool_result",
        "tool_name" => "tool_invoke",
        "tool_call_id" => "missing",
        "is_error" => true,
        "content" => [],
        "details" => %{"name" => "debug", "action" => "status"}
      })

    {:ok, reloaded} = SessionManager.load_from_file(orphan.file_path)
    {:ok, preview, _} = Rewind.run(reloaded, target.leaf_id, restore_files: true)
    assert preview["unrestorableTools"] == ["tool_invoke"]

    assert {:error, :checkpoint_missing} =
             Rewind.run(reloaded, target.leaf_id,
               restore_files: true,
               dry_run: false,
               confirmation_token: preview["confirmationToken"]
             )

    for outcome <- [:success, :failed, :interrupted] do
      full = persisted_invocation(target, "bash", %{}, true, outcome)

      {:ok, preview, _} =
        Rewind.run(full, target.leaf_id, restore_files: true, allow_partial_restore: true)

      assert preview["unrestorableTools"] == ["bash"]
      assert preview["unrestorableCommandCount"] == 1
      refute preview["canAllowPartialRestore"]

      assert {:error, :partial_restore_unreviewable} =
               Rewind.run(full, target.leaf_id,
                 restore_files: true,
                 allow_partial_restore: true,
                 dry_run: false,
                 confirmation_token: preview["confirmationToken"]
               )
    end
  end

  defp persisted_invocation(session, name, arguments, bridged, outcome, details \\ %{}) do
    outer_name = if bridged, do: "tool_invoke", else: name
    params = if bridged, do: %{"name" => name, "args" => arguments}, else: arguments
    id = "invocation-#{System.unique_integer([:positive])}"

    called =
      SessionManager.append_message(session, %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_call",
            "id" => id,
            "name" => outer_name,
            "arguments" => params
          }
        ]
      })

    full =
      if outcome == :interrupted do
        called
      else
        SessionManager.append_message(called, %{
          "role" => "tool_result",
          "tool_name" => outer_name,
          "tool_call_id" => id,
          "is_error" => outcome == :failed,
          "content" => [],
          "details" => details
        })
      end

    {:ok, reloaded} = SessionManager.load_from_file(full.file_path)
    reloaded
  end

  defp code_call(session, name, arguments) do
    SessionManager.append_message(session, %{
      "role" => "assistant",
      "content" => [
        %{
          "type" => "tool_call",
          "id" => "code",
          "name" => name,
          "arguments" => arguments
        }
      ]
    })
  end

  defp shell_call(session, command) do
    id = "shell-#{System.unique_integer([:positive])}"

    session
    |> SessionManager.append_message(%{
      "role" => "assistant",
      "content" => [
        %{
          "type" => "tool_call",
          "id" => id,
          "name" => "bash",
          "arguments" => %{"command" => command}
        }
      ]
    })
    |> SessionManager.append_message(%{
      "role" => "tool_result",
      "tool_name" => "bash",
      "tool_call_id" => id,
      "content" => [%{"type" => "text", "text" => "complete"}],
      "details" => %{"exit_code" => 0},
      "is_error" => false
    })
  end

  test "tree pages remain stable and do not expose hidden thought text", %{session: session} do
    first = user(session, "visible prompt")

    full =
      SessionManager.append_message(first, %{
        "role" => "assistant",
        "content" => [
          %{"type" => "thinking", "thinking" => "private thought"},
          %{"type" => "text", "text" => "visible answer"}
        ]
      })

    page = Rewind.tree(full, limit: 1, offset: 1)
    assert page["totalEntries"] == 2
    refute page["hasMore"]
    assert [%{"text" => "visible answer"}] = page["entries"]
    assert {:error, :not_user_message} = Rewind.run(full, full.leaf_id)
  end

  defp user(session, text),
    do: SessionManager.append_message(session, %{"role" => "user", "content" => text})

  defp assistant(session, text),
    do:
      SessionManager.append_message(session, %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}]
      })

  defp tool_result(session, name, checkpoint_id) do
    SessionManager.append_message(session, %{
      "role" => "tool_result",
      "tool_name" => name,
      "tool_call_id" => "call-#{System.unique_integer([:positive])}",
      "content" => [%{"type" => "text", "text" => "written"}],
      "details" => if(checkpoint_id, do: %{"checkpoint_id" => checkpoint_id}, else: %{})
    })
  end
end
