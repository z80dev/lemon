defmodule CodingAgent.SessionRewindTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session.Rewind
  alias CodingAgent.SessionManager
  alias LemonCore.Checkpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "session-rewind-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
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
