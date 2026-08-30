defmodule CodingAgent.Tools.ComputerUseTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ToolPolicy, Tools}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.ImageContent

  setup do
    tmp = Path.join(System.tmp_dir!(), "lemon_computer_use_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      stop_sessions()
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "is registered with the full Hermes-compatible action vocabulary and dangerous policy", %{
    tmp: tmp
  } do
    tool = Tools.get_tool("computer_use", tmp, session_id: "schema-session")
    actions = tool.parameters["properties"]["action"]["enum"]

    assert actions ==
             ~w(capture click double_click right_click middle_click drag scroll type key set_value wait list_apps list_windows focus_app)

    refute ToolPolicy.allowed?(ToolPolicy.from_profile(:safe_mode), "computer_use")
    refute ToolPolicy.allowed?(ToolPolicy.from_profile(:no_external), "computer_use")
  end

  test "capture writes a managed screenshot artifact and emits an image block", %{tmp: tmp} do
    parent = self()

    runner = fn tool, args, timeout ->
      send(parent, {:runner, tool, args, timeout})

      {:ok,
       %{
         "content" => [
           %{"type" => "text", "text" => "[1] AXButton Save"},
           %{"type" => "image", "data" => Base.encode64(<<1, 2, 3>>), "mimeType" => "image/png"}
         ],
         "structuredContent" => %{"verified" => true, "effect" => "captured"}
       }}
    end

    tool =
      Tools.get_tool("computer_use", tmp,
        session_id: "capture-session",
        computer_use_runner: runner,
        computer_use_artifacts_dir: Path.join(tmp, "artifacts")
      )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "call-1",
               %{
                 "action" => "capture",
                 "mode" => "som",
                 "pid" => 101,
                 "window_id" => 201,
                 "timeoutMs" => 500
               },
               nil,
               nil
             )

    assert result.trust == :untrusted
    assert [%{text: _}, %ImageContent{data: encoded, mime_type: "image/png"}] = result.content
    assert Base.decode64!(encoded) == <<1, 2, 3>>
    assert File.read!(result.details["screenshot_path"]) == <<1, 2, 3>>
    assert result.details["screenshot_bytes"] == 3
    refute inspect(result.details) =~ encoded
    assert result.details["verdict"]["verified"]

    assert_received {:runner, "get_window_state", args, 500}
    assert args["pid"] == 101
    assert args["window_id"] == 201
  end

  test "AX-only capture does not emit image content", %{tmp: tmp} do
    runner = fn _tool, _args, _timeout ->
      {:ok,
       %{
         "content" => [%{"type" => "text", "text" => "AXButton Save"}],
         "structuredContent" => %{"elements" => [%{"index" => 1}]}
       }}
    end

    tool =
      Tools.get_tool("computer_use", tmp,
        session_id: "ax-session",
        computer_use_runner: runner
      )

    result =
      tool.execute.(
        "call-1",
        %{"action" => "capture", "mode" => "ax", "pid" => 1, "window_id" => 2},
        nil,
        nil
      )

    assert %AgentToolResult{} = result
    assert length(result.content) == 1
    assert result.trust == :untrusted
  end

  test "progress updates expose no typed text", %{tmp: tmp} do
    parent = self()

    runner = fn tool, _args, _timeout ->
      case tool do
        "get_window_state" -> {:ok, %{"structuredContent" => %{}}}
        "type_text" -> {:ok, %{"structuredContent" => %{"verified" => true}}}
      end
    end

    updates = fn update -> send(parent, {:update, update}) end

    tool =
      Tools.get_tool("computer_use", tmp,
        session_id: "progress-session",
        computer_use_runner: runner
      )

    assert %AgentToolResult{} =
             tool.execute.(
               "capture",
               %{"action" => "capture", "pid" => 1, "window_id" => 2},
               nil,
               updates
             )

    assert %AgentToolResult{} =
             result =
             tool.execute.(
               "type",
               %{"action" => "type", "text" => "typed-progress-secret"},
               nil,
               updates
             )

    refute inspect(result) =~ "typed-progress-secret"

    updates = drain_updates([])
    refute inspect(updates) =~ "typed-progress-secret"
  end

  defp drain_updates(acc) do
    receive do
      {:update, update} -> drain_updates([update | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp stop_sessions do
    LemonBrowser.ComputerUseSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_scope, pid} ->
      if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)
  end
end
