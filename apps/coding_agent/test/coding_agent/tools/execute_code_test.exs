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
      assert tool.description =~ "only what the script prints to stdout is returned"
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

      assert module =~ "def _configure(rpc_dir, token):"
      assert module =~ "lemon_tools is not configured for this cell"
      refute module =~ "_configure(\""
      refute module =~ "_TOKEN = \""
    end

    test "a configured prelude embeds its rpc dir and token exactly once, json-escaped" do
      token = "token-0123"
      prelude = PythonShim.render_prelude("/tmp/it's here", token, Config.allowlist())

      assert prelude =~ ~s|_configure("/tmp/it's here", "token-0123")|
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

      script = """
      import json, os
      import lemon_tools

      requests = []
      for request_id, token in enumerate(("first-token", "second-token"), 1):
          rpc_dir = "rpc-%d" % request_id
          os.mkdir(rpc_dir)
          with open(os.path.join(rpc_dir, "res-%d.json" % request_id), "w") as response:
              json.dump({"id": request_id, "ok": True, "content": ""}, response)

          lemon_tools._configure(rpc_dir, token)
          lemon_tools.read("ignored")

          with open(os.path.join(rpc_dir, "req-%d.json" % request_id)) as request:
              requests.append(json.load(request))

      print(json.dumps(requests))
      """

      {output, 0} = System.cmd("python3", ["-c", script], cd: tmp_dir)

      assert [
               %{"id" => 1, "token" => "first-token", "tool" => "read"},
               %{"id" => 2, "token" => "second-token", "tool" => "read"}
             ] = Jason.decode!(output)
    end

    test "the import line only imports enabled names" do
      assert PythonShim.import_line(["read", "ls"]) ==
               "from lemon_tools import ToolError, read, ls"

      assert PythonShim.import_line(Config.allowlist()) ==
               "from lemon_tools import ToolError, read, grep, find, ls, webfetch"
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
      assert Path.wildcard(Path.join(System.tmp_dir!(), "lemon-exec-code-*")) == []
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
        Regex.run(~r/_configure\("([^"]+)", "([^"]+)"\)/, first_shim)

      [_, second_rpc_dir, second_token] =
        Regex.run(~r/_configure\("([^"]+)", "([^"]+)"\)/, second_shim)

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
end
