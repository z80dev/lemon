defmodule CodingAgent.NodeToolsTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.ToolService
  alias CodingAgent.{NodeTools, ToolRegistry}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.{ExecutionContext, NodeRegistry}

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

  test "an unknown node fails without running and names the connected nodes", ctx do
    start_hand("hand-1", "box", ctx.remote)

    result = run(tool(ctx.local, "bash"), %{"command" => "touch ran", "node" => "nope"})

    assert result.is_error
    assert text(result) =~ ~s(No connected node named "nope")
    assert text(result) =~ "Connected nodes: box"
    assert result.details.outcome == "not_run"
    refute File.exists?(Path.join(ctx.local, "ran"))
  end

  test "a node without coding_agent.tool is refused before dispatch", ctx do
    {:ok, pid} = Task.start_link(fn -> Process.sleep(:infinity) end)
    :ok = NodeRegistry.register("old-1", "old", pid, %{capabilities: %{}})

    result = run(tool(ctx.local, "read"), %{"path" => "x", "node" => "old"})
    assert result.is_error
    assert text(result) =~ "cannot run single tool calls"
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
    assert result.details.outcome == "unknown"
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
    assert result.details.outcome == "unknown"
    assert_receive {:hand_cancelled, ^invoke_id}, 2_000
  end

  test "without the nodes tool, node arguments are refused and not advertised", ctx do
    start_hand("hand-1", "box", ctx.remote)
    policy = %{allow: ["bash", "read"]}

    {:ok, bash} = ToolRegistry.get_tool(ctx.local, "bash", tool_policy: policy)
    refute Map.has_key?(bash.parameters["properties"], "node")

    result = run(bash, %{"command" => "touch ran", "node" => "box"})
    assert result.is_error
    assert text(result) =~ "cannot route calls"
    refute File.exists?(Path.join(ctx.remote, "ran"))
    refute File.exists?(Path.join(ctx.local, "ran"))
  end

  describe "destination admission" do
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

  # ── helpers ──────────────────────────────────────────────────────────────

  defp tool(cwd, name) do
    {:ok, tool} = ToolRegistry.get_tool(cwd, name, session_id: "node-tools-test")
    tool
  end

  defp run(tool, params, signal \\ nil) do
    case tool.execute.("call-#{System.unique_integer([:positive])}", params, signal, nil) do
      {:ok, %AgentToolResult{} = result} -> result
      %AgentToolResult{} = result -> result
    end
  end

  defp text(%AgentToolResult{content: content}),
    do: Enum.map_join(content, "", &Map.get(&1, :text, ""))

  defp request(tool, arguments) do
    {:ok, context} = ExecutionContext.new(run_id: "run-1")
    {:ok, context} = ExecutionContext.for_remote(context, nil)
    {:ok, encoded} = ExecutionContext.encode(context)

    %{
      "version" => 1,
      "tool" => tool,
      "arguments" => arguments,
      "toolCallId" => "call-1",
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
