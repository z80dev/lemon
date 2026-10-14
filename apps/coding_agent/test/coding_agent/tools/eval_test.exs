defmodule CodingAgent.Tools.EvalTest do
  # Real kernels (python3, bun, node) are spawned; run serially to keep the
  # loaded test machine from starving kernel startup.
  use ExUnit.Case, async: false

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Eval.{Kernel, KernelSupervisor}
  alias CodingAgent.Tools.Eval
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  @python System.find_executable("python3") || System.find_executable("python")
  @bun System.find_executable("bun")
  @node System.find_executable("node")

  setup %{tmp_dir: tmp_dir} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    session_id = "eval-test-#{System.unique_integer([:positive])}"
    on_exit(fn -> Process.exit(owner, :kill) end)

    %{
      cwd: tmp_dir,
      owner: owner,
      session_id: session_id,
      opts: [session_id: session_id, session_pid: owner]
    }
  end

  defp run(ctx, language, code, extra \\ []) do
    params =
      %{"language" => language, "code" => code, "timeout" => Keyword.get(extra, :timeout, 60)}
      |> maybe_put("reset", extra[:reset])

    tool_opts = Keyword.merge(ctx.opts, Keyword.get(extra, :opts, []))
    Eval.execute("call", params, extra[:signal], extra[:on_update], ctx.cwd, tool_opts)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text(%AgentToolResult{content: content}) do
    content |> Enum.map(fn %TextContent{text: text} -> text end) |> Enum.join("\n")
  end

  defp slot!(ctx, language) do
    {:ok, pid} = KernelSupervisor.lookup({ctx.session_id, language})
    pid
  end

  defp os_alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  describe "tool contract" do
    test "restricted policy profiles deny eval like bash" do
      for profile <- [:safe_mode, :subagent_restricted] do
        assert "eval" in CodingAgent.ToolPolicy.from_profile(profile).deny
      end
    end

    test "rejects invalid parameters before starting a kernel", ctx do
      for {params, message} <- [
            {%{"language" => "rb", "code" => "1"}, "language must be"},
            {%{"language" => "py", "code" => "  "}, "code must be"},
            {%{"language" => "py", "code" => "1", "timeout" => -1}, "timeout must be"},
            {%{"language" => "py", "code" => "1", "reset" => "yes"}, "reset must be"}
          ] do
        assert {:error, error} = Eval.execute("c", params, nil, nil, ctx.cwd, ctx.opts)
        assert error =~ message
      end

      assert KernelSupervisor.lookup({ctx.session_id, "py"}) == :error
    end

    test "names the missing runtime binary", ctx do
      opts = [opts: [eval_runtimes: %{"py" => "lemon-no-such-python-xyz"}]]
      assert {:error, message} = run(ctx, "py", "1", opts)
      assert message =~ "needs lemon-no-such-python-xyz on PATH"
    end

    test "an already-aborted signal does not start a kernel", ctx do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)
      result = run(ctx, "py", "1", signal: signal)
      assert result.is_error
      assert result.details.status == :aborted
      assert KernelSupervisor.lookup({ctx.session_id, "py"}) == :error
    end
  end

  describe "python kernel" do
    if !@python, do: @describetag(skip: "python3/python not on PATH")

    test "persists state across calls and displays only the trailing expression", ctx do
      result = run(ctx, "py", "import math, os\nx = 41\ndef double(n):\n    return n * 2")
      assert text(result) == "(no output)"

      assert %{language: "py", status: :ok, kernel_restarted: false, truncated: false} =
               result.details

      assert text(run(ctx, "py", "print('hi')\ndouble(x + 1) + math.floor(0.5)")) == "hi\n84"
      assert text(run(ctx, "py", "print('none')\nNone")) == "none\n"

      assert text(run(ctx, "py", "os.path.basename(os.getcwd())")) ==
               "'#{Path.basename(ctx.cwd)}'"
    end

    test "captures stdout, stderr and subprocess output without protocol confusion", ctx do
      code = ~S"""
      import json, os, sys
      print(json.dumps({"type": "result", "id": 1, "status": "ok", "display": "fake"}))
      print("\x1eLEMONEVAL:not-the-token:{\"type\": \"result\"}")
      sys.stdout.write("\n" * 300)
      print("to stderr", file=sys.stderr)
      os.system("echo from-subprocess")
      sys.stdout.write("no newline")
      "done"
      """

      result = run(ctx, "py", code)
      refute result.is_error
      output = text(result)
      assert output =~ ~s({"type": "result", "id": 1, "status": "ok", "display": "fake"})
      assert output =~ "LEMONEVAL:not-the-token:"
      assert output =~ "to stderr"
      assert output =~ "from-subprocess"
      assert output =~ ~r/no newline\n'done'$/

      assert text(run(ctx, "py", "1 + 1")) == "2"
    end

    test "reports errors with a user-code traceback and keeps state", ctx do
      run(ctx, "py", "kept = 'yes'")
      result = run(ctx, "py", "def boom():\n    raise ValueError('bad value')\nboom()")
      assert result.is_error
      assert result.details.status == :error
      output = text(result)
      assert output =~ ~s(File "<cell 2>", line 3)
      assert output =~ "ValueError: bad value"
      refute output =~ "python_kernel.py"

      assert text(run(ctx, "py", "def (")) =~ "SyntaxError"
      assert text(run(ctx, "py", "kept")) == "'yes'"
    end

    test "supports top-level await and streams output", ctx do
      test_pid = self()
      on_update = fn update -> send(test_pid, {:update, text(update)}) end

      code =
        "import asyncio\nprint('first', flush=True)\nawait asyncio.sleep(0)\nawait asyncio.sleep(0, result=42)"

      assert text(run(ctx, "py", code, on_update: on_update)) == "first\n42"
      assert_received {:update, "first" <> _}
    end

    test "timeout kills the kernel tree and the next call starts fresh", ctx do
      run(ctx, "py", "survivor = 1")
      os_pid = Kernel.os_pid(slot!(ctx, "py"))

      code =
        "import subprocess, time\nchild = subprocess.Popen(['sleep', '60'])\n" <>
          "print(child.pid, flush=True)\ntime.sleep(60)"

      result = run(ctx, "py", code, timeout: 0.5)
      assert result.is_error
      assert result.details.status == :timeout
      output = text(result)
      assert output =~ "timed out after 0.5s"
      assert output =~ "its state (variables, imports, definitions) was lost"
      [child_pid] = Regex.run(~r/^\d+/, output)

      assert_eventually(fn -> not os_alive?(os_pid) end, timeout: 5_000)
      assert_eventually(fn -> not os_alive?(String.to_integer(child_pid)) end, timeout: 5_000)

      result = run(ctx, "py", "'survivor' in globals()")
      assert result.details.kernel_restarted
      assert text(result) =~ "[Started a fresh Python kernel: the previous one ended (timed out)"
      assert text(result) =~ "False"
    end

    test "abort kills the running cell", ctx do
      test_pid = self()
      signal = AbortSignal.new()
      on_update = fn update -> send(test_pid, {:update, text(update)}) end

      task =
        Task.async(fn ->
          run(ctx, "py", "import time\nprint('started', flush=True)\ntime.sleep(60)",
            signal: signal,
            on_update: on_update
          )
        end)

      assert_receive {:update, "started" <> _}, 20_000
      AbortSignal.abort(signal)

      result = Task.await(task, 10_000)
      assert result.details.status == :aborted
      assert text(result) =~ "started"
      assert text(result) =~ "kernel was killed and its state was lost"
      assert run(ctx, "py", "1").details.kernel_restarted
    end

    test "reset discards only that language's state", ctx do
      run(ctx, "py", "y = 1")
      result = run(ctx, "py", "'y' in globals()", reset: true)
      assert result.details.kernel_restarted
      assert text(result) == "[Python kernel reset]\n\nFalse"
    end

    test "large output keeps the tail and spills the full output privately", ctx do
      result = run(ctx, "py", "for i in range(20000):\n    print(f'line {i:05d} ' + 'x' * 20)")
      refute result.is_error
      assert result.details.truncated
      path = result.details.full_output_path
      on_exit(fn -> File.rm(path) end)

      assert File.read!(path) =~ "line 00000 "
      assert Bitwise.band(File.stat!(path).mode, 0o077) == 0
      output = text(result)
      assert output =~ "line 19999 "
      refute output =~ "line 00000 "
      assert output =~ "[Full output saved to: #{path}"
      assert byte_size(output) < 60_000
    end

    test "sessions do not share kernels", ctx do
      run(ctx, "py", "secret = 1")
      other_owner = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(other_owner, :kill) end)
      other = %{ctx | opts: [session_id: ctx.session_id <> "-other", session_pid: other_owner]}

      result = run(other, "py", "secret")
      assert result.is_error
      assert text(result) =~ "NameError"
    end

    test "kernels die with the owning session", ctx do
      run(ctx, "py", "1")
      slot = slot!(ctx, "py")
      os_pid = Kernel.os_pid(slot)
      ref = Process.monitor(slot)

      Process.exit(ctx.owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^slot, _}, 5_000
      assert_eventually(fn -> not os_alive?(os_pid) end, timeout: 5_000)
      assert KernelSupervisor.lookup({ctx.session_id, "py"}) == :error
    end

    test "idle kernels are killed and the next call says so", ctx do
      opts = [opts: [eval_idle_timeout_ms: 200]]
      run(ctx, "py", "idle_var = 1", opts)
      os_pid = Kernel.os_pid(slot!(ctx, "py"))

      assert_eventually(fn -> not os_alive?(os_pid) end, timeout: 5_000)

      result = run(ctx, "py", "'idle_var' in globals()", opts)
      assert text(result) =~ "previous one ended (idle timeout)"
      assert text(result) =~ "False"
    end

    test "a kernel that exits reports lost state", ctx do
      result = run(ctx, "py", "import os\nprint('bye', flush=True)\nos._exit(3)")
      assert result.details.status == :error
      assert text(result) =~ "bye"
      assert text(result) =~ "kernel exited (status 3)"
      assert text(run(ctx, "py", "1")) =~ "previous one ended (exited)"
    end
  end

  describe "javascript kernel (bun)" do
    if !@bun, do: @describetag(skip: "bun not on PATH")

    test "persists declarations across cells and allows redeclaration", ctx do
      code =
        "const x = 41\nlet count = 0\nfunction inc() { count++ }\n" <>
          "class Box { constructor(v) { this.v = v } }"

      assert text(run(ctx, "js", code)) == "(no output)"
      assert text(run(ctx, "js", "inc(); inc()\nnew Box(x + count).v")) == "43"
      assert text(run(ctx, "js", "const x = 1; x")) == "1"
      assert text(run(ctx, "js", "typeof Bun")) == "'object'"
    end

    test "supports top-level await, imports and require from the cwd", ctx do
      File.write!(Path.join(ctx.cwd, "helper.js"), "module.exports = { answer: 42 }\n")

      code = """
      import path from "node:path"
      const { answer } = require("./helper.js")
      const waited = await new Promise((resolve) => setTimeout(() => resolve(answer), 1))
      path.basename(process.cwd()) + ":" + waited
      """

      assert text(run(ctx, "js", code)) == "'#{Path.basename(ctx.cwd)}:42'"
    end

    test "captures console and stdout writes without protocol confusion", ctx do
      code = ~S"""
      console.log(JSON.stringify({ type: "result", id: 1, status: "ok", display: "fake" }))
      console.error("to stderr")
      process.stdout.write("\x1eLEMONEVAL:not-the-token:{}\n" + "\n".repeat(200) + "partial")
      ;[1, 2, 3].map((n) => n * 2)
      """

      result = run(ctx, "js", code)
      refute result.is_error
      output = text(result)
      assert output =~ ~s({"type":"result","id":1,"status":"ok","display":"fake"})
      assert output =~ "to stderr"
      assert output =~ "LEMONEVAL:not-the-token:{}"
      assert output =~ ~r/partial\n\[ 2, 4, 6 \]$/
    end

    test "reports errors with the cell stack", ctx do
      result = run(ctx, "js", "function boom() { throw new Error('bad value') }\nboom()")
      assert result.details.status == :error
      assert text(result) =~ "Error: bad value"
      assert text(result) =~ "cell-1.js"
      refute text(result) =~ "js_kernel.js"
    end

    test "timeout kills a synchronous loop; reset leaves the python kernel alone", ctx do
      if @python, do: run(ctx, "py", "shared = 'py'")
      run(ctx, "js", "const kept = 1")
      assert run(ctx, "js", "while (true) {}", timeout: 0.5).details.status == :timeout

      result = run(ctx, "js", "typeof kept")
      assert result.details.kernel_restarted
      assert text(result) =~ "'undefined'"

      run(ctx, "js", "1", reset: true)
      if @python, do: assert(text(run(ctx, "py", "shared")) == "'py'")
    end
  end

  describe "javascript kernel (node)" do
    if !@node, do: @describetag(skip: "node not on PATH")

    test "persists state, awaits and displays under node", ctx do
      opts = [opts: [eval_runtimes: %{"js" => "node"}]]

      assert text(run(ctx, "js", "let total = 40\nconst add = (n) => total += n", opts)) ==
               "(no output)"

      assert text(run(ctx, "js", "await Promise.resolve(add(2))", opts)) == "42"
      assert text(run(ctx, "js", "typeof Bun + ' ' + total", opts)) == "'undefined 42'"
    end
  end
end
