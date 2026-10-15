defmodule LemonOmp.Tools.OmpTest do
  # Drives the fake omp through the agent tool; shares the live-session cap.
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonOmp.Tools.Omp

  setup do
    use_fake_omp()
    ws = workspace!()
    key = "agent:omp-tool-test:#{System.unique_integer([:positive])}"
    {:ok, ws: ws, key: key, tool: Omp.tool(ws, session_key: key)}
  end

  defp run(tool, params, on_update \\ nil, signal \\ nil),
    do: tool.execute.("call-#{System.unique_integer([:positive])}", params, signal, on_update)

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text

  defp assert_untrusted(%AgentToolResult{} = result) do
    assert result.trust == :untrusted
    assert %{trust_boundary: _} = result.details
    result
  end

  test "describes itself as the omp tool" do
    tool = Omp.tool()
    assert tool.name == "omp"
    assert "action" in tool.parameters["required"]

    assert tool.parameters["properties"]["action"]["enum"] ==
             ~w(models start start_many wait status subagent list send configure cancel close resume discover)

    assert tool.parameters["properties"]["approval_mode"]["enum"] == ~w(always-ask write yolo)
    assert tool.parameters["properties"]["mode"]["enum"] == ~w(steer follow_up redirect)
    assert tool.parameters["properties"]["mode"]["description"] =~ "going the wrong way"
    assert tool.parameters["properties"]["approval_mode"]["description"] =~ "start, resume"
    assert tool.description =~ "models + configure"
    assert tool.description =~ "cheaper model"

    assert tool.parameters["properties"]["tasks"]["items"]["properties"]["approval_mode"]["enum"] ==
             ~w(always-ask write yolo)
  end

  test "default 600-second wait survives a shorter generic tool deadline", ctx do
    assert ctx.tool.timeout_ms == :infinity
    started = run(ctx.tool, %{"action" => "start", "prompt" => "HOLD deadline"})
    id = started.details["session"]["id"]
    {:ok, stream} = LemonAgent.EventStream.start_link(timeout: :infinity)
    context = %LemonAgent.Types.AgentContext{tools: [ctx.tool]}

    call = %LemonAi.Types.ToolCall{
      id: "long-wait",
      name: "omp",
      arguments: %{"action" => "wait", "id" => id}
    }

    runner =
      Task.async(fn ->
        LemonAgent.Loop.ToolCalls.execute_and_collect_tools(
          context,
          [],
          [call],
          %LemonAgent.Types.AgentLoopConfig{tool_timeout_ms: 10},
          nil,
          stream
        )
      end)

    assert Task.yield(runner, 100) == nil
    assert {:ok, _} = LemonOmp.send_message(id, "finish after generic deadline", :steer)
    {[message], _, _, _} = Task.await(runner, 2_000)
    refute message.is_error
    assert Enum.any?(message.content, &(&1.text =~ "finish after generic deadline"))
    LemonAgent.EventStream.complete(stream, [])
  end

  test "configure reports refreshed model and thinking with owner-scoped untrusted output", ctx do
    started = run(ctx.tool, %{"action" => "start", "prompt" => "HOLD configure"})
    id = started.details["session"]["id"]

    configured =
      run(ctx.tool, %{
        "action" => "configure",
        "id" => id,
        "model" => "fake/cheap",
        "thinking" => "minimal"
      })
      |> assert_untrusted()

    refute configured.is_error
    assert configured.details["action"] == "configure"
    assert configured.details["session"]["model"] == "fake/cheap"
    assert configured.details["session"]["thinking"] == "minimal"
    assert text(configured) =~ "model fake/cheap, thinking minimal"
    assert text(configured) =~ "next model call"

    foreign = Omp.tool(ctx.ws, session_key: "another-conversation")
    denied = run(foreign, %{"action" => "configure", "id" => id, "thinking" => "low"})
    assert denied.is_error
    assert denied.details["error"] == "not_found"

    invalid = run(ctx.tool, %{"action" => "configure", "id" => id})
    assert invalid.is_error
    assert invalid.details["error"] == "invalid_params"
  end

  test "configure reports applied fields and the second-step rejection", ctx do
    started = run(ctx.tool, %{"action" => "start", "prompt" => "HOLD configure"})
    id = started.details["session"]["id"]
    File.write!(Path.join(ctx.ws, ".fake_omp_thinking_mode"), "reject")

    result =
      run(ctx.tool, %{
        "action" => "configure",
        "id" => id,
        "model" => "fake/cheap",
        "thinking" => "low"
      })
      |> assert_untrusted()

    assert result.is_error
    assert result.details["error"] == "partially_applied"
    assert result.details["applied"] == ["model"]
    assert result.details["failedStep"] == "thinking"
    assert result.details["cause"] == "rejected"
    assert text(result) =~ "Applied model; thinking failed"
    assert text(result) =~ "Thinking refused"
    assert text(result) =~ "not rolled back"
  end

  test "subagent status, streamed progress and drill-down text are untrusted", ctx do
    started = run(ctx.tool, %{"action" => "start", "prompt" => "SUBAGENTS HOLD"})
    id = started.details["session"]["id"]
    await_wire(id, &(get_in(&1, ["subagents", Access.at(0), "toolCalls"]) == 2))

    status = run(ctx.tool, %{"action" => "status", "id" => id}) |> assert_untrusted()
    assert text(status) =~ "Subagents: explore (running) — Running write — Create sub.txt"
    parent = self()
    signal = LemonAgent.AbortSignal.new()
    :ok = LemonAgent.AbortSignal.abort(signal)
    run(ctx.tool, %{"action" => "wait", "id" => id}, &send(parent, {:child_update, &1}), signal)
    assert_receive {:child_update, update}
    assert text(update) =~ "Subagents: explore (running) — Running write — Create sub.txt"
    assert update.trust == :untrusted

    run(
      ctx.tool,
      %{"action" => "wait", "ids" => [id]},
      &send(parent, {:child_batch_update, &1}),
      signal
    )

    assert_receive {:child_batch_update, batch_update}
    assert batch_update.trust == :untrusted
    assert text(batch_update) =~ "Subagents: explore (running) — Running write — Create sub.txt"

    transcript =
      run(ctx.tool, %{
        "action" => "subagent",
        "id" => id,
        "subagent_id" => "child-1",
        "limit" => 1
      })
      |> assert_untrusted()

    refute transcript.is_error
    assert transcript.details["action"] == "subagent"
    assert transcript.details["subagentId"] == "child-1"
    assert length(transcript.details["transcript"]["messages"]) == 1
    assert text(transcript) =~ "omp subagent child-1 transcript tail:"
    assert text(transcript) =~ "[toolResult write]\nmessage 60 "
    refute text(transcript) =~ "\u202e"

    foreign = Omp.tool(ctx.ws, session_key: "another-conversation")
    denied = run(foreign, %{"action" => "subagent", "id" => id, "subagent_id" => "child-1"})
    assert denied.is_error
    assert denied.details["error"] == "not_found"
    missing = run(ctx.tool, %{"action" => "subagent", "id" => id, "subagent_id" => "missing"})
    assert missing.is_error
    assert missing.details["error"] == "rejected"
    assert text(missing) =~ "Unknown subagent"
  end

  test "resume explicitly continues interrupted work without accepting an extra prompt", ctx do
    invalid =
      run(ctx.tool, %{
        "action" => "resume",
        "omp_session_id" => "01abcd",
        "continue" => true,
        "prompt" => "extra"
      })

    assert invalid.is_error

    result =
      run(ctx.tool, %{
        "action" => "resume",
        "omp_session_id" => "01abcd",
        "continue" => true,
        "wait" => true
      })

    refute result.is_error
    assert result.details["session"]["lastTurn"] == "completed"
    assert File.read!(Path.join(ctx.ws, ".fake_omp.args")) =~ "--resume 01abcd"
  end

  test "parallel workers forward approval modes and native routing context", ctx do
    tool = Omp.tool(ctx.ws, session_key: ctx.key, session_id: "batch-native", run_id: "batch-run")
    LemonCore.Bus.subscribe("exec_approvals")
    workspaces = [ctx.ws, workspace!()]
    modes = ["always-ask", "write"]

    tasks =
      Enum.zip_with(workspaces, modes, fn ws, mode ->
        %{"cwd" => ws, "prompt" => "APPROVAL", "approval_mode" => mode}
      end)

    result = run(tool, %{"action" => "start_many", "tasks" => tasks}) |> assert_untrusted()
    refute result.is_error
    sessions = result.details["sessions"]
    assert Enum.map(sessions, & &1["approvalMode"]) == modes

    for {ws, mode} <- Enum.zip(workspaces, modes) do
      assert File.read!(Path.join(ws, ".fake_omp.args")) =~ "--approval-mode #{mode}"
    end

    for _ <- sessions do
      assert_receive %LemonCore.Event{type: :approval_requested, payload: %{pending: pending}},
                     5_000

      assert pending.session_id == "batch-native"
      assert pending.run_id == "batch-run"
      assert pending.session_key == ctx.key
      assert Enum.any?(sessions, &(&1["id"] == pending.action["ompSession"]))
      assert {:ok, _} = LemonCore.ExecApprovals.resolve(pending.id, :deny)
    end
  end

  test "start and resume forward approval mode and native approval routing context", ctx do
    tool = Omp.tool(ctx.ws, session_key: ctx.key, session_id: "native-id", run_id: "run-id")
    LemonCore.Bus.subscribe("exec_approvals")

    for params <- [
          %{"action" => "start", "prompt" => "APPROVAL", "approval_mode" => "always-ask"},
          %{
            "action" => "resume",
            "omp_session_id" => "fake-session-0001",
            "prompt" => "APPROVAL",
            "approval_mode" => "write"
          }
        ] do
      result = run(tool, params) |> assert_untrusted()
      refute result.is_error
      wire = result.details["session"]
      assert wire["approvalMode"] == params["approval_mode"]

      assert File.read!(Path.join(ctx.ws, ".fake_omp.args")) =~
               "--approval-mode #{params["approval_mode"]}"

      assert_receive %LemonCore.Event{type: :approval_requested, payload: %{pending: pending}},
                     5_000

      assert pending.session_id == "native-id"
      assert pending.run_id == "run-id"
      assert pending.session_key == ctx.key
      assert {:ok, _} = LemonCore.ExecApprovals.resolve(pending.id, :deny)
      await_wire(wire["id"], &(&1["pendingApprovals"] == []))
      assert {:ok, _} = LemonOmp.close(wire["id"])
    end
  end

  test "wait reports pending approval and where to resolve it", ctx do
    parent = self()
    on_update = fn update -> send(parent, {:approval_update, update}) end
    result = run(ctx.tool, %{"action" => "start", "prompt" => "APPROVAL"})
    id = result.details["session"]["id"]
    await_wire(id, &(&1["pendingApprovals"] != []))
    signal = LemonAgent.AbortSignal.new()
    :ok = LemonAgent.AbortSignal.abort(signal)
    wait = run(ctx.tool, %{"action" => "wait", "id" => id}, on_update, signal)
    assert text(wait) =~ "Pending approvals:"
    assert_receive {:approval_update, update}
    assert text(update) =~ "Waiting for approval: bash"
    assert text(update) =~ "exec.approval.resolve"
  end

  test "start, status, list, send, cancel and close a session it owns", ctx do
    result =
      run(ctx.tool, %{"action" => "start", "prompt" => "HOLD for the tool"}) |> assert_untrusted()

    refute result.is_error

    assert %{"action" => "start", "session" => %{"id" => id, "status" => "running", "cwd" => cwd}} =
             result.details

    assert cwd == ctx.ws
    assert text(result) =~ "Started omp session #{id}"
    assert {:ok, %{"owner" => %{"kind" => "agent", "sessionKey" => key}}} = LemonOmp.get(id)
    assert key == ctx.key

    status = run(ctx.tool, %{"action" => "status", "id" => id}) |> assert_untrusted()
    assert %{"action" => "status", "session" => %{"id" => ^id}} = status.details
    assert text(status) =~ "omp session #{id}"
    assert text(status) =~ "Status: running"

    list = run(ctx.tool, %{"action" => "list"}) |> assert_untrusted()
    assert %{"action" => "list", "sessions" => [%{"id" => ^id}]} = list.details
    assert text(list) =~ "- #{id} [running] HOLD for the tool"

    follow =
      run(ctx.tool, %{"action" => "send", "id" => id, "message" => "later", "mode" => "follow_up"})

    assert %{"action" => "send", "delivery" => "followUp", "session" => %{"id" => ^id}} =
             assert_untrusted(follow).details

    assert text(follow) =~ "delivered as followUp"

    cancel = run(ctx.tool, %{"action" => "cancel", "id" => id}) |> assert_untrusted()
    refute cancel.is_error
    assert %{"action" => "cancel", "session" => %{"id" => ^id}} = cancel.details
    assert %{"lastTurn" => "aborted"} = await_wire(id, &(&1["status"] == "idle"))

    steer = run(ctx.tool, %{"action" => "send", "id" => id, "message" => "new work"})
    assert %{"delivery" => "prompt"} = assert_untrusted(steer).details
    await_wire(id, &(&1["result"] == "Done: new work"))

    close = run(ctx.tool, %{"action" => "close", "id" => id}) |> assert_untrusted()
    assert %{"action" => "close", "session" => %{"status" => "closed"}} = close.details
    assert text(close) =~ "can be resumed later"

    again =
      run(ctx.tool, %{"action" => "send", "id" => id, "message" => "more"}) |> assert_untrusted()

    assert again.is_error
    assert %{"action" => "send", "error" => "not_running"} = again.details
    assert text(again) == "omp send failed: " <> LemonOmp.error_message(:not_running)
  end

  test "send redirect aborts the running turn and describes the accepted redirect", ctx do
    started = run(ctx.tool, %{"action" => "start", "prompt" => "HOLD the wrong task"})
    id = started.details["session"]["id"]
    await_wire(id, &(&1["activeTools"] != []))

    redirected =
      run(ctx.tool, %{
        "action" => "send",
        "id" => id,
        "message" => "the right task",
        "mode" => "redirect"
      })
      |> assert_untrusted()

    refute redirected.is_error
    assert redirected.details["delivery"] == "redirect"
    assert text(redirected) =~ "redirected the turn"
    assert Enum.any?(received(ctx.ws), &(&1["type"] == "abort_and_prompt"))

    assert %{"lastTurn" => "completed"} =
             await_wire(id, &(&1["result"] == "Redirected: the right task"))
  end

  test "start with wait streams progress until the turn settles", ctx do
    parent = self()
    on_update = fn %AgentToolResult{} = update -> send(parent, {:update, update}) end

    result =
      run(ctx.tool, %{"action" => "start", "prompt" => "a quick job", "wait" => true}, on_update)

    assert_untrusted(result)

    assert %{
             "action" => "start",
             "session" => %{"status" => "idle", "result" => "Done: a quick job"}
           } = result.details

    assert text(result) =~ "Last result:\nDone: a quick job"
  end

  test "wait streams updates through on_update and honours timeouts and aborts", ctx do
    parent = self()
    on_update = fn update -> send(parent, {:update, update}) end

    %{"session" => %{"id" => id}} =
      run(ctx.tool, %{"action" => "start", "prompt" => "HOLD please"}).details

    signal = LemonAgent.AbortSignal.new()
    :ok = LemonAgent.AbortSignal.abort(signal)
    aborted = run(ctx.tool, %{"action" => "wait", "id" => id}, on_update, signal)
    assert text(aborted) =~ "Stopped waiting; the omp session keeps running."

    task =
      Task.async(fn ->
        run(ctx.tool, %{"action" => "wait", "id" => id, "timeout_seconds" => 5}, on_update)
      end)

    wait_until(fn ->
      match?(
        {:current_function, {LemonOmp, :wait_loop, 4}},
        Process.info(task.pid, :current_function)
      )
    end)

    assert {:ok, _} = LemonOmp.send_message(id, "wrap up", :steer)
    result = Task.await(task, 7_000) |> assert_untrusted()

    refute result.is_error

    assert %{
             "action" => "wait",
             "session" => %{"status" => "idle", "result" => "Steered: wrap up"}
           } = result.details

    assert_received {:update,
                     %AgentToolResult{
                       trust: :untrusted,
                       details: %{"action" => "wait", "session" => %{"id" => ^id}},
                       content: [%TextContent{text: "omp " <> _}]
                     }}
  end

  test "wait reports a session still running after the timeout", ctx do
    %{"session" => %{"id" => id}} =
      run(ctx.tool, %{"action" => "start", "prompt" => "HOLD long"}).details

    # timeout_seconds is whole seconds; 1 is the minimum.
    result = run(ctx.tool, %{"action" => "wait", "id" => id, "timeout_seconds" => 1})
    assert text(result) =~ "Still running after 1s (omp keeps working)."
    assert %{"session" => %{"status" => "running"}} = result.details
  end

  test "sessions of other conversations and the operator are not visible", ctx do
    {:ok, %{"id" => foreign}} =
      LemonOmp.start(%{"prompt" => "HOLD theirs", "cwd" => ctx.ws},
        owner: %{kind: :agent, session_key: "agent:someone-else"}
      )

    {:ok, %{"id" => operator}} =
      LemonOmp.start(%{"prompt" => "HOLD operator", "cwd" => workspace!()})

    for id <- [foreign, operator], action <- ~w(status cancel close wait) do
      result =
        run(ctx.tool, %{"action" => action, "id" => id, "timeout_seconds" => 1})
        |> assert_untrusted()

      assert result.is_error
      assert %{"action" => ^action, "error" => "not_found"} = result.details
      assert text(result) == "omp #{action} failed: no such omp session."
    end

    send = run(ctx.tool, %{"action" => "send", "id" => foreign, "message" => "hijack"})
    assert %{"error" => "not_found"} = send.details

    assert text(run(ctx.tool, %{"action" => "list"})) ==
             "No omp sessions started from this conversation."

    assert {:ok, %{"status" => "running"}} = LemonOmp.get(foreign)
    refute "abort" in Enum.map(received(ctx.ws), & &1["type"])
  end

  test "errors are safe is_error results", ctx do
    for {params, code, message} <- [
          {%{"action" => "explode"}, "invalid_params", "omp omp failed: action must be one of:"},
          {%{}, "invalid_params", "omp omp failed: action must be one of:"},
          {%{"action" => "status"}, "invalid_params",
           "omp status failed: missing required parameters"},
          {%{"action" => "send", "id" => "omp_x"}, "invalid_params",
           "omp send failed: missing required"},
          {%{"action" => "start"}, "invalid_prompt", "omp start failed: prompt must be"},
          {%{"action" => "start", "prompt" => "x", "cwd" => "/definitely/not/here"},
           "invalid_cwd", "omp start failed: cwd must be"},
          {%{"action" => "send", "id" => "omp_x", "message" => ""}, "invalid_message",
           "omp send failed: message must be"},
          {%{"action" => "resume", "omp_session_id" => "../x"}, "invalid_params",
           "omp resume failed: invalid"}
        ] do
      result = run(ctx.tool, params) |> assert_untrusted()
      assert result.is_error, inspect(params)
      assert result.details["error"] == code, inspect(params)
      assert String.starts_with?(text(result), message), "#{inspect(params)}: #{text(result)}"
    end

    put_app_env(:executable, Path.join(ctx.ws, "no/omp"))
    missing = run(ctx.tool, %{"action" => "start", "prompt" => "hi"})
    assert %{"error" => "not_installed"} = missing.details
    assert text(missing) =~ "omp is not installed"
  end

  test "an unacknowledged start names the kept session so it can be reconciled", ctx do
    put_app_env(:command_timeout_ms, 300)
    File.write!(Path.join(ctx.ws, ".fake_omp_mode"), "hang")

    result = run(ctx.tool, %{"action" => "start", "prompt" => "anyone?"}) |> assert_untrusted()
    assert result.is_error
    assert %{"action" => "start", "error" => "outcome_unknown"} = result.details
    assert [%{"id" => id}] = LemonOmp.list(owner: {:session_key, ctx.key})
    assert text(result) =~ "session #{id} may already be working on it"

    status = run(ctx.tool, %{"action" => "status", "id" => id})
    refute status.is_error
    assert text(status) =~ "Status: starting"
  end

  test "discover lists stored sessions for the workspace", ctx do
    agent_dir = tmp_dir!("lemon_omp_tool_agent")
    put_app_env(:agent_dir, agent_dir)

    empty = run(ctx.tool, %{"action" => "discover"}) |> assert_untrusted()
    assert %{"action" => "discover", "sessions" => []} = empty.details
    assert text(empty) == "No stored omp sessions for #{ctx.ws}."

    {out, 0} = System.cmd("/bin/pwd", ["-P"], cd: ctx.ws)
    canonical = String.trim(out)

    store =
      Path.join([
        agent_dir,
        "sessions",
        "--" <> String.replace(String.trim_leading(canonical, "/"), "/", "-") <> "--"
      ])

    File.mkdir_p!(store)

    File.write!(
      Path.join(store, "2026-10-13T10-00-00-000Z_01tool-0001.jsonl"),
      Enum.map_join(
        [
          %{"type" => "title", "v" => 1, "title" => "Stored \e[1mwork\e[0m"},
          %{"type" => "session", "id" => "01tool-0001", "cwd" => canonical},
          %{"type" => "custom", "customType" => "session_exit"}
        ],
        "",
        &(Jason.encode!(&1) <> "\n")
      )
    )

    found = run(ctx.tool, %{"action" => "discover"}) |> assert_untrusted()

    assert %{
             "action" => "discover",
             "sessions" => [%{"ompSessionId" => "01tool-0001", "source" => "omp"}]
           } =
             found.details

    assert text(found) =~ "- 01tool-0001 [empty] Stored work"
    assert text(found) =~ "(source: omp)"

    bad = run(ctx.tool, %{"action" => "discover", "cwd" => Path.join(ctx.ws, "missing")})
    assert bad.is_error
    assert %{"error" => "invalid_cwd"} = bad.details
  end

  test "start_many defaults cwd, preserves per-worker overrides and gathers usage", ctx do
    other = workspace!()
    parent = self()
    update = &send(parent, {:combined, &1})

    result =
      run(
        ctx.tool,
        %{
          "action" => "start_many",
          "tasks" => [
            %{"prompt" => "first worker"},
            %{
              "prompt" => "second worker",
              "cwd" => other,
              "model" => "fake/other",
              "thinking" => "low"
            }
          ],
          "wait" => true
        },
        update
      )
      |> assert_untrusted()

    refute result.is_error

    assert %{"action" => "start_many", "sessions" => [a, b], "errors" => [], "usage" => usage} =
             result.details

    assert a["cwd"] == ctx.ws
    assert b["cwd"] == other
    assert Enum.all?([a, b], &(&1["status"] == "idle" and &1["lastTurn"] == "completed"))
    assert usage["totalTokens"] >= 340
    assert usage["cost"] > 0
    assert text(result) =~ a["id"]
    assert text(result) =~ b["id"]
    assert text(result) =~ "last turn completed"
    assert text(result) =~ "Done: first worker"
    assert text(result) =~ "Combined usage:"

    assert_received {:combined,
                     %AgentToolResult{
                       trust: :untrusted,
                       details: %{"action" => "start_many", "sessions" => [_, _]}
                     }}
  end

  test "start_many reports partial failures per task and errors only when all failed", ctx do
    other = workspace!()

    result =
      run(ctx.tool, %{
        "action" => "start_many",
        "tasks" => [%{"prompt" => "HOLD good"}, %{"prompt" => "REJECT", "cwd" => other}]
      })
      |> assert_untrusted()

    refute result.is_error

    assert %{
             "sessions" => [%{"status" => "running"}],
             "errors" => [%{"task" => 1, "error" => "rejected"}]
           } = result.details

    assert text(result) =~ "Task 2:"
    assert text(result) =~ "Task refused"

    failed =
      run(ctx.tool, %{
        "action" => "start_many",
        "tasks" => [%{"prompt" => "REJECT", "cwd" => other}]
      })

    assert failed.is_error

    assert %{"sessions" => [], "errors" => [%{"task" => 0, "error" => "rejected"}]} =
             failed.details
  end

  test "start_many invalidates the entire batch before starting", ctx do
    result =
      run(ctx.tool, %{
        "action" => "start_many",
        "tasks" => [%{"prompt" => "HOLD valid"}, %{"prompt" => ""}]
      })

    assert result.is_error
    assert result.details["error"] == "invalid_task"
    assert text(result) =~ "task 2: prompt must"
    refute File.exists?(Path.join(ctx.ws, ".fake_omp.pid"))
  end

  test "wait ids supports any/all and streams combined details", ctx do
    parent = self()

    %{"sessions" => [a, b]} =
      run(ctx.tool, %{
        "action" => "start_many",
        "tasks" => [
          %{"prompt" => "HOLD first"},
          %{"prompt" => "HOLD second", "cwd" => workspace!()}
        ]
      }).details

    ids = [a["id"], b["id"]]
    assert {:ok, _} = LemonOmp.cancel(a["id"])
    await_wire(a["id"], &(&1["status"] == "idle"))

    any = run(ctx.tool, %{"action" => "wait", "ids" => ids, "wait_for" => "any"})
    refute any.is_error

    assert %{
             "sessions" => [%{"status" => "idle"}, %{"status" => "running"}],
             "reason" => "settled"
           } = any.details

    signal = LemonAgent.AbortSignal.new()
    :ok = LemonAgent.AbortSignal.abort(signal)
    aborted = run(ctx.tool, %{"action" => "wait", "ids" => ids}, nil, signal)
    assert text(aborted) =~ "Stopped waiting"
    assert aborted.details["reason"] == "aborted"

    assert {:ok, _} = LemonOmp.send_message(b["id"], "finish", :steer)
    all = run(ctx.tool, %{"action" => "wait", "ids" => ids}, &send(parent, {:many_wait, &1}))
    refute all.is_error
    assert Enum.all?(all.details["sessions"], &(&1["status"] == "idle"))

    assert_received {:many_wait,
                     %AgentToolResult{details: %{"action" => "wait", "sessions" => [_, _]}}}

    missing = run(ctx.tool, %{"action" => "wait", "ids" => ids ++ ["omp_missing"]})
    assert missing.is_error
    assert missing.details["error"] == "not_found"

    invalid = run(ctx.tool, %{"action" => "wait", "ids" => ids, "wait_for" => "wrong"})
    assert invalid.is_error
    assert invalid.details["error"] == "invalid_params"
  end
end
