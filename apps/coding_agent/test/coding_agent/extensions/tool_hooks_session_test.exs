defmodule CodingAgent.Extensions.ToolHooksSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias LemonAgent.Test.Mocks

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    CodingAgent.ToolRegistry.invalidate_extension_cache()
    CodingAgent.Extensions.clear_extension_cache()
    on_exit(fn -> File.rm_rf!(SessionManager.get_session_dir(tmp_dir)) end)
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
          on_session_start: fn event -> send(test_pid, {:session_start, event}) end,
          on_session_shutdown: fn event -> send(test_pid, {:session_shutdown, event}) end,
          on_tool_call: fn
            %{tool_name: "read", args: args} ->
              {:replace_args, %{args | "path" => String.replace(args["path"], "requested", "redirected")}}

            %{tool_name: "write"} ->
              {:block, "writes are frozen"}

            _ ->
              :ok
          end
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

    session =
      start_supervised!(
        {Session,
         [
           cwd: tmp_dir,
           workspace_dir: Path.join(tmp_dir, "workspace"),
           model: Mocks.mock_model(),
           stream_fn: Mocks.mock_stream_fn([response, Mocks.assistant_message("done")]),
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

    assert_received {:session_event, _, {:tool_execution_end, "w1", "write", write, true}}
    assert Enum.map_join(write.content, "", & &1.text) =~ "writes are frozen"
    refute File.exists?(blocked_path)

    stop_supervised!(Session)
    assert_receive {:session_shutdown, %{session_id: ^session_id, reason: :shutdown}}, 2_000
  end
end
