defmodule CodingAgent.Tools.ExecuteCodeAdversarialRpcTest do
  @moduledoc """
  Adversarial protocol coverage for the `execute_code` RPC pump.

  The happy-path protocol lives in `CodingAgent.Tools.ExecuteCodeRpcTest`; this
  module models a script that ignores the generated shim and writes raw frames
  itself — the only thing a real script has to do to attack the protocol.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.ExecuteCode.Rpc
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir
  @token String.duplicate("a", 43)

  setup %{tmp_dir: base} do
    assert {:ok, _rpc_dir} = CodingAgent.PrivateTmp.reserve_dir(base, "rpc")
    {:ok, rpc_dir: discover_rpc_dir!(base)}
  end

  describe "malformed frames" do
    test "every malformed shape is answered rather than ignored", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      bodies = %{
        1 => "{not json",
        2 => Jason.encode!([%{"token" => @token, "tool" => "echo"}]),
        3 => Jason.encode!(%{"token" => @token, "tool" => 42, "params" => %{}}),
        4 => Jason.encode!(%{"token" => @token, "params" => %{}}),
        5 =>
          Jason.encode!(%{"token" => @token, "tool" => "echo", "params" => ["not", "a", "map"]}),
        6 => Jason.encode!(%{"token" => @token, "tool" => "echo", "params" => "value=hello"}),
        7 => "",
        8 => Jason.encode!("just a string")
      }

      for {id, body} <- bodies, do: File.write!(Path.join(rpc_dir, "req-#{id}.json"), body)

      # An unanswered frame would hang the script until its wall clock ran out,
      # so "rejected" must always mean "rejected in writing". Undecodable or
      # non-map frames cannot authenticate; authenticated malformed calls reach
      # structural validation, but none reach a tool.
      for id <- [1, 2, 7, 8] do
        assert %{"ok" => false, "error" => "rpc authentication failed"} =
                 await_response(rpc_dir, id)
      end

      for id <- 3..6 do
        assert %{"ok" => false, "error" => "invalid rpc request"} =
                 await_response(rpc_dir, id)
      end

      write_request(rpc_dir, 9, "echo", %{"value" => "still serving"})
      assert %{"ok" => true, "content" => "still serving"} = await_response(rpc_dir, 9)

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.denied == 4
      assert stats.errors == 4
      assert stats.calls == 5
      assert Path.wildcard(Path.join(rpc_dir, "req-*.json")) == []
      assert Path.wildcard(Path.join(rpc_dir, "*.tmp")) == []
    end

    test "a request directory with descendants is skipped without consuming the sweep cap", %{
      rpc_dir: rpc_dir
    } do
      request_dir = Path.join(rpc_dir, "req-1.json")
      descendant = Path.join(request_dir, "nested/request.json")
      File.mkdir_p!(Path.dirname(descendant))
      File.write!(descendant, "must survive")

      write_request(rpc_dir, 2, "echo", %{"value" => "alive"})

      ctx = Map.put(ctx(rpc_dir), :max_requests_per_sweep, 1)
      stats = Rpc.process_pending(ctx, Rpc.initial_stats())

      assert %{"ok" => true, "content" => "alive"} = read_response(rpc_dir, 2)
      assert stats.calls == 1
      refute File.exists?(Path.join(rpc_dir, "res-1.json"))
      assert File.lstat!(request_dir).type == :directory
      assert File.read!(descendant) == "must survive"

      # A file that becomes a directory after selection also remains intact:
      # File.rm/1 rejects it instead of recursively removing its descendants.
      stats = Rpc.process_request(1, ctx, stats)
      assert %{"ok" => false, "error" => "rpc authentication failed"} = read_response(rpc_dir, 1)
      assert stats.denied == 1
      assert File.lstat!(request_dir).type == :directory
      assert File.read!(descendant) == "must survive"
    end

    test "a frame whose id is not an integer is consumed without dispatch", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      File.write!(
        Path.join(rpc_dir, "req-abc.json"),
        Jason.encode!(%{"token" => @token, "tool" => "tattle", "params" => %{}})
      )

      write_request(rpc_dir, 1, "echo", %{"value" => "numeric"})
      assert %{"ok" => true, "content" => "numeric"} = await_response(rpc_dir, 1)

      # No integer id means there is no safe response name and no dispatch, but
      # the malformed frame must not remain to be scanned forever.
      refute_received {:called, "tattle"}
      refute File.exists?(Path.join(rpc_dir, "req-abc.json"))
      refute File.exists?(Path.join(rpc_dir, "res-abc.json"))

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 1
    end

    test "a negative id stays inside the rpc directory", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))

      write_request(rpc_dir, -3, "echo", %{"value" => "negative"})
      assert %{"id" => -3, "ok" => true, "content" => "negative"} = await_response(rpc_dir, -3)

      # Ids only ever reach the filesystem through `req-`/`res-` names built
      # from a parsed integer, so no id can name a path outside the rpc dir.
      names =
        rpc_dir |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()

      assert names == ["res--3.json"]
      finish_pump(pump)
    end
  end

  describe "caps under an adversarial script" do
    test "an rpc flood is capped and every frame still gets an answer", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir, max_calls: 3))

      for id <- 1..200, do: write_request(rpc_dir, id, "echo", %{"value" => "v#{id}"})
      for id <- 1..200, do: assert(%{"id" => ^id} = await_response(rpc_dir, id))

      answers = Enum.map(1..200, &read_response(rpc_dir, &1))

      # Frames are served in ascending id order, so the cap is deterministic:
      # the three lowest ids win and the rest are refused, never dropped.
      assert Enum.count(answers, & &1["ok"]) == 3
      assert answers |> Enum.take(3) |> Enum.map(& &1["ok"]) == [true, true, true]

      for answer <- Enum.drop(answers, 3) do
        assert answer["error"] =~ "rpc call limit exceeded (max 3 calls per script)"
      end

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.calls == 3
      assert stats.errors == 197
    end

    test "the byte budget is spent across calls, not per call", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir, max_result_bytes: 100))

      write_request(rpc_dir, 1, "big", %{"size" => 60})
      assert %{"ok" => true} = await_response(rpc_dir, 1)

      write_request(rpc_dir, 2, "big", %{"size" => 60})
      assert %{"ok" => false, "error" => error} = await_response(rpc_dir, 2)
      assert error =~ "40 bytes remaining of 100"

      write_request(rpc_dir, 3, "big", %{"size" => 40})
      assert %{"ok" => true} = await_response(rpc_dir, 3)

      write_request(rpc_dir, 4, "big", %{"size" => 1})
      assert %{"ok" => false, "error" => exhausted} = await_response(rpc_dir, 4)
      assert exhausted =~ "0 bytes remaining of 100"

      {:ok, :done, stats} = finish_pump(pump)
      assert stats.bytes == 100
      assert stats.errors == 2
    end
  end

  describe "lifecycle" do
    test "a frame written after the script exits is never served", %{rpc_dir: rpc_dir} do
      pump = start_pump(ctx(rpc_dir))
      {:ok, :done, stats} = finish_pump(pump)

      # A script that forks a child which outlives it cannot keep calling tools:
      # the pump stops with the script, by design (no final drain).
      write_request(rpc_dir, 1, "tattle", %{})
      Process.sleep(80)

      refute File.exists?(Path.join(rpc_dir, "res-1.json"))
      refute_received {:called, "tattle"}
      assert stats.calls == 0
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  defp ctx(rpc_dir, overrides \\ []) do
    %{
      tools: stub_tools(),
      tool_policy: Keyword.get(overrides, :tool_policy),
      approval_context: Keyword.get(overrides, :approval_context),
      max_calls: Keyword.get(overrides, :max_calls, 100),
      max_result_bytes: Keyword.get(overrides, :max_result_bytes, 5_242_880),
      signal: Keyword.get(overrides, :signal),
      rpc_dir: rpc_dir,
      token: Keyword.get(overrides, :token, @token),
      poll_interval_ms: 5
    }
  end

  defp stub_tools do
    test = self()

    %{
      "echo" => stub_tool("echo", fn params -> text(params["value"] || "") end),
      "big" =>
        stub_tool("big", fn params -> text(String.duplicate("x", params["size"] || 10)) end),
      "tattle" =>
        stub_tool("tattle", fn _params ->
          send(test, {:called, "tattle"})
          text("tattled")
        end)
    }
  end

  defp stub_tool(name, fun) do
    %AgentTool{
      name: name,
      description: "stub",
      label: name,
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, params, _signal, _on_update -> fun.(params) end
    }
  end

  defp text(value), do: %AgentToolResult{content: [%TextContent{text: value}]}

  defp start_pump(ctx) do
    test = self()

    runner =
      Task.async(fn ->
        script =
          Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
            receive(do: ({:finish, result} -> result))
          end)

        send(test, {:script_pid, script.pid})
        Rpc.serve(script, ctx)
      end)

    script_pid =
      receive do
        {:script_pid, pid} -> pid
      after
        5_000 -> flunk("script task never started")
      end

    %{runner: runner, script_pid: script_pid}
  end

  defp finish_pump(pump) do
    send(pump.script_pid, {:finish, :done})
    Task.await(pump.runner, 30_000)
  end

  defp discover_rpc_dir!(base) do
    rpc_dirs =
      base
      |> Path.join("rpc-*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)

    assert [rpc_dir] = rpc_dirs,
           "expected exactly one rpc-* directory under #{base}, got: #{inspect(rpc_dirs)}"

    rpc_dir
  end

  defp write_request(rpc_dir, id, tool, params, token \\ @token) do
    assert File.dir?(rpc_dir), "rpc directory does not exist: #{rpc_dir}"
    tmp = Path.join(rpc_dir, "req-#{id}.json.tmp")

    File.write!(
      tmp,
      Jason.encode!(%{"id" => id, "token" => token, "tool" => tool, "params" => params})
    )

    File.rename!(tmp, Path.join(rpc_dir, "req-#{id}.json"))
  end

  defp await_response(rpc_dir, id, attempts \\ 600) do
    path = Path.join(rpc_dir, "res-#{id}.json")

    cond do
      File.exists?(path) ->
        read_response(rpc_dir, id)

      attempts <= 0 ->
        flunk("no response for request #{id}")

      true ->
        Process.sleep(5)
        await_response(rpc_dir, id, attempts - 1)
    end
  end

  defp read_response(rpc_dir, id) do
    rpc_dir |> Path.join("res-#{id}.json") |> File.read!() |> Jason.decode!()
  end
end

defmodule CodingAgent.Tools.ExecuteCodeAdversarialTest do
  @moduledoc """
  Adversarial coverage for the whole `execute_code` tool.

  The python script is replaced by a hostile Elixir `:script_runner` that writes
  raw RPC frames instead of going through the generated shim — exactly the
  escape a real script would attempt, and with no python3 involved the escapes
  are checked on every host.
  """
  use ExUnit.Case, async: false

  alias CodingAgent.BashExecutor
  alias CodingAgent.ToolPolicy
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools
  alias CodingAgent.Tools.ExecuteCode
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{TextContent, ToolResultMessage}

  @moduletag :tmp_dir

  describe "allowlist escapes" do
    test "hand-written frames cannot reach a tool outside the allowlist", %{tmp_dir: cwd} do
      forbidden = ["bash", "write", "edit", "patch", "agent", "execute_code"]
      frames = Enum.map(forbidden, &{&1, %{"command" => "id"}})

      {result, answers, _base} = hostile_run(cwd, frames, opts())

      for {name, answer} <- Enum.zip(forbidden, answers) do
        assert answer["ok"] == false
        assert answer["error"] == "tool '#{name}' is not available inside execute_code scripts"
      end

      assert result.details.rpc_errors == length(forbidden)
      assert result.details.rpc_tools == []
    end

    test "narrowing the config removes the capability, not just the python stub", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "readable")

      frames = [
        {"read", %{"path" => "f.txt"}},
        {"grep", %{"pattern" => "x"}},
        {"ls", %{}},
        {"find", %{"pattern" => "*"}},
        {"webfetch", %{"url" => "https://example.com"}}
      ]

      {result, [read | rejected], _base} = hostile_run(cwd, frames, opts(%{tools: ["read"]}))

      assert read["ok"] == true

      for answer <- rejected do
        assert answer["ok"] == false
        assert answer["error"] =~ "is not available inside execute_code scripts"
      end

      # A webfetch the pump refused never fetched anything, so an attempt alone
      # does not taint the run.
      assert result.trust == :trusted
      assert result.details.rpc_tools == ["read"]
    end

    test "config can narrow the allowlist but never widen it", %{tmp_dir: cwd} do
      options = opts(%{tools: ["read", "bash", "write"]})

      {_result, [bash], _base} = hostile_run(cwd, [{"bash", %{"command" => "id"}}], options)

      assert bash["error"] =~ "tool 'bash' is not available inside execute_code scripts"
      refute ExecuteCode.tool(cwd, options).description =~ "bash("
    end
  end

  describe "policy escapes through the registry" do
    test "a policy that denies an inner tool denies it inside a script too", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "secret")
      frames = [{"read", %{"path" => "f.txt"}}]

      options =
        opts(%{}, tool_policy: ToolPolicy.custom(deny: ["read"]))
        |> registry_opts()
        |> with_runner(frames)

      assert {:ok, tool} = ToolRegistry.get_tool(cwd, "execute_code", options)

      {result, [answer], _base} = drive(tool)

      assert answer["ok"] == false
      assert answer["error"] =~ "in deny list"
      refute answer["error"] =~ "secret"
      assert result.details.rpc_denied == 1
    end

    test "an inner tool requiring approval is gated inside a script too", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "f.txt"), "secret")
      frames = [{"read", %{"path" => "f.txt"}}]
      test = self()

      options =
        opts(%{},
          tool_policy: ToolPolicy.custom(require_approval: ["read"]),
          approval_context: %{
            timeout_ms: 30_000,
            approval_request_fun: fn request ->
              send(test, {:approval_requested, request.tool})
              {:ok, :denied}
            end
          }
        )
        |> registry_opts()
        |> with_runner(frames)

      assert {:ok, tool} = ToolRegistry.get_tool(cwd, "execute_code", options)

      {result, [answer], _base} = drive(tool)

      # The approval prompt names the inner tool, proving the registry's
      # approval context reached the pump rather than stopping at execute_code.
      assert_received {:approval_requested, "read"}
      assert answer["error"] =~ "approval denied for 'read'"
      refute answer["error"] =~ "secret"
      assert result.details.rpc_denied == 1
    end
  end

  describe "path reach" do
    test "an rpc read reaches exactly what a direct read tool call reaches", %{tmp_dir: cwd} do
      outside = Path.join(Path.dirname(cwd), "outside-#{System.unique_integer([:positive])}.txt")
      File.write!(outside, "OUTSIDE-THE-CWD")
      on_exit(fn -> File.rm(outside) end)

      paths = [outside, Path.join("..", Path.basename(outside)), "/etc/hostname"]
      frames = Enum.map(paths, &{"read", %{"path" => &1}})

      {_result, answers, _base} = hostile_run(cwd, frames, opts())

      # execute_code must add no reach and remove none: the RPC path runs the
      # same tool with the same cwd, so if a jail is ever added to `read` it
      # applies inside scripts too and this stays green.
      for {answer, path} <- Enum.zip(answers, paths) do
        assert normalize_answer(answer) == direct_read(cwd, path)
      end
    end
  end

  describe "runtime-absent hosts" do
    test "a python_path that is not an executable file is refused before anything runs", %{
      tmp_dir: cwd
    } do
      not_executable = Path.join(cwd, "not-python")
      File.write!(not_executable, "#!/bin/sh\necho nope\n")
      File.chmod!(not_executable, 0o600)

      runner = fn _command, _cwd, _opts -> flunk("no script may run without a python3") end

      for path <- [cwd, not_executable, Path.join(cwd, "missing-python3")] do
        assert {:error, message} =
                 ExecuteCode.execute(
                   "call-1",
                   %{"script" => "print(1)"},
                   nil,
                   nil,
                   cwd,
                   opts(%{python_path: path}, script_runner: runner)
                 )

        assert message =~ path
      end

      # The refusal happens before the workspace is built.
      assert Path.wildcard(Path.join(System.tmp_dir!(), "lemon-exec-code-*")) == []
    end
  end

  describe "runaway scripts" do
    # The only adversarial case that genuinely needs an interpreter: a script
    # cannot decline its own wall-time kill.
    if System.find_executable("python3") == nil do
      @describetag :skip
    end

    test "a script that ignores SIGTERM is still killed on the wall clock", %{tmp_dir: cwd} do
      script = """
      import os, signal, time
      signal.signal(signal.SIGTERM, lambda *_: None)
      signal.signal(signal.SIGINT, lambda *_: None)
      with open("pid.txt", "w") as f:
          f.write(str(os.getpid()))
      while True:
          time.sleep(0.05)
      """

      started = System.monotonic_time(:millisecond)

      result =
        ExecuteCode.execute(
          "call-1",
          %{"script" => script},
          nil,
          nil,
          cwd,
          opts(%{timeout_ms: 2_000})
        )

      elapsed = System.monotonic_time(:millisecond) - started

      # A hung script still produces a well-formed tool result, not a crash.
      assert %AgentToolResult{} = result
      assert [%TextContent{text: text}] = result.content
      assert text =~ "timed out after 2000ms"
      assert elapsed < 15_000
      assert Path.wildcard(Path.join(System.tmp_dir!(), "lemon-exec-code-*")) == []

      # And the interpreter is gone: the wall-time cap is a process-group kill,
      # not a polite request the script can decline.
      if File.dir?("/proc") do
        pid = cwd |> Path.join("pid.txt") |> File.read!() |> String.trim()
        assert process_dead?(pid)
      end
    end
  end

  describe "concurrency" do
    test "concurrent runs get their own workspace, budget and answers", %{tmp_dir: cwd} do
      run_one = fn tag ->
        fn ->
          frames = for i <- 1..3, do: {"read", %{"path" => "#{tag}-#{i}"}}

          hostile_run(
            cwd,
            frames,
            opts(%{max_rpc_calls: 2},
              execute_code_tool_overrides: %{"read" => param_tool("read", "path")}
            )
          )
        end
      end

      [{result_a, answers_a, base_a}, {result_b, answers_b, base_b}] =
        ["AAA", "BBB"]
        |> Enum.map(&Task.async(run_one.(&1)))
        |> Task.await_many(60_000)

      # Each run carries its own call budget rather than sharing one.
      for result <- [result_a, result_b] do
        assert result.details.rpc_calls == 2
        assert result.details.rpc_errors == 1
      end

      assert Enum.map(answers_a, & &1["content"]) == ["AAA-1", "AAA-2", nil]
      assert Enum.map(answers_b, & &1["content"]) == ["BBB-1", "BBB-2", nil]

      assert base_a != base_b
      refute File.exists?(base_a)
      refute File.exists?(base_b)
    end
  end

  describe "context isolation" do
    test "a large intermediate provably never reaches the transcript", %{tmp_dir: cwd} do
      needle = "SUPERSECRETNEEDLEPAYLOAD"
      payload = String.duplicate(needle <> String.duplicate("x", 76), 4_000)

      options = opts(%{}, execute_code_tool_overrides: %{"read" => stub_tool("read", payload)})

      {result, [answer], _base} =
        hostile_run(cwd, [{"read", %{"path" => "big.txt"}}], options, stdout: "42")

      # The payload really did travel over the RPC files...
      assert answer["content"] == payload
      assert result.details.rpc_bytes == byte_size(payload)
      assert result.details.rpc_bytes > 100_000

      # ...and none of it is in the tool result the loop turns into a transcript
      # message (`LemonAgent.Loop.ToolCalls.emit_tool_result/7` copies exactly
      # these two fields).
      message = %ToolResultMessage{
        tool_call_id: "call-1",
        tool_name: "execute_code",
        content: result.content,
        details: result.details,
        trust: result.trust
      }

      transcript = Enum.map_join(message.content, "\n", & &1.text)

      assert transcript == "42"
      refute transcript =~ needle
      # `details` is UI/logging only and carries counters, not payload, so the
      # megabyte is invisible to the model on both fields.
      refute inspect(message.details) =~ needle

      # `LemonAi.ContextCompactor` estimates a tool result from its `content`
      # blocks alone, so this is the entire token cost of the run.
      assert LemonAi.Tokens.estimate_chars(transcript) < 20
      assert LemonAi.Tokens.estimate_chars(payload) > 10_000
    end

    test "a refused oversized result leaks neither payload nor taint", %{tmp_dir: cwd} do
      needle = "FETCHEDSECRET"
      payload = String.duplicate(needle, 1_000)

      options =
        opts(%{max_rpc_result_bytes: 64},
          execute_code_tool_overrides: %{"webfetch" => stub_tool("webfetch", payload)}
        )

      {result, [answer], _base} =
        hostile_run(cwd, [{"webfetch", %{"url" => "https://example.com"}}], options)

      assert answer["ok"] == false
      refute answer["error"] =~ needle
      assert result.details.rpc_bytes == 0
      # The bytes never reached the script, so the run is not web-tainted.
      assert result.trust == :trusted
      assert result.details.rpc_tools == []
    end
  end

  describe "planted result-channel files" do
    test "a text-<id>.json symlink cannot inject a result block", %{tmp_dir: cwd} do
      victim =
        Path.join(Path.dirname(cwd), "block-victim-#{System.unique_integer([:positive])}.txt")

      File.write!(victim, "INJECTED RESULT VIA SYMLINK")
      on_exit(fn -> File.rm(victim) end)

      runner = fn command, _runner_cwd, runner_opts ->
        base = command_base(command)
        rpc_dir = discover_rpc_dir!(base)
        File.ln_s!(victim, Path.join(rpc_dir, "text-1.json"))

        {:ok,
         %BashExecutor.Result{
           output: "done",
           exit_code: 0,
           cancelled: false,
           truncated: false,
           full_output_path: nil
         }}
      end

      result =
        ExecuteCode.execute(
          "call-1",
          %{"script" => "unused"},
          nil,
          nil,
          cwd,
          opts(%{}, script_runner: runner)
        )

      # The planted link is skipped like the res-<id>.json defense: the
      # victim is untouched and the result is exactly the honest stdout.
      assert [%TextContent{text: "done"}] = result.content
      assert File.read!(victim) == "INJECTED RESULT VIA SYMLINK"
    end

    test "an oversized planted text block is skipped without crashing", %{tmp_dir: cwd} do
      runner = fn command, _runner_cwd, _runner_opts ->
        base = command_base(command)
        rpc_dir = discover_rpc_dir!(base)

        tmp = Path.join(rpc_dir, "text-1.json.tmp")
        File.write!(tmp, Jason.encode!(%{"n" => 1, "text" => String.duplicate("z", 5_000_000)}))
        File.rename!(tmp, Path.join(rpc_dir, "text-1.json"))

        {:ok,
         %BashExecutor.Result{
           output: "done",
           exit_code: 0,
           cancelled: false,
           truncated: false,
           full_output_path: nil
         }}
      end

      result =
        ExecuteCode.execute(
          "call-1",
          %{"script" => "unused"},
          nil,
          nil,
          cwd,
          opts(%{}, script_runner: runner)
        )

      assert [%TextContent{text: "done"}] = result.content
    end
  end

  # ==========================================================================
  # Helpers
  # ==========================================================================

  # Runs `execute_code` with the python script replaced by an Elixir "script"
  # that writes the given raw RPC frames into the workspace and collects the
  # answers. Returns `{result, answers, workspace_base}`.
  defp hostile_run(cwd, frames, options, runner_opts \\ []) do
    options = with_runner(options, frames, runner_opts)
    result = ExecuteCode.execute("call-1", %{"script" => "unused"}, nil, nil, cwd, options)
    {answers, base} = collect_run()
    {result, answers, base}
  end

  # Same, for a tool built by the registry (its opts must already carry the
  # runner, since the tool closes over them at build time).
  defp drive(%AgentTool{} = tool) do
    result = tool.execute.("call-1", %{"script" => "unused"}, nil, nil)
    {answers, base} = collect_run()
    {result, answers, base}
  end

  defp with_runner(options, frames, runner_opts \\ []) do
    test = self()
    stdout = Keyword.get(runner_opts, :stdout, "done")

    runner = fn command, _runner_cwd, _runner_opts ->
      base = command_base(command)
      rpc_dir = discover_rpc_dir!(base)
      token = configured_token(base)

      answers =
        frames
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, params}, id} ->
          write_request(rpc_dir, id, name, params, token)
          await_response(rpc_dir, id)
        end)

      send(test, {:run, base, answers})

      {:ok,
       %BashExecutor.Result{
         output: stdout,
         exit_code: 0,
         cancelled: false,
         truncated: false,
         full_output_path: nil
       }}
    end

    Keyword.put(options, :script_runner, runner)
  end

  defp collect_run do
    receive do
      {:run, base, answers} -> {answers, base}
    after
      30_000 -> flunk("the hostile script runner never reported")
    end
  end

  defp registry_opts(options),
    do: Keyword.merge(options, include_extensions: false, include_mcp: false)

  defp normalize_answer(%{"ok" => true, "content" => content}), do: {:ok, content}
  defp normalize_answer(%{"ok" => false, "error" => error}), do: {:error, error}

  defp direct_read(cwd, path) do
    case Tools.Read.execute("direct", %{"path" => path}, nil, nil, cwd, []) do
      %AgentToolResult{content: content} -> {:ok, Enum.map_join(content, "\n", & &1.text)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  # "exec '<python>' '<base>/script.py'" -> "<base>"
  defp command_base(command) do
    [_python, script_path] =
      Regex.scan(~r/'([^']+)'/, command, capture: :all_but_first) |> List.flatten()

    Path.dirname(script_path)
  end

  defp discover_rpc_dir!(base) do
    rpc_dirs =
      base
      |> Path.join("rpc-*")
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)

    assert [rpc_dir] = rpc_dirs,
           "expected exactly one rpc-* directory under #{base}, got: #{inspect(rpc_dirs)}"

    rpc_dir
  end

  defp configured_token(base) do
    source = File.read!(Path.join(base, "lemon_tools.py"))

    [_, encoded] =
      Regex.run(~r/_configure\(.*,\s*("(?:[^"\\]|\\.)*")\)\s*\z/s, source)

    Jason.decode!(encoded)
  end

  defp write_request(rpc_dir, id, tool, params, token) do
    assert File.dir?(rpc_dir), "rpc directory does not exist: #{rpc_dir}"
    tmp = Path.join(rpc_dir, "req-#{id}.json.tmp")

    File.write!(
      tmp,
      Jason.encode!(%{"id" => id, "token" => token, "tool" => tool, "params" => params})
    )

    File.rename!(tmp, Path.join(rpc_dir, "req-#{id}.json"))
  end

  defp await_response(rpc_dir, id, attempts \\ 600) do
    path = Path.join(rpc_dir, "res-#{id}.json")

    cond do
      File.exists?(path) -> path |> File.read!() |> Jason.decode!()
      attempts <= 0 -> nil
      true -> Process.sleep(10) && await_response(rpc_dir, id, attempts - 1)
    end
  end

  defp opts(settings \\ %{}, extra \\ []) do
    Keyword.merge(
      [settings_manager: %{tools: %{execute_code: Map.merge(%{enabled: true}, settings)}}],
      extra
    )
  end

  # Dead means gone or reaped-but-not-yet-collected; either way it is not
  # burning CPU past its wall clock.
  defp process_dead?(pid, attempts \\ 100) do
    cond do
      not File.exists?("/proc/#{pid}") -> true
      zombie?(pid) -> true
      attempts <= 0 -> false
      true -> Process.sleep(50) && process_dead?(pid, attempts - 1)
    end
  end

  defp zombie?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} -> stat |> String.split(") ") |> List.last() |> String.starts_with?("Z")
      {:error, _} -> true
    end
  end

  defp param_tool(name, key) do
    stub_execute(name, fn params -> params[key] || "" end)
  end

  defp stub_tool(name, output) do
    stub_execute(name, fn _params -> output end)
  end

  defp stub_execute(name, fun) do
    %AgentTool{
      name: name,
      description: "stub #{name}",
      label: name,
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, params, _signal, _on_update ->
        %AgentToolResult{content: [%TextContent{text: fun.(params)}]}
      end
    }
  end
end
