defmodule CodingAgent.NodeToolsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ToolService
  alias CodingAgent.{NodeTools, ToolRegistry}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.ExecutionContext
  alias LemonAgent.NodeRegistry

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    clear_nodes()
    on_exit(&clear_nodes/0)

    local = Path.join(root, "local")
    remote = Path.join(root, "remote")
    File.mkdir_p!(local)
    File.mkdir_p!(remote)

    {:ok, local: local, remote: remote}
  end

  test "routes file and shell calls to the named node's own files", ctx do
    start_hand("hand-1", "box", ctx.remote)

    write = tool(ctx.local, "write")

    result =
      run(write, %{"path" => "notes.txt", "content" => "remote side\n", "node" => "box"})

    refute result.is_error, text(result)
    assert File.read!(Path.join(ctx.remote, "notes.txt")) == "remote side\n"
    refute File.exists?(Path.join(ctx.local, "notes.txt"))
    assert %{node: "box", node_id: "hand-1", outcome: "completed"} = result.details
    assert result.trust == :untrusted

    read = run(tool(ctx.local, "read"), %{"path" => "notes.txt", "node" => "box"})
    assert text(read) =~ "remote side"

    bash = run(tool(ctx.local, "bash"), %{"command" => "pwd", "node" => "box"})
    assert text(bash) =~ Path.basename(ctx.remote)

    local_bash = run(tool(ctx.local, "bash"), %{"command" => "pwd"})
    assert text(local_bash) =~ Path.basename(ctx.local)
  end

  test "a routed edit uses the node's read tracker across calls", ctx do
    start_hand("hand-1", "box", ctx.remote)
    File.write!(Path.join(ctx.remote, "a.txt"), "one\ntwo\n")

    read = run(tool(ctx.local, "read"), %{"path" => "a.txt", "node" => "box"})
    refute read.is_error, text(read)

    edit =
      run(tool(ctx.local, "edit"), %{
        "path" => "a.txt",
        "old_text" => "two",
        "new_text" => "three",
        "node" => "box"
      })

    refute edit.is_error, text(edit)
    assert File.read!(Path.join(ctx.remote, "a.txt")) == "one\nthree\n"
  end

  test "a routed eval cell runs on the node and its tool calls stay there", ctx do
    start_hand("hand-1", "box", ctx.remote)

    code = """
    const here = await tools.bash({command: "pwd"});
    const same = await tools.bash({command: "pwd", node: "box"});
    const other = await tools.bash({command: "pwd", node: "elsewhere"});
    console.log(JSON.stringify({here: here.text.trim(), same: same.text.trim(), other: other.ok, why: other.text, cwd: process.cwd()}));
    """

    result =
      run(tool(ctx.local, "eval"), %{"language" => "js", "code" => code, "node" => "box"})

    refute result.is_error, text(result)
    [json] = Regex.run(~r/\{.*\}/, text(result))
    out = Jason.decode!(json)
    assert out["here"] =~ Path.basename(ctx.remote)
    assert out["same"] == out["here"]
    assert out["cwd"] =~ Path.basename(ctx.remote)
    refute out["other"]
    assert out["why"] =~ "can only call its own tools"
  end

  test "an unknown node fails without running and names the connected nodes", ctx do
    start_hand("hand-1", "box", ctx.remote)

    result = run(tool(ctx.local, "bash"), %{"command" => "touch ran", "node" => "nope"})

    assert result.is_error
    assert text(result) =~ ~s(No connected node named "nope")
    assert text(result) =~ "Connected nodes: box"
    assert result.details.outcome == :not_started
    assert result.details.reason == :skipped
    refute File.exists?(Path.join(ctx.local, "ran"))
  end

  test "a node without coding_agent.tool is refused before dispatch", ctx do
    {:ok, pid} = Task.start_link(fn -> Process.sleep(:infinity) end)
    :ok = NodeRegistry.register("old-1", "old", pid, %{capabilities: %{}})

    result = run(tool(ctx.local, "read"), %{"path" => "x", "node" => "old"})
    assert result.is_error
    assert text(result) =~ "cannot run single tool calls"
    assert %{outcome: :not_started, reason: :skipped} = result.details
  end

  test "a dropped connection reports an unknown outcome and is not retried", ctx do
    parent = self()
    hand = start_hand("hand-1", "box", ctx.remote, notify: parent)

    task =
      Task.async(fn ->
        run(tool(ctx.local, "bash"), %{"command" => "sleep 5", "node" => "box"})
      end)

    assert_receive {:hand_invoked, _invoke_id}, 5_000
    :ok = NodeRegistry.unregister("hand-1", hand)

    result = Task.await(task, 10_000)
    assert result.is_error
    assert text(result) =~ "Outcome unknown"
    assert result.details.outcome == :unknown
    assert result.details.reason == :interrupted
    refute_receive {:hand_invoked, _}, 200
  end

  test "aborting a routed call cancels it on the node", ctx do
    parent = self()
    start_hand("hand-1", "box", ctx.remote, notify: parent)
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        run(tool(ctx.local, "bash"), %{"command" => "sleep 5", "node" => "box"}, signal)
      end)

    assert_receive {:hand_invoked, invoke_id}, 5_000
    AbortSignal.abort(signal)

    result = Task.await(task, 5_000)
    assert result.details.outcome == :unknown
    assert result.details.reason == :interrupted
    assert_receive {:hand_cancelled, ^invoke_id}, 2_000
  end

  test "an abort notification wakes a routed call without waiting for its deadline", ctx do
    start_hand("hand-1", "box", ctx.remote, notify: self())
    signal = AbortSignal.new()

    task =
      Task.async(fn ->
        run(tool(ctx.local, "bash"), %{"command" => "sleep 5", "node" => "box"}, signal)
      end)

    assert_receive {:hand_invoked, invoke_id}, 5_000
    send(task.pid, {:lemon_abort, signal, :abort})

    assert %{outcome: :unknown, reason: :interrupted} = Task.await(task, 5_000).details
    assert_receive {:hand_cancelled, ^invoke_id}, 2_000
    refute AbortSignal.aborted?(signal)
  end

  test "without the nodes tool, node arguments are refused and not advertised", ctx do
    start_hand("hand-1", "box", ctx.remote)
    policy = %{allow: ["bash", "read"]}

    {:ok, bash} =
      ToolRegistry.get_tool(ctx.local, "bash",
        tool_policy: policy,
        tool_intent_recorder: intent_recorder(ctx.local)
      )

    refute Map.has_key?(bash.parameters["properties"], "node")

    result = run(bash, %{"command" => "touch ran", "node" => "box"})
    assert result.is_error
    assert text(result) =~ "cannot route calls"
    assert %{outcome: :not_started, reason: :skipped} = result.details
    refute File.exists?(Path.join(ctx.remote, "ran"))
    refute File.exists?(Path.join(ctx.local, "ran"))
  end

  describe "destination admission" do
    test "effectful requests without an exact controller intent never run", ctx do
      for marker <- [nil, %{"recordedBy" => "controller", "toolCallId" => "other-call"}] do
        args = request("write", %{"path" => "not-run.txt", "content" => "no"})
        args = Map.put(args, "toolIntent", marker)
        assert {:ok, result} = ToolService.run(args, default_cwd: ctx.remote)
        assert result["isError"]
        refute File.exists?(Path.join(ctx.remote, "not-run.txt"))
      end
    end

    test "the exact controller intent permits one destination call", ctx do
      args = request("write", %{"path" => "ran.txt", "content" => "yes"})
      assert {:ok, result} = ToolService.run(args, default_cwd: ctx.remote)
      refute result["isError"]
      assert File.read!(Path.join(ctx.remote, "ran.txt")) == "yes"
    end

    test "the destination capability ceiling forbids tools it excludes", ctx do
      assert {:error, :forbidden} =
               ToolService.run(request("bash", %{"command" => "true"}),
                 default_cwd: ctx.remote,
                 execution_capabilities: ["read"]
               )
    end

    test "a context for another run is rejected", ctx do
      args = request("read", %{"path" => "x"}) |> Map.put("runId", "other-run")

      assert {:error, :invalid_execution_context} =
               ToolService.run(args, default_cwd: ctx.remote)
    end

    test "an unknown tool is unsupported", ctx do
      assert {:error, :unsupported_tool} =
               ToolService.run(request("agent", %{}), default_cwd: ctx.remote)
    end

    test "a cell on the node cannot run a call the session would have reviewed", ctx do
      code = """
      const r = await tools.bash({command: "touch reviewed-call-ran"});
      console.log(JSON.stringify({ok: r.ok, text: r.text}));
      """

      args =
        request("eval", %{"language" => "js", "code" => code}, %{approval_mode: :write})

      assert {:ok, result} = ToolService.run(args, default_cwd: ctx.remote, node_name: "box")
      [text] = for %{"type" => "text", "text" => t} <- result["content"], do: t
      assert text =~ ~s("ok":false)
      assert text =~ "needs approval"
      refute File.exists?(Path.join(ctx.remote, "reviewed-call-ran"))
    end
  end

  test "results round-trip through the transport codec without trust metadata" do
    result =
      %AgentToolResult{
        content: [%LemonAi.Types.TextContent{text: "hi"}],
        details: %{exit_code: 0, trust_boundary: %{untrusted: false}},
        is_error: false
      }

    encoded = NodeTools.encode_result(result)
    assert {:ok, json} = Jason.encode(encoded)
    assert {:ok, decoded} = json |> Jason.decode!() |> NodeTools.decode_result()
    assert decoded.details == %{"exit_code" => 0}
    assert [%{text: "hi"}] = decoded.content
  end

  test "interrupted outcomes normalize at the transport boundary" do
    for {outcome, reason} <- [
          {:not_started, :skipped},
          {:unknown, :interrupted},
          {:unknown, :aborted},
          {:unknown, :timeout},
          {:unknown, :crashed}
        ] do
      result = %AgentToolResult{
        content: [%LemonAi.Types.TextContent{text: "node-specific notice"}],
        details: %{outcome: outcome, reason: reason, node: "box"},
        is_error: true
      }

      assert {:ok, decoded} =
               result
               |> NodeTools.encode_result()
               |> Jason.encode!()
               |> Jason.decode!()
               |> NodeTools.decode_result()

      assert decoded.details == %{"node" => "box", outcome: outcome, reason: reason}
      assert [%{text: "node-specific notice"}] = decoded.content
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tool(cwd, name) do
    {:ok, tool} =
      ToolRegistry.get_tool(cwd, name,
        session_id: "node-tools-test",
        tool_intent_recorder: intent_recorder(cwd)
      )

    tool
  end

  defp intent_recorder(cwd) do
    fn data ->
      path = Path.join(cwd, "intent-#{System.unique_integer([:positive])}.jsonl")
      session = CodingAgent.SessionManager.new(cwd) |> CodingAgent.SessionManager.persist(path)

      try do
        case CodingAgent.SessionManager.record_tool_intent(session, data) do
          {:ok, _session} -> :ok
          {:error, reason, _session} -> {:error, reason}
        end
      after
        CodingAgent.SessionManager.close(session)
      end
    end
  end

  defp run(tool, params, signal \\ nil) do
    case tool.execute.("call-#{System.unique_integer([:positive])}", params, signal, nil) do
      {:ok, %AgentToolResult{} = result} -> result
      %AgentToolResult{} = result -> result
    end
  end

  defp text(%AgentToolResult{content: content}),
    do: Enum.map_join(content, "", &Map.get(&1, :text, ""))

  defp request(tool, arguments, policy \\ nil) do
    {:ok, context} = ExecutionContext.new(run_id: "run-1", tool_policy: policy)
    {:ok, context} = ExecutionContext.for_remote(context, nil)
    {:ok, encoded} = ExecutionContext.encode(context)

    %{
      "version" => 1,
      "tool" => tool,
      "arguments" => arguments,
      "toolCallId" => "call-1",
      "toolIntent" => %{"recordedBy" => "controller", "toolCallId" => "call-1"},
      "sessionId" => "session-1",
      "runId" => "run-1",
      "executionContext" => encoded
    }
  end

  # A fake node connection that runs requests through the real destination
  # service, the way the worker does.
  defp start_hand(node_id, name, cwd, opts \\ []) do
    notify = Keyword.get(opts, :notify)
    {:ok, pid} = Task.start_link(fn -> hand_loop(node_id, name, cwd, notify) end)

    :ok =
      NodeRegistry.register(node_id, name, pid, %{
        capabilities: %{NodeTools.method() => NodeTools.capability()}
      })

    pid
  end

  defp hand_loop(node_id, name, cwd, notify) do
    receive do
      {:node_event, "node.invoke.request", %{"invokeId" => invoke_id, "args" => args}} ->
        if notify, do: send(notify, {:hand_invoked, invoke_id})

        spawn(fn ->
          case ToolService.run(args, default_cwd: cwd, node_name: name) do
            {:ok, result} -> NodeRegistry.complete(node_id, invoke_id, result)
            {:error, reason} -> NodeRegistry.complete(node_id, invoke_id, nil, to_string(reason))
          end
        end)

      {:node_event, "node.invoke.cancel", %{"invokeId" => invoke_id}} ->
        if notify, do: send(notify, {:hand_cancelled, invoke_id})

      _other ->
        :ok
    end

    hand_loop(node_id, name, cwd, notify)
  end

  defp clear_nodes do
    for node <- NodeRegistry.list(), do: NodeRegistry.unregister(node.id, node.pid)
  end
end
