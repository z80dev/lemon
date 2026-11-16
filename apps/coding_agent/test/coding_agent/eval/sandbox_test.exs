defmodule CodingAgent.Eval.SandboxTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Eval.{KernelSupervisor, Sandbox}
  alias CodingAgent.{ToolDisclosure, ToolPolicy, ToolRegistry, ToolResources}
  alias CodingAgent.Tools.CodeMode
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :deno
  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    id = "code-mode-#{System.unique_integer([:positive])}"
    opts = [session_id: id, session_pid: self()]
    on_exit(fn -> ToolResources.stop(id) end)
    {:ok, cwd: cwd, id: id, opts: opts}
  end

  test "direct file, network, env, process and module access is denied", %{cwd: cwd, opts: opts} do
    secret = Path.join(cwd, "private.txt")
    target = Path.join(cwd, "forbidden.txt")
    module = Path.join(cwd, "private.js")
    File.write!(secret, "not available to cells")
    File.write!(module, "export default 'not available to cells';")

    code = """
    const attempts = {
      fs_read: () => Deno.readTextFile(#{Jason.encode!(secret)}),
      fs_write: () => Deno.writeTextFile(#{Jason.encode!(target)}, "forbidden"),
      net: () => fetch("http://127.0.0.1:18080/code-mode-must-not-connect"),
      env: () => Deno.env.get("HOME"),
      process: () => new Deno.Command("sh", {args: ["-c", "exit 0"]}).output(),
      module: () => import(#{Jason.encode!("file://" <> module)})
    };
    const results = {};
    for (const [name, attempt] of Object.entries(attempts)) {
      try { await attempt(); results[name] = "UNEXPECTED_AUTHORITY"; }
      catch (error) { results[name] = String(error); }
    }
    return results;
    """

    result = execute(cwd, opts, code)
    assert result.details.status == :ok
    text = text(result)
    refute text =~ "UNEXPECTED_AUTHORITY"
    assert text =~ "fs_read"
    results = Jason.decode!(text)

    Enum.each(results, fn {name, error} ->
      assert error =~ ~r/NotCapable|PermissionDenied|Requires .* access|permission/i,
             "#{name} did not fail at its permission boundary: #{error}"
    end)

    assert text =~ "fs_write"
    assert text =~ "net"
    assert text =~ "NotCapable" or text =~ "PermissionDenied"
    refute text =~ "not available to cells"
    refute File.exists?(target)
  end

  test "yield re-attaches the same cell without replaying its tool call", %{
    cwd: cwd,
    id: id,
    opts: opts
  } do
    parent = self()

    gate = %AgentTool{
      name: "gate",
      description: "Controlled test gate",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn call_id, _args, _signal, _update ->
        send(parent, {:gate_started, self(), call_id})

        receive do
          :release -> %AgentToolResult{content: [%TextContent{text: "released"}]}
        end
      end
    }

    opts = Keyword.put(opts, :tool_resolver, fn "gate" -> {:ok, gate} end)
    first = execute(cwd, opts, "return (await tools.gate({})).text;", 0)
    assert first.details.status == :yielded
    cell = first.details.cell_id
    assert_receive {:gate_started, gate_pid, call_id}, 10_000
    assert call_id =~ cell

    assert {:ok, slot} = KernelSupervisor.lookup({id, "code_mode"})
    assert {:error, message} = Sandbox.start_cell(slot, "return 2", nil, nil, 10_000)
    assert message =~ "already running"
    send(gate_pid, :release)
    final = CodeMode.wait_tool(cwd, opts).execute.("wait", %{"cell_id" => cell}, nil, nil)
    assert final.details.status == :ok
    assert final.details.cell_id == cell
    assert text(final) =~ "released"
    refute_received {:gate_started, _, _}

    again = CodeMode.wait_tool(cwd, opts).execute.("again", %{"cell_id" => cell}, nil, nil)
    assert again == final

    foreign = CodeMode.wait_tool(cwd, session_id: "foreign-#{id}")
    assert {:error, _} = foreign.execute.("foreign", %{"cell_id" => cell}, nil, nil)
  end

  test "bridged calls preserve catalog policy denials and execution approvals", %{
    cwd: cwd,
    opts: opts
  } do
    parent = self()
    cfg = ToolDisclosure.config(nil, profile: :code_mode)

    tuples =
      ToolRegistry.get_tool_tuples(cwd,
        tool_disclosure: cfg,
        enabled_only: ["bash", "write"],
        include_extensions: false,
        include_mcp: false,
        tool_policy: ToolPolicy.custom(deny: ["bash"], require_approval: ["write"]),
        approval_context: %{
          run_id: "code-mode-policy",
          session_id: opts[:session_id],
          approval_request_fun: fn request ->
            send(parent, {:approval, request.tool})
            {:ok, :denied}
          end
        }
      )

    catalog = Map.new(tuples, fn {name, tool, _source} -> {name, tool} end)
    refute Map.has_key?(catalog, "bash")

    resolver = fn name ->
      case Map.fetch(catalog, name) do
        {:ok, tool} -> {:ok, tool}
        :error -> {:error, "unknown or unavailable tool: #{name}"}
      end
    end

    target = Path.join(cwd, "approval-required.txt")

    code = """
    let denied;
    try { await tools.bash({command: "printf forbidden"}); }
    catch (error) { denied = String(error); }
    const write = await tools.write({path: #{Jason.encode!(target)}, content: "forbidden"});
    return {denied, write};
    """

    result = execute(cwd, Keyword.put(opts, :tool_resolver, resolver), code)
    assert result.details.status == :ok
    assert text(result) =~ "unknown or unavailable tool: bash"
    assert text(result) =~ "denied"
    assert_receive {:approval, "write"}
    refute File.exists?(target)
  end

  test "handoff pauses new bridged calls and re-attachment uses the current resolver", %{
    cwd: cwd,
    id: id,
    opts: opts
  } do
    parent = self()

    gate = %AgentTool{
      name: "gate",
      description: "Controlled handoff gate",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _args, _signal, _update ->
        send(parent, {:handoff_gate, self()})

        receive do
          :release -> %AgentToolResult{content: [%TextContent{text: "first"}]}
        end
      end
    }

    original = Keyword.put(opts, :tool_resolver, fn "gate" -> {:ok, gate} end)

    first =
      execute(cwd, original, "await tools.gate({}); return (await tools.current({})).text;", 0)

    assert_receive {:handoff_gate, gate_pid}, 10_000
    assert :ok = ToolResources.handoff(id, self())
    send(gate_pid, :release)

    current = %AgentTool{
      name: "current",
      description: "Current session catalog",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ ->
        %AgentToolResult{content: [%TextContent{text: "current catalog"}]}
      end
    }

    resumed = Keyword.put(opts, :tool_resolver, fn "current" -> {:ok, current} end)

    final =
      CodeMode.wait_tool(cwd, resumed).execute.(
        "wait",
        %{"cell_id" => first.details.cell_id},
        nil,
        nil
      )

    assert final.details.status == :ok
    assert text(final) =~ "current catalog"
  end

  test "abort cancels a yielded cell and its outstanding tool task", %{cwd: cwd, opts: opts} do
    parent = self()
    signal = AbortSignal.new()

    gate = %AgentTool{
      name: "gate",
      description: "Wait for cancellation",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _args, inner_signal, _update ->
        AbortSignal.subscribe(inner_signal)
        send(parent, {:waiting, self()})

        receive do
          {:lemon_abort, ^inner_signal, :abort} ->
            send(parent, :inner_aborted)
            %AgentToolResult{content: [%TextContent{text: "cancelled"}]}
        end
      end
    }

    opts = Keyword.put(opts, :tool_resolver, fn "gate" -> {:ok, gate} end)
    tool = CodeMode.tool(cwd, opts)

    first =
      tool.execute.(
        "start",
        %{"code" => "return await tools.gate({});", "yield_after" => 0},
        signal,
        nil
      )

    assert first.details.status == :yielded
    assert_receive {:waiting, pid}, 10_000
    monitor = Process.monitor(pid)
    AbortSignal.abort(signal)

    final =
      CodeMode.wait_tool(cwd, opts).execute.(
        "wait",
        %{"cell_id" => first.details.cell_id},
        nil,
        nil
      )

    assert final.details.status == :aborted
    assert_receive :inner_aborted
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}
  end

  defp execute(cwd, opts, code, yield_after \\ 30) do
    CodeMode.tool(cwd, opts).execute.(
      "cell",
      %{"code" => code, "yield_after" => yield_after},
      nil,
      nil
    )
  end

  defp text(%AgentToolResult{content: [%TextContent{text: text}]}), do: text
end
