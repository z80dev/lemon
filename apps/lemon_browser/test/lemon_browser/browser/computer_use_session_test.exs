defmodule LemonBrowser.ComputerUseSessionTest do
  use ExUnit.Case, async: false

  alias LemonBrowser.ComputerUseSession

  setup do
    test_pid = self()

    runner = fn tool, args, timeout ->
      send(test_pid, {:cua_call, tool, args, timeout})

      case tool do
        "list_windows" ->
          {:ok,
           %{
             "structuredContent" => %{
               "windows" => [
                 %{
                   "app_name" => "Notes",
                   "pid" => 101,
                   "window_id" => 201,
                   "title" => "Scratchpad",
                   "z_index" => 9,
                   "is_on_screen" => true
                 },
                 %{
                   "app_name" => "Hidden",
                   "pid" => 102,
                   "window_id" => 202,
                   "title" => "Invisible",
                   "z_index" => 99,
                   "is_on_screen" => false
                 }
               ]
             }
           }}

        "get_window_state" ->
          {:ok,
           %{
             "content" => [
               %{"type" => "text", "text" => "[1] button Save"},
               %{
                 "type" => "image",
                 "data" => Base.encode64(<<1, 2, 3>>),
                 "mimeType" => "image/png"
               }
             ],
             "structuredContent" => %{
               "elements" => [%{"index" => 1, "role" => "button", "label" => "Save"}],
               "verified" => true,
               "effect" => "captured"
             }
           }}

        "click" ->
          {:ok,
           %{
             "structuredContent" => %{
               "verified" => true,
               "effect" => "activated",
               "path" => "ax",
               "next_step" => "capture"
             }
           }}

        "type_text" ->
          {:ok, %{"structuredContent" => %{"verified" => false, "effect" => "unknown"}}}

        "bring_to_front" ->
          {:ok, %{"structuredContent" => %{"verified" => true, "effect" => "focused"}}}

        other ->
          {:ok, %{"structuredContent" => %{"verified" => true, "operation" => other}}}
      end
    end

    on_exit(&stop_sessions/0)

    {:ok,
     opts: [
       session_id: "cua-secret-#{System.unique_integer([:positive])}",
       run_id: "run-secret",
       computer_use_runner: runner
     ]}
  end

  test "requires exact Lemon session identity before any driver call", %{opts: opts} do
    assert {:error, {:missing_computer_use_binding, :session_id}} =
             ComputerUseSession.request(
               %{"action" => "list_apps"},
               1_000,
               Keyword.delete(opts, :session_id)
             )

    refute_received {:cua_call, _, _, _}
  end

  test "captures a visible app window and binds later element input to that exact target", %{
    opts: opts
  } do
    assert {:ok, capture} =
             ComputerUseSession.request(
               %{"action" => "capture", "mode" => "som", "app" => "Notes"},
               1_000,
               opts
             )

    assert capture["target"] == %{
             "kind" => "window",
             "pid" => 101,
             "windowId" => 201,
             "app" => "Notes",
             "title" => "Scratchpad"
           }

    assert capture["verdict"]["verified"]
    assert [%{"type" => "text"}, %{"type" => "image"}] = capture["content"]

    assert_received {:cua_call, "list_windows", list_args, 1_000}
    assert list_args["session"] =~ "lemon-"
    refute list_args["session"] =~ Keyword.fetch!(opts, :session_id)

    assert_received {:cua_call, "get_window_state", capture_args, 1_000}
    assert capture_args["pid"] == 101
    assert capture_args["window_id"] == 201
    assert capture_args["mode"] == "som"

    assert {:ok, clicked} =
             ComputerUseSession.request(
               %{"action" => "click", "element" => 1},
               1_000,
               opts
             )

    assert clicked["deliveryMode"] == "background"
    assert clicked["verdict"]["effect"] == "activated"
    assert clicked["verdict"]["nextStep"] == "capture"

    assert_received {:cua_call, "click", click_args, 1_000}
    assert click_args["pid"] == 101
    assert click_args["window_id"] == 201
    assert click_args["element_index"] == 1
    refute Map.has_key?(click_args, "delivery_mode")
  end

  test "capture_after returns fresh state without replaying the action", %{opts: opts} do
    assert {:ok, _} =
             ComputerUseSession.request(
               %{"action" => "capture", "pid" => 101, "window_id" => 201},
               1_000,
               opts
             )

    assert {:ok, result} =
             ComputerUseSession.request(
               %{
                 "action" => "click",
                 "coordinate" => [30, 40],
                 "capture_after" => true
               },
               1_000,
               opts
             )

    assert is_map(result["capture"])
    assert_received {:cua_call, "click", %{"x" => 30, "y" => 40}, 1_000}
    assert_received {:cua_call, "get_window_state", _, 1_000}
    refute_received {:cua_call, "click", _, _}
  end

  test "foreground focus is explicit and invalid escalation fails before input", %{opts: opts} do
    assert {:ok, _} =
             ComputerUseSession.request(
               %{"action" => "capture", "pid" => 101, "window_id" => 201},
               1_000,
               opts
             )

    assert {:error, reason} =
             ComputerUseSession.request(
               %{
                 "action" => "click",
                 "element" => 1,
                 "bring_to_front" => true,
                 "delivery_mode" => "background"
               },
               1_000,
               opts
             )

    assert reason =~ "foreground"
    refute_received {:cua_call, "click", _, _}

    assert {:ok, focused} =
             ComputerUseSession.request(
               %{"action" => "focus_app", "app" => "Notes", "raise_window" => true},
               1_000,
               opts
             )

    assert focused["raised"]
    assert_received {:cua_call, "bring_to_front", %{"pid" => 101, "window_id" => 201}, 1_000}
  end

  test "type content is sent only to the driver and never echoed by the adapter", %{opts: opts} do
    assert {:ok, _} =
             ComputerUseSession.request(
               %{"action" => "capture", "pid" => 101, "window_id" => 201},
               1_000,
               opts
             )

    secret = "do-not-echo-this-text"

    assert {:ok, result} =
             ComputerUseSession.request(
               %{"action" => "type", "text" => secret},
               1_000,
               opts
             )

    assert_received {:cua_call, "type_text", type_args, 1_000}
    assert type_args["text"] == secret
    refute inspect(result) =~ secret
    assert result["verdict"]["verified"] == false
  end

  test "driver errors are returned once with no automatic replay", %{opts: opts} do
    parent = self()

    failing_runner = fn tool, args, timeout ->
      send(parent, {:failing_call, tool, args, timeout})

      if tool == "get_window_state" do
        {:ok, %{"structuredContent" => %{}}}
      else
        {:error, {:timeout_outcome_unknown, tool}}
      end
    end

    failure_opts =
      opts
      |> Keyword.put(:session_id, "failing-session")
      |> Keyword.put(:computer_use_runner, failing_runner)

    assert {:ok, _} =
             ComputerUseSession.request(
               %{"action" => "capture", "pid" => 101, "window_id" => 201},
               1_000,
               failure_opts
             )

    assert {:error, {:timeout_outcome_unknown, "click"}} =
             ComputerUseSession.request(
               %{"action" => "click", "element" => 1},
               1_000,
               failure_opts
             )

    assert_received {:failing_call, "click", _, 1_000}
    refute_received {:failing_call, "click", _, _}
  end

  test "status hashes session identity and does not expose the driver session label", %{
    opts: opts
  } do
    assert {:ok, _} =
             ComputerUseSession.request(
               %{"action" => "capture", "pid" => 101, "window_id" => 201},
               1_000,
               opts
             )

    [status] = ComputerUseSession.status()
    rendered = inspect(status)

    assert status.request_count == 1
    refute rendered =~ Keyword.fetch!(opts, :session_id)
    refute rendered =~ "run-secret"
    refute rendered =~ "lemon-"
  end

  defp stop_sessions do
    LemonBrowser.ComputerUseSessionRegistry
    |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.each(fn {_scope, pid} ->
      if is_pid(pid) and Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)
  end
end
