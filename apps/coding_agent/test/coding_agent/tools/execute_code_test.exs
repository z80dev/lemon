defmodule CodingAgent.Tools.ExecuteCodeSchemaTest do
  @moduledoc """
  Everything about `execute_code` that does not need a python3 interpreter:
  the tool schema, the shim template, and the two "cannot run" paths.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.ExecuteCode
  alias CodingAgent.Tools.ExecuteCode.{Config, PythonShim}

  @moduletag :tmp_dir

  describe "tool/2 schema" do
    test "names, labels, required script, and the additive reset parameter", %{tmp_dir: cwd} do
      tool = ExecuteCode.tool(cwd, enabled_opts())

      assert tool.name == "execute_code"
      assert tool.label == "Execute Code"
      assert tool.parameters["required"] == ["script"]

      assert Map.keys(tool.parameters["properties"]) |> Enum.sort() ==
               ["reset", "script", "timeout_ms"]

      assert tool.parameters["properties"]["script"]["type"] == "string"
      assert tool.parameters["properties"]["timeout_ms"]["type"] == "integer"
      assert tool.parameters["properties"]["reset"]["type"] == "boolean"
      assert tool.parameters["properties"]["reset"]["default"] == false
    end

    test "the description lists every enabled helper and the limits", %{tmp_dir: cwd} do
      tool = ExecuteCode.tool(cwd, enabled_opts(%{timeout_ms: 45_000, max_rpc_calls: 9}))

      for name <- Config.allowlist(), do: assert(tool.description =~ "#{name}(")
      assert tool.description =~ "45000 ms wall time"
      assert tool.description =~ "9 tool calls"
      assert tool.description =~ "only the text() blocks are the result"
      assert tool.description =~ "offset by 1"
    end

    test "the description states the resolved kernel mode", %{tmp_dir: cwd} do
      per_call = ExecuteCode.tool(cwd, enabled_opts())

      assert per_call.description =~ "Kernel mode: per_call"
      refute per_call.description =~ "Kernel mode: session"

      session = ExecuteCode.tool(cwd, enabled_opts(%{kernel_mode: "session"}))

      assert session.description =~ "Kernel mode: session"
      assert session.description =~ "reset=true"
    end

    test "a narrowed allowlist omits the other helpers", %{tmp_dir: cwd} do
      tool = ExecuteCode.tool(cwd, enabled_opts(%{tools: ["read"]}))

      assert tool.description =~ "read(path"
      refute tool.description =~ "grep("
      refute tool.description =~ "find("
      refute tool.description =~ "ls("
      refute tool.description =~ "webfetch("
    end

    test "two builds with the same opts are byte-identical (prompt caching)", %{tmp_dir: cwd} do
      opts = enabled_opts()
      first = ExecuteCode.tool(cwd, opts)
      second = ExecuteCode.tool(cwd, opts)

      assert first.description == second.description
      assert first.parameters == second.parameters
    end
  end

  describe "enabled?/2" do
    test "defaults to false and follows the config", %{tmp_dir: cwd} do
      refute ExecuteCode.enabled?(cwd, [])
      refute ExecuteCode.enabled?(cwd, settings_manager: %{tools: %{execute_code: %{}}})
      assert ExecuteCode.enabled?(cwd, enabled_opts())
    end
  end

  describe "execute/6 refusals" do
    test "a disabled tool refuses even if it is somehow called", %{tmp_dir: cwd} do
      assert {:error, message} =
               ExecuteCode.execute(
                 "call-1",
                 %{"script" => "print(1)"},
                 nil,
                 nil,
                 cwd,
                 settings_manager: %{tools: %{execute_code: %{enabled: false}}}
               )

      assert message =~ "execute_code is disabled"
    end

    test "a missing script parameter is reported", %{tmp_dir: cwd} do
      assert {:error, "Missing required parameter: script"} =
               ExecuteCode.execute("call-1", %{}, nil, nil, cwd, enabled_opts())

      assert {:error, "Missing required parameter: script"} =
               ExecuteCode.execute("call-1", %{"script" => ""}, nil, nil, cwd, enabled_opts())
    end

    test "a non-boolean reset parameter is rejected before anything runs", %{tmp_dir: cwd} do
      for value <- ["true", 1, [], %{}] do
        assert {:error, "reset must be a boolean"} =
                 ExecuteCode.execute(
                   "call-1",
                   %{"script" => "print(1)", "reset" => value},
                   nil,
                   nil,
                   cwd,
                   enabled_opts()
                 )
      end
    end

    test "a configured python_path that does not exist names the path", %{tmp_dir: cwd} do
      opts = enabled_opts(%{python_path: "/nonexistent/python3"})

      assert {:error, message} =
               ExecuteCode.execute("call-1", %{"script" => "print(1)"}, nil, nil, cwd, opts)

      assert message =~ "configured execute_code python_path not found: /nonexistent/python3"
    end

    test "a host without python3 gets a teachable error", %{tmp_dir: cwd} do
      opts = Keyword.put(enabled_opts(), :python_finder, fn _ -> nil end)

      assert {:error, message} =
               ExecuteCode.execute("call-1", %{"script" => "print(1)"}, nil, nil, cwd, opts)

      assert message =~ "python3 was not found on this host"
      assert message =~ "python_path"
    end

    test "an already-aborted signal short-circuits before any workspace is built", %{tmp_dir: cwd} do
      signal = LemonAgent.AbortSignal.new()
      :ok = LemonAgent.AbortSignal.abort(signal)

      opts =
        Keyword.put(enabled_opts(), :script_runner, fn _c, _cwd, _o ->
          flunk("the script must not run once the signal is aborted")
        end)

      result = ExecuteCode.execute("call-1", %{"script" => "print(1)"}, signal, nil, cwd, opts)

      assert [%LemonAi.Types.TextContent{text: "Script cancelled."}] = result.content
    end
  end

  describe "PythonShim" do
    test "the prelude defines only the enabled stubs" do
      prelude = PythonShim.render_prelude(["read"])

      assert prelude =~ "def read(path, offset=None, limit=None):"
      refute prelude =~ "def grep("
      refute prelude =~ "def ls("
      assert prelude =~ "class ToolError(Exception):"
    end

    test "the persistent module starts without bridge authority" do
      module = PythonShim.render_module(["read"])

      assert module =~ "def _configure(rpc_dir, token, budget=None, generation=None):"
      assert module =~ "lemon_tools is not configured for this cell"
      refute module =~ "_configure(\""
      assert module =~ "_BRIDGE = None"
    end

    test "the result channels are always present, budget baked in" do
      module = PythonShim.render_module(["read"], 2_048)

      assert module =~ "_DEFAULT_TEXT_BUDGET = 2048"
      assert module =~ "def text(s):"
      assert module =~ "def notify(msg):"
      assert module =~ "def batch(calls):"
      assert module =~ "threading.Lock()"

      # The default budget matches Config's pinned default.
      assert PythonShim.render_module([]) =~ "_DEFAULT_TEXT_BUDGET = 65536"
    end

    test "a configured prelude embeds its rpc dir and token exactly once, json-escaped" do
      token = "token-0123"
      prelude = PythonShim.render_prelude("/tmp/it's here", token, Config.allowlist(), 2_048)

      assert prelude =~ ~s|_configure("/tmp/it's here", "token-0123", 2048)|
      assert length(String.split(prelude, "/tmp/it's here")) == 2
      assert length(String.split(prelude, token)) == 2
    end

    test "stubs are emitted in a fixed order regardless of config order" do
      a = PythonShim.render_prelude(["webfetch", "read", "grep"])
      b = PythonShim.render_prelude(["grep", "webfetch", "read"])

      assert a == b
      assert index_of(a, "def read(") < index_of(a, "def grep(")
      assert index_of(a, "def grep(") < index_of(a, "def webfetch(")
    end

    test "the rendered shim rotates bridge configuration for each call", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "lemon_tools.py"), PythonShim.render_prelude(["read"]))

      # Every _configure installs a fresh bridge: credentials rotate and the
      # request-id space restarts at 1, because ids only need uniqueness
      # inside one cell's rpc directory.
      script = """
      import json, os
      import lemon_tools

      requests = []
      for rpc_dir, token in (("rpc-1", "first-token"), ("rpc-2", "second-token")):
          os.mkdir(rpc_dir)
          with open(os.path.join(rpc_dir, "res-1.json"), "w") as response:
              json.dump({"id": 1, "ok": True, "content": ""}, response)

          lemon_tools._configure(rpc_dir, token)
          lemon_tools.read("ignored")

          with open(os.path.join(rpc_dir, "req-1.json")) as request:
              requests.append(json.load(request))

      print(json.dumps(requests))
      """

      {output, 0} = System.cmd("python3", ["-c", script], cd: tmp_dir)

      assert [
               %{"id" => 1, "token" => "first-token", "tool" => "read"},
               %{"id" => 1, "token" => "second-token", "tool" => "read"}
             ] = Jason.decode!(output)
    end

    test "the import line only imports enabled tool names plus the channels" do
      assert PythonShim.import_line(["read", "ls"]) ==
               "from lemon_tools import ToolError, read, ls, text, notify, batch"

      assert PythonShim.import_line(Config.allowlist()) ==
               "from lemon_tools import ToolError, read, grep, find, ls, webfetch, text, notify, batch"
    end

    test "render_script adds exactly one line" do
      script = "print(1)\nprint(2)\n"
      rendered = PythonShim.render_script(script)

      assert length(String.split(rendered, "\n")) == length(String.split(script, "\n")) + 1
      assert String.starts_with?(rendered, "from lemon_tools import ")
      assert String.ends_with?(rendered, script)
    end
  end

  defp enabled_opts(overrides \\ %{}) do
    [settings_manager: %{tools: %{execute_code: Map.merge(%{enabled: true}, overrides)}}]
  end

  defp index_of(haystack, needle) do
    {index, _} = :binary.match(haystack, needle)
    index
  end
end

defmodule CodingAgent.Tools.ExecuteCodeTest do
  @moduledoc """
  End-to-end `execute_code` runs against a real python3 interpreter.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.BashExecutor
  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.ExecuteCode
  alias CodingAgent.Tools.ExecuteCode.{PythonShim, Rpc}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  # The whole module needs python3; there is nothing meaningful to assert about
  # a real run without it. The schema and missing-runtime paths live in
  # `CodingAgent.Tools.ExecuteCodeSchemaTest` above and always run.
  if System.find_executable("python3") == nil do
    @moduletag :skip
  end

  describe "helper round trips" do
    test "read", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "alpha\nbeta\n")

      result = run(cwd, ~s|print(read("f.txt"))|)

      assert text(result) =~ "alpha"
      assert text(result) =~ "beta"
      assert result.details.rpc_calls == 1
      assert result.details.rpc_tools == ["read"]
      assert result.details.exit_code == 0
    end

    test "grep, with the counting done script-side", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "hay.txt"), "needle one\nnothing\nneedle two\nneedle three\n")

      result = run(cwd, ~s|print(len([l for l in grep("needle").splitlines() if "needle" in l]))|)

      assert text(result) =~ "3"
      assert result.details.rpc_tools == ["grep"]
    end

    test "find", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), "")
      File.write!(Path.join(cwd, "b.ex"), "")

      result = run(cwd, ~s|print(find("*.ex"))|)

      assert text(result) =~ "a.ex"
      assert text(result) =~ "b.ex"
      assert result.details.rpc_tools == ["find"]
    end

    test "ls", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "visible.txt"), "")

      result = run(cwd, ~s|print(ls())|)

      assert text(result) =~ "visible.txt"
      assert result.details.rpc_tools == ["ls"]
    end

    test "several calls in one script are all counted", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "one.txt"), "1")
      File.write!(Path.join(cwd, "two.txt"), "2")

      script = """
      total = 0
      for name in ("one.txt", "two.txt"):
          total += len(read(name))
      print("done")
      """

      result = run(cwd, script)

      assert text(result) =~ "done"
      assert result.details.rpc_calls == 2
      assert result.details.rpc_bytes > 0
    end
  end

  describe "trust propagation" do
    test "a run that used webfetch is untrusted and wrapped", %{tmp_dir: cwd} do
      opts =
        opts(%{},
          execute_code_tool_overrides: %{
            "webfetch" => stub_tool("webfetch", "PAGE BODY FROM THE INTERNET")
          }
        )

      result = run(cwd, ~s|print(webfetch("https://example.com"))|, opts)

      assert result.trust == :untrusted
      assert text(result) =~ "PAGE BODY FROM THE INTERNET"
      assert text(result) =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
      assert text(result) =~ "SECURITY NOTICE"
      assert result.details.rpc_tools == ["webfetch"]
    end

    test "a run that never touched the network stays trusted and unwrapped", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "local only")

      result = run(cwd, ~s|print(read("f.txt"))|)

      assert result.trust == :trusted
      refute text(result) =~ "<<<EXTERNAL_UNTRUSTED_CONTENT>>>"
    end
  end

  describe "error surfaces" do
    test "a failing helper raises ToolError the script can catch", %{tmp_dir: cwd} do
      script = """
      try:
          read("missing.txt")
          print("NO ERROR")
      except Exception as e:
          print(type(e).__name__)
      """

      assert text(run(cwd, script)) =~ "ToolError"
    end

    test "policy denial reaches the script as a ToolError message", %{tmp_dir: cwd} do
      script = """
      try:
          grep("x")
          print("NO ERROR")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{}, tool_policy: ToolPolicy.custom(deny: ["grep"])))

      assert text(result) =~ "deny list"
      assert result.details.rpc_denied == 1
    end

    test "a denied approval reaches the script and counts as denied", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "secret")

      script = """
      try:
          read("f.txt")
          print("NO ERROR")
      except Exception as e:
          print(str(e))
      """

      result =
        run(
          cwd,
          script,
          opts(%{},
            tool_policy: ToolPolicy.custom(require_approval: ["read"]),
            approval_context: %{
              timeout_ms: 30_000,
              approval_request_fun: fn _ -> {:ok, :denied} end
            }
          )
        )

      assert text(result) =~ "approval denied for 'read'"
      assert result.details.rpc_denied == 1
    end

    test "an approved approval lets the call through", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "approved content")

      result =
        run(
          cwd,
          ~s|print(read("f.txt"))|,
          opts(%{},
            tool_policy: ToolPolicy.custom(require_approval: ["read"]),
            approval_context: %{
              timeout_ms: 30_000,
              approval_request_fun: fn _ -> {:ok, :approved, :session} end
            }
          )
        )

      assert text(result) =~ "approved content"
      assert result.details.rpc_denied == 0
    end

    test "a nonzero exit is reported", %{tmp_dir: cwd} do
      result = run(cwd, "import sys\nsys.exit(3)")

      assert text(result) =~ "Script exited with code 3"
      assert result.details.exit_code == 3
    end

    test "a python traceback arrives through merged stderr", %{tmp_dir: cwd} do
      result = run(cwd, "this is not python(")

      assert text(result) =~ "SyntaxError"
      assert result.details.exit_code != 0
    end

    test "an empty successful run is teachable rather than blank", %{tmp_dir: cwd} do
      result = run(cwd, "x = 1")

      assert text(result) == "(script produced no output)"
      assert result.details.exit_code == 0
    end
  end

  describe "context-size proof" do
    test "a large intermediate result never reaches the tool result", %{tmp_dir: cwd} do
      needle = "SUPERSECRETNEEDLEPAYLOAD"
      line = needle <> String.duplicate("x", 80) <> "\n"
      File.write!(Path.join(cwd, "big.txt"), String.duplicate(line, 2_000))

      script = """
      hits = grep("#{needle}", max_results=2000)
      print(str(len([l for l in hits.splitlines() if "#{needle}" in l])))
      """

      result = run(cwd, script)

      # `details` is never sent to the model (see `LemonAgent.Types.AgentToolResult`),
      # so the megabyte that travelled over the RPC files is visible here for the
      # test but cost the transcript nothing.
      assert result.details.rpc_bytes > 50_000
      assert byte_size(text(result)) < 200
      refute text(result) =~ needle
    end
  end

  describe "runaway caps" do
    test "wall time", %{tmp_dir: cwd} do
      started = System.monotonic_time(:millisecond)
      result = run(cwd, "while True:\n    pass\n", opts(%{timeout_ms: 2_000}))
      elapsed = System.monotonic_time(:millisecond) - started

      assert text(result) =~ "timed out"
      assert elapsed < 10_000
    end

    test "the per-run timeout_ms parameter is clamped to the configured maximum", %{tmp_dir: cwd} do
      result =
        ExecuteCode.execute(
          "call-1",
          %{"script" => "while True:\n    pass\n", "timeout_ms" => 60_000},
          nil,
          nil,
          cwd,
          opts(%{timeout_ms: 2_000})
        )

      assert text(result) =~ "Script timed out after 2000ms."
    end

    test "call cap", %{tmp_dir: cwd} do
      script = """
      ok = 0
      failed = 0
      for _ in range(4):
          try:
              ls()
              ok += 1
          except Exception:
              failed += 1
      print("%d/%d" % (ok, failed))
      """

      result = run(cwd, script, opts(%{max_rpc_calls: 2}))

      assert text(result) =~ "2/2"
      assert result.details.rpc_calls == 2
      assert result.details.rpc_errors == 2
    end

    test "rpc byte budget", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "kb.txt"), String.duplicate("a", 1_024))

      script = """
      try:
          read("kb.txt")
          print("NO ERROR")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{max_rpc_result_bytes: 64}))

      assert text(result) =~ "byte budget exceeded"
      assert result.details.rpc_errors == 1
    end

    test "stdout cap spills to a file", %{tmp_dir: cwd} do
      script = ~s|print("y" * 100000)|

      result = run(cwd, script, opts(%{max_output_bytes: 1_000}))

      assert text(result) =~ "[Full output saved to:"
      assert byte_size(text(result)) < 5_000
      assert result.details.truncated == true

      path = result.details.full_output_path
      assert File.exists?(path)
      assert File.stat!(path).size > 50_000
    end
  end

  describe "reset parameter in per-call mode" do
    test "a boolean reset runs unchanged and keeps the per-call detail shape", %{tmp_dir: cwd} do
      for reset <- [true, false] do
        result =
          ExecuteCode.execute(
            "call-1",
            %{"script" => "print(21 * 2)", "reset" => reset},
            nil,
            nil,
            cwd,
            opts()
          )

        assert text(result) =~ "42"
        assert result.details.exit_code == 0

        # The persistent-kernel detail fields land with the session path; a
        # per-call result keeps exactly its existing shape.
        assert Map.keys(result.details) |> Enum.sort() == [
                 :exit_code,
                 :rpc_bytes,
                 :rpc_calls,
                 :rpc_denied,
                 :rpc_errors,
                 :rpc_tools,
                 :truncated
               ]
      end
    end
  end

  describe "lifecycle" do
    test "an abort during a sleeping script cancels it promptly", %{tmp_dir: cwd} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          ExecuteCode.execute(
            "call-1",
            %{"script" => "import time\ntime.sleep(10)\n"},
            signal,
            nil,
            cwd,
            opts()
          )
        end)

      Process.sleep(300)
      :ok = AbortSignal.abort(signal)

      result = Task.await(task, 15_000)
      assert text(result) =~ "Script cancelled."
    end

    test "the workspace is removed after success and after a timeout", %{tmp_dir: cwd} do
      {result, base} = run_capturing_base(cwd, ~s|print("ok")|, opts())
      assert text(result) =~ "ok"
      refute File.exists?(base)

      {timed_out, timeout_base} =
        run_capturing_base(cwd, "while True:\n    pass\n", opts(%{timeout_ms: 2_000}))

      assert text(timed_out) =~ "timed out"
      refute File.exists?(timeout_base)
      # Workspaces live beneath the application-private root now; nothing may
      # leak there. (Legacy pre-private-root dirs directly under the system
      # temp dir are outside this assertion.)
      {:ok, private_root} = CodingAgent.PrivateTmp.root()
      assert Path.wildcard(Path.join(private_root, "lemon-exec-code*")) == []
    end

    test "every workspace object is private at creation, before the script runs", %{tmp_dir: cwd} do
      test = self()

      runner = fn command, runner_cwd, runner_opts ->
        # The workspace exists only until the run ends, so capture the modes
        # here, inside the runner — not after execute/6 has cleaned up.
        base = command_base(command)
        shim = File.read!(Path.join(base, "lemon_tools.py"))

        [_, rpc_dir, _token, _budget] =
          Regex.run(~r/_configure\("([^"]+)", "([^"]+)"(?:, (\d+))?\)/, shim)

        modes = %{
          base: mode(base),
          rpc: mode(rpc_dir),
          lemon_tools: mode(Path.join(base, "lemon_tools.py")),
          script: mode(Path.join(base, "script.py"))
        }

        send(test, {:modes, modes})
        BashExecutor.execute(command, runner_cwd, runner_opts)
      end

      result = run(cwd, ~s|print("ok")|, opts(%{}, script_runner: runner))
      assert text(result) =~ "ok"

      assert_received {:modes, modes}
      assert modes == %{base: 0o700, rpc: 0o700, lemon_tools: 0o600, script: 0o600}
    end

    test "each run uses a fresh token that does not reach its result or details", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "private bridge authority stays private")
      test = self()

      runner = fn command, runner_cwd, runner_opts ->
        base = command_base(command)
        shim = File.read!(Path.join(base, "lemon_tools.py"))
        send(test, {:shim, shim})
        BashExecutor.execute(command, runner_cwd, runner_opts)
      end

      first = run(cwd, ~s|print(read("f.txt"))|, opts(%{}, script_runner: runner))
      assert_received {:shim, first_shim}

      second = run(cwd, ~s|print(read("f.txt"))|, opts(%{}, script_runner: runner))
      assert_received {:shim, second_shim}

      [_, first_rpc_dir, first_token] =
        Regex.run(~r/_configure\("([^"]+)", "([^"]+)"(?:, \d+)?\)/, first_shim)

      [_, second_rpc_dir, second_token] =
        Regex.run(~r/_configure\("([^"]+)", "([^"]+)"(?:, \d+)?\)/, second_shim)

      assert first_token =~ ~r/^[A-Za-z0-9_-]{43}$/
      assert second_token =~ ~r/^[A-Za-z0-9_-]{43}$/
      refute first_token == second_token

      for {result, rpc_dir, token} <- [
            {first, first_rpc_dir, first_token},
            {second, second_rpc_dir, second_token}
          ] do
        assert text(result) =~ "private bridge authority stays private"
        refute text(result) =~ token
        refute text(result) =~ rpc_dir
        refute inspect(result.details) =~ token
        refute inspect(result.details) =~ rpc_dir
      end
    end

    test "concurrent runs in separate workspaces do not cross-talk", %{tmp_dir: cwd} do
      a = Path.join(cwd, "a")
      b = Path.join(cwd, "b")
      File.mkdir_p!(a)
      File.mkdir_p!(b)
      File.write!(Path.join(a, "marker.txt"), "AAA-WORKSPACE")
      File.write!(Path.join(b, "marker.txt"), "BBB-WORKSPACE")

      script = """
      import time
      out = []
      for _ in range(3):
          out.append(read("marker.txt"))
          time.sleep(0.05)
      print("|".join(str(len(o)) for o in out))
      print(out[0])
      """

      [ra, rb] =
        [a, b]
        |> Enum.map(fn dir -> Task.async(fn -> run(dir, script) end) end)
        |> Task.await_many(60_000)

      assert text(ra) =~ "AAA-WORKSPACE"
      refute text(ra) =~ "BBB-WORKSPACE"
      assert text(rb) =~ "BBB-WORKSPACE"
      refute text(rb) =~ "AAA-WORKSPACE"
      assert ra.details.rpc_calls == 3
      assert rb.details.rpc_calls == 3
    end
  end

  describe "backend portability" do
    test "the script survives a container-style relocation of cwd and environment", %{
      tmp_dir: cwd
    } do
      File.write!(Path.join(cwd, "f.txt"), "portable content")
      test = self()

      runner = fn command, _runner_cwd, runner_opts ->
        send(test, {:command, command})

        # A docker/ssh backend would place the workspace somewhere else and run
        # it with its own cwd and environment. Only the absolute rpc dir baked
        # into the shim should matter.
        BashExecutor.execute(
          String.replace(command, "exec ", "exec env -i PATH=/usr/bin:/bin HOME=/tmp ",
            global: false
          ),
          System.tmp_dir!(),
          runner_opts
        )
      end

      # `read` resolves relative to the tool's cwd, not the shell's, so the
      # relocated run still reads the project file.
      result = run(cwd, ~s|print(read("f.txt"))|, opts(%{}, script_runner: runner))

      assert text(result) =~ "portable content"

      assert_received {:command, command}
      base = command_base(command)

      # Every path the command mentions lives inside the one workspace dir.
      for path <- Regex.scan(~r/'([^']+)'/, command, capture: :all_but_first) do
        assert String.starts_with?(hd(path), base) or File.exists?(hd(path))
      end
    end
  end

  describe "text() result channel" do
    test "blocks return in flush order with stdout demoted to a labeled diagnostics tail", %{
      tmp_dir: cwd
    } do
      script = """
      print("DeprecationWarning: incidental library noise")
      text("deliberate answer: 42")
      text("second deliberate line")
      print("more incidental output")
      """

      result = run(cwd, script)
      body = text(result)

      assert result.details.exit_code == 0
      assert body =~ "Script result (text()):"

      # The blocks are the labeled result, verbatim, in order.
      assert index_of(body, "deliberate answer: 42") < index_of(body, "second deliberate line")
      assert index_of(body, "second deliberate line") < index_of(body, "Diagnostics")

      # Stdout never impersonates the result: it only appears after the
      # diagnostics label.
      diagnostics_at = index_of(body, "Diagnostics (stdout/stderr, not the result):")
      assert diagnostics_at < index_of(body, "DeprecationWarning")
      assert diagnostics_at < index_of(body, "more incidental output")
    end

    test "an over-budget text() call raises ToolError and the flushed partial blocks still return",
         %{tmp_dir: cwd} do
      # The budget charges the encoded frame ({"n": 1, "text": ...} envelope
      # included), so 10 digits fit a cap of 64 and a second block does not.
      script = """
      text("0123456789")
      try:
          text("X" * 40)
          print("NO ERROR")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{max_text_bytes: 64}))
      body = text(result)
      # The refusing call surfaces like every other limit violation, in the
      # diagnostics tail...
      assert body =~ "text() byte budget exceeded"
      assert body =~ "cap 64"
      # ...while every block flushed before the refusal is still the result.
      assert index_of(body, "0123456789") < index_of(body, "Diagnostics")
    end

    test "the budget charges the JSON-encoded frame, not the raw string", %{
      tmp_dir: cwd
    } do
      # A NUL-heavy string roughly six-folds under JSON escaping: 8000 raw
      # bytes encode to ~48 KiB. Under raw-string accounting the second call
      # (4000 more raw bytes) would still fit the 64 KiB cap; charging the
      # encoded frame refuses it — on the script side, consistently.
      script = """
      text("\\0" * 8000)
      print("flushed one")
      try:
          text("\\0" * 4000)
          print("SECOND BLOCK WRITTEN")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{max_text_bytes: 65_536}))
      body = text(result)

      refute body =~ "SECOND BLOCK WRITTEN"
      assert body =~ "text() byte budget exceeded"
      assert body =~ "48020 bytes accumulated"
      # The in-budget first block is delivered in full, NULs included: the
      # 8000 raw NULs sit in the result section, ahead of the diagnostics
      # tail where the (printed) marker lines live.
      assert index_of(body, String.duplicate("\0", 8_000)) < index_of(body, "Diagnostics")
      assert index_of(body, "flushed one") > index_of(body, "Diagnostics")
    end

    test "a control-char string whose encoding exceeds the cap is refused, never silently dropped",
         %{tmp_dir: cwd} do
      # 11000 NULs are 11 KiB raw (well under the 64 KiB cap) but encode to
      # ~66 KiB on disk. Both sides must agree: the shim refuses it, so no
      # in-budget block is dropped later by the host's file-size check.
      script = """
      try:
          text("\\0" * 11000)
          print("BLOCK WRITTEN")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{max_text_bytes: 65_536}))
      body = text(result)

      refute body =~ "BLOCK WRITTEN"
      refute body =~ "Script result (text()):"
      assert body =~ "text() byte budget exceeded"
      assert result.details.exit_code == 0
    end

    test "shim-charged bytes equal host-charged bytes over a nasty-string corpus",
         %{tmp_dir: cwd} do
      rpc_dir = Path.join(cwd, "equiv-rpc")
      File.mkdir_p!(rpc_dir)
      token = String.duplicate("e", 43)

      # Stage the real shim plus a driver that configures the bridge and
      # emits the corpus through text(), reporting (a) the shim-side charged
      # total and (b) the sanitized strings it actually delivered.
      File.write!(Path.join(cwd, "lemon_tools.py"), PythonShim.render_module([], 65_536))

      driver = """
      import json, lemon_tools

      lemon_tools._configure(#{Jason.encode!(rpc_dir)}, #{Jason.encode!(token)}, None, "cell-1")

      corpus = [
          "",
          "plain ascii",
          "\\0" * 100,
          "".join(chr(i) for i in range(1, 128)),
          "emoji: \\U0001F600\\U0001F680",
          "bmp: \\u00e9\\u4e2d\\u05d0",
          "lone low surrogate: \\ud800",
          "lone high surrogate: \\ud83d",
          "mixed pairs and loners: \\ud83d\\ude00\\ud800\\udfff",
          "tab\\tnewline\\nquote\\"backslash\\\\",
          "\\u2028\\u2029line separators",
          "x" * 1000,
      ]
      delivered = []
      for s in corpus:
          try:
              lemon_tools.text(s)
              delivered.append(s)
          except Exception:
              print("UNEXPECTED REFUSAL")

      # The big block cannot fit the remaining budget: the shim must refuse
      # it — delivered iff charged, on the script side too.
      try:
          lemon_tools.text("Y" * 64000)
          delivered.append("big")
          print("BIG WRITTEN")
      except Exception:
          print("BIG REFUSED")

      print("RESULT " + json.dumps({
          "charged": lemon_tools._BRIDGE.text_bytes,
          "delivered": [lemon_tools._json_safe(s) for s in delivered],
      }))
      """

      File.write!(Path.join(cwd, "driver.py"), driver)

      {out, 0} = System.cmd(System.find_executable("python3"), ["driver.py"], cd: cwd)

      assert out =~ "BIG REFUSED"
      refute out =~ "BIG WRITTEN"
      refute out =~ "UNEXPECTED REFUSAL"

      %{"charged" => charged, "delivered" => delivered} =
        out
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "RESULT "))
        |> String.trim_leading("RESULT ")
        |> Jason.decode!()

      # Host side: read the same frames with the real reader.
      blocks = Rpc.read_text_blocks(rpc_dir, max_text_bytes: 65_536)

      host_charged =
        rpc_dir
        |> Path.join("text-*.json")
        |> Path.wildcard()
        |> Enum.map(&File.read!/1)
        |> Enum.map(&byte_size/1)
        |> Enum.sum()

      # Bidirectional equivalence: what the shim charged, the host charged;
      # what the shim delivered, the host delivers — sanitized lone
      # surrogates included, never silently dropped.
      assert host_charged == charged
      assert blocks == delivered
      assert length(blocks) == 12
    end

    test "blocks flushed before a wall-clock kill survive into the result", %{tmp_dir: cwd} do
      script = """
      text("partial answer survives the kill")
      while True:
          pass
      """

      result = run(cwd, script, opts(%{timeout_ms: 2_000}))
      body = text(result)

      assert body =~ "Script timed out after 2000ms."

      assert index_of(body, "Script timed out after 2000ms.") <
               index_of(body, "partial answer survives the kill")

      assert index_of(body, "partial answer survives the kill") < index_of(body, "Diagnostics")
    end

    test "a script that never calls text() keeps the historic stdout-only result", %{tmp_dir: cwd} do
      result = run(cwd, ~s|print("plain output")|)

      assert text(result) == "plain output\n"
      assert result.details.exit_code == 0
    end
  end

  describe "notify() streaming" do
    test "on_update receives notify() messages in order during the run", %{tmp_dir: cwd} do
      test_pid = self()

      on_update = fn %AgentToolResult{content: [%TextContent{text: message} | _]} ->
        send(test_pid, {:notification, message})
      end

      script = """
      import time
      notify("step one")
      notify("step two")
      time.sleep(0.3)
      print("done")
      """

      result = ExecuteCode.execute("call-1", %{"script" => script}, nil, on_update, cwd, opts())

      assert text(result) =~ "done"

      # Both arrived, in flush order (receive drains the mailbox oldest-first).
      first = receive(do: ({:notification, message} -> message))
      second = receive(do: ({:notification, message} -> message))
      assert {first, second} == {"notify: step one", "notify: step two"}
    end

    test "a notify() as the last statement before exit is still forwarded", %{
      tmp_dir: cwd
    } do
      test_pid = self()

      on_update = fn %AgentToolResult{content: [%TextContent{text: message} | _]} ->
        send(test_pid, {:notification, message})
      end

      result =
        ExecuteCode.execute(
          "call-1",
          %{"script" => ~s|notify("last statement")|},
          nil,
          on_update,
          cwd,
          opts()
        )

      assert text(result) == "(script produced no output)"
      assert_received {:notification, "notify: last statement"}
    end

    test "a nil on_update consumes notifications without crashing the run", %{tmp_dir: cwd} do
      script = """
      import time
      notify("ignored one")
      notify("ignored two")
      time.sleep(0.3)
      print("still fine")
      """

      result = run(cwd, script)

      assert text(result) =~ "still fine"
      assert result.details.exit_code == 0
    end
  end

  describe "batch() parallel helper calls" do
    test "a batch of blocking calls overlaps: every call is in flight before any completes",
         %{tmp_dir: cwd} do
      # A barrier tool that only returns once `needed` calls are concurrently
      # in flight. Under serial dispatch the first call would spin to its
      # deadline alone and report a barrier timeout; only real parallel
      # dispatch can open the barrier.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      read_override = barrier_read_override(counter, 3)

      script = """
      results = batch([
          ("read", {"value": "r1"}),
          ("read", {"value": "r2"}),
          ("read", {"value": "r3"}),
      ])
      print("|".join(results))
      """

      result =
        run(
          cwd,
          script,
          opts(%{},
            execute_code_tool_overrides: %{"read" => read_override}
          )
        )

      on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

      assert text(result) =~ "r1|r2|r3"
      refute text(result) =~ "BARRIER TIMEOUT"
      assert result.details.rpc_calls == 3
    end

    test "the call limit stays exact when a batch exceeds the remaining budget", %{tmp_dir: cwd} do
      script = """
      try:
          batch([("ls", {}), ("ls", {}), ("ls", {})])
          print("NO ERROR")
      except Exception as e:
          print(str(e))
      """

      result = run(cwd, script, opts(%{max_rpc_calls: 2}))

      assert text(result) =~ "rpc call limit exceeded (max 2 calls per script)"
      assert result.details.rpc_calls == 2
      assert result.details.rpc_errors == 1
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp run(cwd, script, opts \\ nil) do
    ExecuteCode.execute("call-1", %{"script" => script}, nil, nil, cwd, opts || opts())
  end

  defp run_capturing_base(cwd, script, opts) do
    test = self()

    runner = fn command, runner_cwd, runner_opts ->
      send(test, {:base, command_base(command)})
      BashExecutor.execute(command, runner_cwd, runner_opts)
    end

    result = run(cwd, script, Keyword.put(opts, :script_runner, runner))

    base =
      receive do
        {:base, base} -> base
      after
        5_000 -> flunk("script runner was never invoked")
      end

    {result, base}
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  # "exec '<python>' '<base>/script.py'" -> "<base>"
  defp command_base(command) do
    [_, script_path] =
      Regex.scan(~r/'([^']+)'/, command, capture: :all_but_first) |> List.flatten()

    Path.dirname(script_path)
  end

  defp opts(settings \\ %{}, extra \\ []) do
    Keyword.merge(
      [settings_manager: %{tools: %{execute_code: Map.merge(%{enabled: true}, settings)}}],
      extra
    )
  end

  defp stub_tool(name, output) do
    %AgentTool{
      name: name,
      description: "stub #{name}",
      label: name,
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _params, _signal, _on_update ->
        %AgentToolResult{content: [%TextContent{text: output}]}
      end
    }
  end

  defp text(%AgentToolResult{content: [%TextContent{text: text} | _]}), do: text

  defp index_of(haystack, needle) do
    {index, _} = :binary.match(haystack, needle)
    index
  end

  # A helper stub that returns only once `needed` calls are concurrently in
  # flight (a barrier): proof by construction that dispatch overlapped.
  defp barrier_read_override(counter, needed) do
    %AgentTool{
      name: "read",
      description: "barrier read",
      label: "read",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, params, _signal, _on_update ->
        _in_flight = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if spin_until(fn -> Agent.get(counter, & &1) >= needed end, 10_000) do
          %AgentToolResult{content: [%TextContent{text: params["value"] || ""}]}
        else
          %AgentToolResult{content: [%TextContent{text: "BARRIER TIMEOUT"}]}
        end
      end
    }
  end

  defp spin_until(fun, deadline_ms) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms

    if fun.() do
      true
    else
      spin_wait(fun, deadline)
    end
  end

  defp spin_wait(fun, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      false
    else
      Process.sleep(10)

      if fun.(), do: true, else: spin_wait(fun, deadline)
    end
  end
end
