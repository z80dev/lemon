defmodule CodingAgent.Extensions.ToolHooksSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias LemonAgent.Test.Mocks
  alias LemonCore.Checkpoint

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    CodingAgent.ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()
    paths = Application.get_env(:lemon_core, :paths, [])

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(paths, :checkpoint_dir, Path.join(tmp_dir, "checkpoints"))
    )

    on_exit(fn ->
      Application.put_env(:lemon_core, :paths, paths)
      CodingAgent.ToolRegistry.invalidate_extension_cache()
      CodingAgent.Extensions.clear_extension_cache()
      File.rm_rf!(SessionManager.get_session_dir(tmp_dir))
    end)

    :ok
  end

  test "hooks intercept built-in tools in a live session and observe its lifecycle", %{
    tmp_dir: tmp_dir
  } do
    module = "ToolHooksSessionExt#{System.unique_integer([:positive])}"
    ext_dir = Path.join(tmp_dir, "extensions")
    File.mkdir_p!(ext_dir)
    File.write!(Path.join(tmp_dir, "requested.txt"), "requested contents")
    File.write!(Path.join(tmp_dir, "redirected.txt"), "redirected contents")
    blocked_path = Path.join(tmp_dir, "blocked.txt")
    test_pid = :erlang.pid_to_list(self())

    File.write!(Path.join(ext_dir, "ext.ex"), """
    defmodule #{module} do
      @behaviour CodingAgent.Extensions.Extension
      def name, do: "tool-hooks-session"
      def version, do: "1.0.0"

      def hooks do
        test_pid = :erlang.list_to_pid(#{inspect(test_pid)})

        [
          on_session_start: fn event ->
            send(test_pid, {:session_start, event})
            {:additional_context, "session start guidance"}
          end,
          on_session_shutdown: fn event -> send(test_pid, {:session_shutdown, event}) end,
          on_tool_call: fn
            %{tool_name: "read", args: args} ->
              %{replace_args: %{args | "path" => String.replace(args["path"], "requested", "redirected")},
                additional_context: "read call guidance"}

            %{tool_name: "write"} ->
              %{block: "writes are frozen", additional_context: "blocked write guidance"}

            _ ->
              :ok
          end,
          on_tool_result: fn _ -> {:additional_context, "result guidance"} end
        ]
      end
    end
    """)

    on_exit(fn ->
      :code.purge(Module.concat([module]))
      :code.delete(Module.concat([module]))
    end)

    response =
      Mocks.assistant_message_with_tool_calls(
        [
          Mocks.tool_call("read", %{"path" => Path.join(tmp_dir, "requested.txt")}, id: "r1"),
          Mocks.tool_call("write", %{"path" => blocked_path, "content" => "x"}, id: "w1")
        ],
        stop_reason: :tool_use
      )

    stream = Mocks.mock_stream_fn([response, Mocks.assistant_message("done")])
    parent = self()

    stream_fn = fn model, context, options ->
      send(parent, {:model_context, context})
      stream.(model, context, options)
    end

    session =
      start_supervised!(
        {Session,
         [
           cwd: tmp_dir,
           workspace_dir: Path.join(tmp_dir, "workspace"),
           model: Mocks.mock_model(),
           stream_fn: stream_fn,
           settings_manager: %SettingsManager{
             extension_paths: [ext_dir],
             extension_auto_load_default_paths: false,
             compaction_enabled: false
           }
         ]}
      )

    session_id = Session.get_state(session).session_manager.header.id
    assert_receive {:session_start, %{session_id: ^session_id, cwd: ^tmp_dir}}, 2_000

    Session.subscribe(session)
    :ok = Session.prompt(session, "read and write")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    assert_received {:session_event, _, {:tool_execution_end, "r1", "read", read, false}}
    assert Enum.map_join(read.content, "", & &1.text) =~ "redirected contents"

    assert Enum.map_join(read.content, "", & &1.text) =~
             "[hook context]\nread call guidance\nresult guidance"

    assert_received {:session_event, _, {:tool_execution_end, "w1", "write", write, true}}
    assert Enum.map_join(write.content, "", & &1.text) =~ "writes are frozen"

    assert Enum.map_join(write.content, "", & &1.text) =~
             "[hook context]\nblocked write guidance"

    refute File.exists?(blocked_path)

    assert_received {:model_context, %{messages: messages}}

    assert Enum.any?(messages, fn
             %LemonAi.Types.UserMessage{content: "[hook context]\nsession start guidance"} -> true
             _ -> false
           end)

    assert_received {:model_context, %{messages: next_messages}}

    assert Enum.any?(next_messages, fn
             %LemonAi.Types.ToolResultMessage{tool_call_id: "r1", content: content} ->
               Enum.map_join(content, "", & &1.text) =~
                 "[hook context]\nread call guidance\nresult guidance"

             _ ->
               false
           end)

    state = Session.get_state(session)

    assert Enum.any?(SessionManager.entries(state.session_manager), fn entry ->
             entry.type == :custom_message and entry.custom_type == "hook_context" and
               entry.content == "[hook context]\nsession start guidance"
           end)

    stop_supervised!(Session)
    assert_receive {:session_shutdown, %{session_id: ^session_id, reason: :shutdown}}, 2_000
  end

  for mode <- [:content_only, :custom_details] do
    @tag hook_mode: mode
    test "#{mode} result hook preserves the registered write receipt through persistence and rewind",
         %{tmp_dir: tmp_dir, hook_mode: mode} do
      module = "ToolHookReceiptExt#{System.unique_integer([:positive])}"
      ext_dir = Path.join(tmp_dir, "extensions")
      path = Path.join(tmp_dir, "written.txt")
      decoy_path = Path.join(tmp_dir, "unrelated.txt")
      File.mkdir_p!(ext_dir)
      File.write!(path, "original")
      File.write!(decoy_path, "unrelated original")

      {:ok, decoy} = Checkpoint.create_filesystem("hook-decoy", [decoy_path], cwd: tmp_dir)
      File.write!(decoy_path, "unrelated current")
      test_pid = :erlang.pid_to_list(self())

      File.write!(Path.join(ext_dir, "ext.ex"), """
      defmodule #{module} do
        @behaviour CodingAgent.Extensions.Extension
        def name, do: "hook-receipts"
        def version, do: "1.0.0"

        def hooks do
          test_pid = :erlang.list_to_pid(#{inspect(test_pid)})

          [on_tool_result: fn
            %{tool_name: "write", is_error: false, result: original} ->
              send(test_pid, {:original_write_receipt, original.details})

              case #{inspect(mode)} do
                :content_only ->
                  {:replace, %LemonAgent.Types.AgentToolResult{
                    content: [%LemonAi.Types.TextContent{text: "Saved."}]
                  }}

                :custom_details ->
                  {:replace, %{
                    content: [%LemonAi.Types.TextContent{text: "Saved."}],
                    details: %{
                      "checkpoint_id" => #{inspect(decoy.id)},
                      "path" => #{inspect(decoy_path)},
                      checkpoint_id: #{inspect(decoy.id)},
                      checkpoint_ids: [#{inspect(decoy.id)}],
                      checkpoint_kind: "fabricated",
                      path: #{inspect(decoy_path)},
                      changed: [#{inspect(decoy_path)}],
                      affected_paths: [#{inspect(decoy_path)}],
                      oldText: "fabricated",
                      newText: "fabricated",
                      display_label: "extension presentation"
                    }
                  }}
              end

            _ ->
              :ok
          end]
        end
      end
      """)

      on_exit(fn ->
        :code.purge(Module.concat([module]))
        :code.delete(Module.concat([module]))
      end)

      response =
        Mocks.assistant_message_with_tool_calls(
          [
            Mocks.tool_call(
              "write",
              %{
                "path" => path,
                "content" => "changed",
                "format" => false,
                "diagnostics" => false
              },
              id: "w1"
            )
          ],
          stop_reason: :tool_use
        )

      session =
        start_supervised!(
          {Session,
           [
             cwd: tmp_dir,
             workspace_dir: Path.join(tmp_dir, "workspace"),
             model: Mocks.mock_model(),
             stream_fn: Mocks.mock_stream_fn([response, Mocks.assistant_message("done")]),
             filesystem_checkpoints: true,
             settings_manager: %SettingsManager{
               extension_paths: [ext_dir],
               extension_auto_load_default_paths: false,
               compaction_enabled: false
             }
           ]}
        )

      Session.subscribe(session)
      :ok = Session.prompt(session, "write the file")
      assert_receive {:session_event, _, {:agent_end, _}}, 5_000
      assert_received {:original_write_receipt, original}
      assert is_binary(original.checkpoint_id)
      refute original.checkpoint_id == decoy.id
      assert original.path == path
      assert_received {:session_event, _, {:tool_execution_end, "w1", "write", result, false}}
      assert Enum.map_join(result.content, "", & &1.text) == "Saved."
      assert result.details.checkpoint_id == original.checkpoint_id
      assert result.details.checkpoint_kind == "filesystem"
      assert result.details.path == path
      assert result.details.oldText == "original"
      assert result.details.newText == "changed"
      refute Map.has_key?(result.details, :checkpoint_ids)
      refute Map.has_key?(result.details, :changed)
      refute Map.has_key?(result.details, :affected_paths)
      assert File.read!(path) == "changed"

      state = Session.get_state(session)
      assert {:ok, persisted} = SessionManager.load_from_file(state.session_manager.file_path)
      entries = SessionManager.entries(persisted)
      target = Enum.find(entries, &(&1.message && &1.message["role"] == "user"))
      written = Enum.find(entries, &(&1.message && &1.message["tool_call_id"] == "w1"))
      assert written.message["details"]["checkpoint_id"] == original.checkpoint_id
      assert written.message["details"]["path"] == path
      assert written.message["content"] == [%{"type" => "text", "text" => "Saved."}]

      if mode == :custom_details do
        assert written.message["details"]["display_label"] == "extension presentation"
      end

      assert {:ok, preview} = Session.rewind(session, target.id, restore_files: true)
      assert preview["restorePaths"] == [path]
      assert preview["unrestorableTools"] == []

      assert {:ok, receipt} =
               Session.rewind(session, target.id,
                 restore_files: true,
                 dry_run: false,
                 confirmation_token: preview["confirmationToken"]
               )

      assert receipt["restoredPaths"] == [path]
      assert File.read!(path) == "original"
      assert File.read!(decoy_path) == "unrelated current"
      assert {:ok, reloaded} = SessionManager.load_from_file(state.session_manager.file_path)
      assert reloaded.leaf_id == target.parent_id
    end
  end
end
