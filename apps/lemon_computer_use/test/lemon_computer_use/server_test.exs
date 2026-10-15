defmodule LemonComputerUse.ServerTest do
  use ExUnit.Case, async: false

  import LemonComputerUse.TestSupport

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.{ImageContent, TextContent}
  alias LemonComputerUse.{ContextContributor, Server}
  alias LemonComputerUse.Tools.{Js, JsReset}
  alias LemonCore.Events.RunCompleted

  setup context do
    start_fake_server(context)
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [session_id: "sess-1", run_id: "run-#{System.unique_integer([:positive])}"],
      extra
    )
  end

  defp run(tool, params, signal \\ nil), do: tool.execute.("call-1", params, signal, nil)

  test "builds the tools from the runtime's own descriptors and exposes its instructions" do
    assert ContextContributor.contribute(%{}) == :skip

    js = Js.tool("/tmp", opts())
    reset = JsReset.tool("/tmp", opts())

    assert js.name == "cua_js"
    assert reset.name == "cua_js_reset"
    assert js.timeout_ms == :infinity
    assert reset.timeout_ms == :infinity
    assert js.description =~ "Fake js tool."
    assert js.description =~ "`cua_repl.js` is the `cua_js` tool"
    assert js.parameters["required"] == ["code"]

    assert {:ok,
            %{title: "Computer use", body: "Fake computer-use instructions.", placement: :system}} =
             ContextContributor.contribute(%{})
  end

  test "forwards text and images unchanged and marks them untrusted" do
    js = Js.tool("/tmp", opts())

    assert %AgentToolResult{
             content: [
               %TextContent{text: "shot"},
               %ImageContent{data: "iVBORw0KGgo=", mime_type: "image/png"}
             ],
             trust: :untrusted,
             is_error: false
           } = run(js, %{"code" => "image"})

    assert %AgentToolResult{
             content: [%TextContent{text: "boom"}],
             is_error: true,
             trust: :untrusted
           } =
             run(js, %{"code" => "error"})
  end

  test "sends the Lemon session and run as the LCU session and turn", %{log: log} do
    js = Js.tool("/tmp", opts(run_id: "run-abc", session_id: "sess-xyz"))
    assert %AgentToolResult{content: [%TextContent{text: "hi"}]} = run(js, %{"code" => "text:hi"})

    assert [%{"sessionId" => "sess-xyz", "turnId" => "run-abc", "toolCallId" => "call-1"}] =
             log |> requests() |> Enum.filter(&(&1["type"] == "call"))
  end

  test "a session outside a run gets one stable turn per session process", %{log: log} do
    session = spawn(fn -> Process.sleep(:infinity) end)
    tool_opts = [session_id: "sess-norun", session_pid: session]

    run(Js.tool("/tmp", tool_opts), %{"code" => "text:a"})
    run(JsReset.tool("/tmp", tool_opts), %{})

    turns = log |> requests() |> Enum.filter(&(&1["type"] == "call")) |> Enum.map(& &1["turnId"])
    assert [turn, turn] = turns
    assert String.starts_with?(turn, "session-sess-norun-")

    Process.exit(session, :kill)

    assert eventually(fn ->
             Enum.any?(requests(log), &(&1["type"] == "turnEnded" and &1["turnId"] == turn))
           end) == true
  end

  test "ends the LCU turn when the Lemon run completes", %{log: log} do
    js = Js.tool("/tmp", opts(run_id: "run-done"))
    run(js, %{"code" => "text:x"})

    event =
      LemonCore.Event.new(
        :run_completed,
        RunCompleted.new(%{completed: %{ok: true}}),
        %{run_id: "run-done"}
      )

    LemonCore.Bus.broadcast("run:run-done", event)

    assert eventually(fn ->
             Enum.any?(requests(log), fn request ->
               request["type"] == "turnEnded" and request["turnId"] == "run-done" and
                 request["sessionId"] == "sess-1" and request["event"] == "Stop"
             end)
           end) == true
  end

  test "routes native-app approval requests to the call's Lemon approval context" do
    parent = self()

    approve = fn request ->
      send(parent, {:approval, request})
      {:ok, :approved, :approve_once}
    end

    js =
      Js.tool(
        "/tmp",
        opts(session_key: "agent:main:x", approval_context: %{approval_request_fun: approve})
      )

    assert %AgentToolResult{content: [%TextContent{text: "approval:accept"}]} =
             run(js, %{"code" => "elicit:com.apple.calculator"})

    assert_received {:approval,
                     %{
                       tool: "computer_use",
                       action: %{"app" => "com.apple.calculator"},
                       session_id: "sess-1",
                       session_key: "agent:main:x",
                       tool_call_id: "call-1",
                       rationale: "Allow Computer Use to use com.apple.calculator?"
                     }}
  end

  test "routes website approval requests as origin approvals" do
    parent = self()

    approve = fn request ->
      send(parent, {:approval, request})
      {:ok, :approved, :approve_once}
    end

    js = Js.tool("/tmp", opts(approval_context: %{approval_request_fun: approve}))

    assert %AgentToolResult{content: [%TextContent{text: "approval:accept"}]} =
             run(js, %{"code" => "origin:http://127.0.0.1:8765"})

    assert_received {:approval,
                     %{tool: "computer_use", action: %{"origin" => "http://127.0.0.1:8765"}}}

    never = fn _request ->
      send(parent, :asked_for_lemon_web)
      {:ok, :approved, :approve_once}
    end

    js = Js.tool("/tmp", opts(approval_context: %{approval_request_fun: never}))

    assert %AgentToolResult{content: [%TextContent{text: "approval:decline"}]} =
             run(js, %{"code" => "origin:http://localhost:#{LemonCore.Runtime.Env.web_port()}"})

    refute_received :asked_for_lemon_web
  end

  test "a denied approval declines and Lemon's own apps are declined without asking" do
    deny = fn _request -> {:ok, :denied} end

    js = Js.tool("/tmp", opts(approval_context: %{approval_request_fun: deny}))

    assert %AgentToolResult{content: [%TextContent{text: "approval:decline"}]} =
             run(js, %{"code" => "elicit:com.apple.TextEdit"})

    test_pid = self()

    never = fn _request ->
      send(test_pid, :asked_for_lemon)
      {:ok, :approved, :approve_once}
    end

    js = Js.tool("/tmp", opts(approval_context: %{approval_request_fun: never}))

    assert %AgentToolResult{content: [%TextContent{text: "approval:decline"}]} =
             run(js, %{"code" => "elicit:org.lemonbot.mac"})

    refute_received :asked_for_lemon
  end

  test "an abort cancels the call in flight and its pending approval" do
    signal = LemonAgent.AbortSignal.new()
    js = Js.tool("/tmp", opts())
    task = Task.async(fn -> run(js, %{"code" => "hang"}, signal) end)

    Process.sleep(300)
    LemonAgent.AbortSignal.abort(signal)

    assert %AgentToolResult{is_error: true, content: [%TextContent{text: text}]} =
             Task.await(task, 5_000)

    assert text =~ "aborted"

    # The server stays usable.
    assert %AgentToolResult{content: [%TextContent{text: "after"}]} =
             run(js, %{"code" => "text:after"})
  end

  test "a bridge crash fails the call as possibly applied and the next call reconnects" do
    js = Js.tool("/tmp", opts())

    assert %AgentToolResult{is_error: true, content: [%TextContent{text: text}]} =
             run(js, %{"code" => "crash"})

    assert text =~ "may already have taken effect"
    assert Server.status().last_error == :bridge_exited

    assert %AgentToolResult{content: [%TextContent{text: "again"}]} =
             run(js, %{"code" => "text:again"})
  end

  @tag connect_fail: true
  test "an unavailable runtime yields an explanatory tool and error result" do
    js = Js.tool("/tmp", opts())
    assert js.description =~ "Currently unavailable"
    assert js.parameters["required"] == ["code"]

    assert %AgentToolResult{is_error: true, content: [%TextContent{text: text}]} =
             run(js, %{"code" => "text:x"})

    assert text =~ "connect refused"

    # Later tool builds answer the known failure at once instead of waiting.
    {micros, result} = :timer.tc(fn -> Server.catalog() end)
    assert {:error, {:bridge_error, "connect refused", _}} = result
    assert micros < 500_000
  end

  test "a call without a session is refused before reaching the runtime", %{log: log} do
    js = Js.tool("/tmp", [])
    assert {:error, message} = run(js, %{"code" => "text:x"})
    assert message =~ "needs a Lemon session"
    refute Enum.any?(requests(log), &(&1["type"] == "call"))
  end
end
