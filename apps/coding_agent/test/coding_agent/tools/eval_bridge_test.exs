defmodule CodingAgent.Tools.EvalBridgeTest do
  # Real kernels are spawned; run serially like the other eval suites.
  use ExUnit.Case, async: false

  import LemonPlatformTest.Testing.AsyncHelpers

  alias CodingAgent.MutationLock
  alias CodingAgent.Session
  alias CodingAgent.SettingsManager
  alias CodingAgent.ToolDisclosure
  alias CodingAgent.ToolPolicy
  alias CodingAgent.Tools.Eval
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.{ImageContent, Model, ModelCost, TextContent}

  @moduletag :tmp_dir

  @tag :python3
  test "code-mode local bash bridge returns real split streams and exit status", ctx do
    bash =
      CodingAgent.Tools.Bash.tool(ctx.cwd, tool_disclosure: %{enabled: true, profile: :code_mode})

    resolver = fn "bash" -> {:ok, bash} end

    assert {:ok, result} =
             CodingAgent.Eval.Bridge.call(
               resolver,
               "bash",
               "streams",
               %{"command" => "printf 'stdout only'; printf 'stderr only' >&2; exit 3"},
               AbortSignal.new()
             )

    assert result.stdout == "stdout only"
    assert result.stderr == "stderr only"
    assert result.exit_code == 3
    refute result.output_combined
    refute result.ok
  end

  defmodule ReplySink do
    def tool_reply(pid, ref, call, result), do: send(pid, {:bridge_reply, ref, call, result})
  end

  test "a non-kernel runtime receives bridge refusals through its reply module" do
    ref = make_ref()
    bridge = CodingAgent.Eval.Bridge.new(self(), ref, "sandbox", nil, reply_module: ReplySink)
    CodingAgent.Eval.Bridge.request(bridge, 1, "missing", %{})
    assert_received {:bridge_reply, ^ref, 1, {:error, _}}
  end

  test "direct bridge calls validate arguments before executing wrapped tools" do
    parent = self()

    wrapped = %AgentTool{
      name: "validated",
      parameters: %{
        "type" => "object",
        "required" => ["value"],
        "properties" => %{"value" => %{"type" => "integer"}}
      },
      execute: fn id, args, signal, update ->
        send(parent, {:validated, id, args, signal, update})
        %AgentToolResult{content: [%TextContent{text: "done"}]}
      end
    }

    resolver = fn "validated" -> {:ok, wrapped} end
    signal = AbortSignal.new()

    assert {:error, message} =
             CodingAgent.Eval.Bridge.call(resolver, "validated", "call", %{}, signal)

    assert message =~ "invalid tool arguments"
    refute_received {:validated, _, _, _, _}

    args = %{"value" => 3, "i" => "ordinary cell data"}

    assert {:ok, %{ok: true, text: "done"}} =
             CodingAgent.Eval.Bridge.call(resolver, "validated", "call", args, signal)

    assert_received {:validated, "call", ^args, ^signal, nil}
  end

  test "structured streams come from details rather than presentation text" do
    result = %AgentToolResult{
      content: [%TextContent{text: "decorated human output"}],
      details: %{stdout: "out", stderr: "err", exit_code: 7},
      is_error: true
    }

    assert %{
             ok: false,
             stdout: "out",
             stderr: "err",
             exit_code: 7,
             text: "decorated human output"
           } = CodingAgent.Eval.Bridge.project(result)

    plain =
      CodingAgent.Eval.Bridge.project(%AgentToolResult{
        content: [%TextContent{text: "stdout: not a structured field"}]
      })

    refute Map.has_key?(plain, :stdout)
    refute Map.has_key?(plain, :stderr)
  end

  test "merged backend streams are unavailable rather than fabricated" do
    result = %AgentToolResult{
      content: [%TextContent{text: "combined\\nCommand exited with code 4"}],
      details: %{
        stdout: nil,
        stderr: nil,
        output: "combined",
        exit_code: 4,
        output_combined: true
      }
    }

    assert %{stdout: nil, stderr: nil, output: "combined", exit_code: 4, output_combined: true} =
             CodingAgent.Eval.Bridge.project(result)
  end

  @python System.find_executable("python3") || System.find_executable("python")
  @bun System.find_executable("bun")
  @node System.find_executable("node")

  setup %{tmp_dir: tmp_dir} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    session_id = "eval-bridge-#{System.unique_integer([:positive])}"
    on_exit(fn -> Process.exit(owner, :kill) end)
    test_pid = self()
    peak = :atomics.new(2, [])

    tools = %{
      "echo" =>
        tool("echo", fn id, args, signal, on_update ->
          send(test_pid, {:called, id, args, signal, on_update})

          %AgentToolResult{
            content: [
              %TextContent{text: "echo:#{args["value"]}"},
              %ImageContent{data: "aW1n", mime_type: "image/png"},
              %TextContent{text: "second"}
            ],
            details: %{seen: args, kind: :fake, tuple: {1, 2}}
          }
        end),
      "sleep" =>
        tool("sleep", fn _id, args, _signal, _on_update ->
          now = :atomics.add_get(peak, 1, 1)
          bump_peak(peak, now)
          Process.sleep(300)
          :atomics.sub(peak, 1, 1)
          %AgentToolResult{content: [%TextContent{text: "slept #{args["i"]}"}]}
        end),
      "fail" => tool("fail", fn _id, _args, _signal, _on_update -> {:error, "boom"} end),
      "flagged" =>
        tool("flagged", fn _id, _args, _signal, _on_update ->
          %AgentToolResult{content: [%TextContent{text: "denied"}], is_error: true}
        end),
      "crash" => tool("crash", fn _id, _args, _signal, _on_update -> raise "kaput" end),
      "slow" =>
        tool("slow", fn id, _args, signal, _on_update ->
          send(test_pid, {:slow_started, id, self()})
          wait_for_abort(signal)
          send(test_pid, {:inner_aborted, id})
          %AgentToolResult{content: [%TextContent{text: "stopped"}]}
        end)
    }

    resolver = fn name ->
      case Map.fetch(tools, name) do
        {:ok, tool} -> {:ok, tool}
        :error -> {:error, "unknown or unavailable tool: #{name}"}
      end
    end

    %{
      cwd: tmp_dir,
      session_id: session_id,
      peak: peak,
      opts: [session_id: session_id, session_pid: owner, tool_resolver: resolver]
    }
  end

  defp tool(name, execute) do
    %AgentTool{
      name: name,
      description: name,
      label: name,
      parameters: %{"type" => "object", "properties" => %{}},
      execute: execute
    }
  end

  defp bump_peak(peak, now) do
    seen = :atomics.get(peak, 2)

    if now > seen and :atomics.compare_exchange(peak, 2, seen, now) != :ok,
      do: bump_peak(peak, now)
  end

  defp wait_for_abort(signal) do
    unless AbortSignal.aborted?(signal) do
      Process.sleep(10)
      wait_for_abort(signal)
    end
  end

  defp run(ctx, language, code, extra \\ []) do
    params = %{
      "language" => language,
      "code" => code,
      "timeout" => Keyword.get(extra, :timeout, 60)
    }

    opts = Keyword.merge(ctx.opts, Keyword.get(extra, :opts, []))
    Eval.execute("call", params, extra[:signal], nil, ctx.cwd, opts)
  end

  defp text(%AgentToolResult{content: content}) do
    Enum.map_join(content, "\n", fn
      %TextContent{text: text} -> text
      _ -> ""
    end)
  end

  defp json_lines(result) do
    result |> text() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  # Per-language cells for the shared scenarios.
  @cells %{
    "js" => %{
      round_trip: ~S"""
      const a = await tools.echo({value: "hi", node: "build-box"});
      const b = await tools.call("echo", {value: "again"});
      console.log(JSON.stringify(a));
      console.log(JSON.stringify(b));
      """,
      fan_out: ~S"""
      const t0 = Date.now();
      const rs = await Promise.all(Array.from({length: 8}, (_, i) => tools.sleep({i})));
      console.log(JSON.stringify({ms: Date.now() - t0, texts: rs.map(r => r.text)}));
      """,
      queued: ~S"""
      const rs = await Promise.all(Array.from({length: 20}, (_, i) => tools.sleep({i})));
      console.log(JSON.stringify({n: rs.filter(r => r.ok).length}));
      """,
      failures: ~S"""
      for (const name of ["fail", "flagged", "crash"]) {
        const r = await tools[name]({});
        console.log(JSON.stringify({ok: r.ok, text: r.text}));
      }
      """,
      rejections: ~S"""
      for (const thunk of [() => tools.nope({}), () => tools.echo(5)]) {
        try { await thunk(); console.log(JSON.stringify({rejected: false})); }
        catch (e) { console.log(JSON.stringify({rejected: e.message})); }
      }
      """,
      slow: "await tools.slow({})",
      unavailable: ~S"""
      try { await tools.echo({}) } catch (e) { console.log(JSON.stringify({rejected: e.message})) }
      """
    },
    "py" => %{
      round_trip: ~S"""
      import json
      a = await tools.echo(value="hi", node="build-box")
      b = await tools.call("echo", {"value": "again"})
      print(json.dumps(a))
      print(json.dumps(b))
      """,
      fan_out: ~S"""
      import asyncio, json, time
      t0 = time.monotonic()
      rs = await asyncio.gather(*(tools.sleep({"i": i}) for i in range(8)))
      print(json.dumps({"ms": (time.monotonic() - t0) * 1000, "texts": [r["text"] for r in rs]}))
      """,
      queued: ~S"""
      import asyncio, json
      rs = await asyncio.gather(*(tools.sleep(i=i) for i in range(20)))
      print(json.dumps({"n": sum(1 for r in rs if r["ok"])}))
      """,
      failures: ~S"""
      import json
      for name in ["fail", "flagged", "crash"]:
          r = await getattr(tools, name)()
          print(json.dumps({"ok": r["ok"], "text": r["text"]}))
      """,
      rejections: ~S"""
      import json
      for thunk in (lambda: tools.nope(), lambda: tools.echo(5)):
          try:
              await thunk()
              print(json.dumps({"rejected": False}))
          except Exception as e:
              print(json.dumps({"rejected": str(e)}))
      """,
      slow: "await tools.slow()",
      unavailable: ~S"""
      import json
      try:
          await tools.echo()
      except Exception as e:
          print(json.dumps({"rejected": str(e)}))
      """
    }
  }

  for {language, runtime, label} <- [
        {"js", @bun, "bun"},
        {"js", @node, "node"},
        {"py", @python, "python"}
      ] do
    describe "#{label} tools bridge" do
      if !runtime, do: @describetag(skip: "#{label} not on PATH")

      @language language
      @runtime_opts if(language == "js", do: [eval_runtimes: %{"js" => runtime}], else: [])
      @cells_for Map.fetch!(@cells, language)

      setup ctx do
        %{ctx | opts: Keyword.merge(ctx.opts, @runtime_opts)}
      end

      test "a call round-trips text, ok, details and images with arguments verbatim", ctx do
        result = run(ctx, @language, @cells_for.round_trip)
        refute result.is_error, text(result)

        assert [first, second] = json_lines(result)

        assert first == %{
                 "ok" => true,
                 "text" => "echo:hi\nsecond",
                 "details" => %{
                   "seen" => %{"value" => "hi", "node" => "build-box"},
                   "kind" => "fake",
                   "tuple" => "{1, 2}"
                 },
                 "images" => [%{"mimeType" => "image/png", "data" => "aW1n"}]
               }

        assert second["text"] == "echo:again\nsecond"

        prefix = "eval_#{@language}"
        assert_received {:called, id1, %{"value" => "hi", "node" => "build-box"}, s1, nil}
        assert_received {:called, id2, %{"value" => "again"}, s2, nil}
        assert id1 =~ ~r/^#{prefix}\d+_1$/
        assert id2 =~ ~r/^#{prefix}\d+_2$/
        assert is_reference(s1) and s1 != s2
      end

      test "concurrent calls run in parallel and queue beyond the cap", ctx do
        result = run(ctx, @language, @cells_for.fan_out)
        refute result.is_error, text(result)
        assert [%{"ms" => ms, "texts" => texts}] = json_lines(result)
        assert texts == Enum.map(0..7, &"slept #{&1}")
        assert ms < 8 * 300 / 2

        :atomics.put(ctx.peak, 2, 0)
        result = run(ctx, @language, @cells_for.queued)
        assert [%{"n" => 20}] = json_lines(result)
        assert :atomics.get(ctx.peak, 2) == 16
      end

      test "failing tools resolve ok:false; unknown tools and bad arguments reject", ctx do
        result = run(ctx, @language, @cells_for.failures)
        refute result.is_error, text(result)

        assert [
                 %{"ok" => false, "text" => "boom"},
                 %{"ok" => false, "text" => "denied"},
                 %{"ok" => false, "text" => crash}
               ] = json_lines(result)

        assert crash =~ "tool crash raised: kaput"

        result = run(ctx, @language, @cells_for.rejections)

        assert [%{"rejected" => unknown}, %{"rejected" => invalid}] = json_lines(result)
        assert unknown == "tools.nope: unknown or unavailable tool: nope"
        assert invalid =~ "tools.echo: arguments must be"
      end

      test "abort of the cell aborts in-flight inner calls", ctx do
        signal = AbortSignal.new()
        task = Task.async(fn -> run(ctx, @language, @cells_for.slow, signal: signal) end)

        assert_receive {:slow_started, _id, inner}, 20_000
        AbortSignal.abort(signal)
        assert_receive {:inner_aborted, _id}, 5_000

        result = Task.await(task, 15_000)
        assert result.details.status == :aborted
        assert_process_dead(inner)
      end

      test "a timed-out cell aborts its inner calls", ctx do
        result = run(ctx, @language, @cells_for.slow, timeout: 1)
        assert_received {:slow_started, _id, inner}
        assert_received {:inner_aborted, _id}
        assert result.details.status == :timeout
        refute Process.alive?(inner)
      end

      test "without a resolver or session, tool calls fail in the cell", ctx do
        opts = Keyword.drop(ctx.opts, [:tool_resolver, :session_pid])
        result = run(%{ctx | opts: opts}, @language, @cells_for.unavailable)

        assert [%{"rejected" => message}] = json_lines(result)
        assert message =~ "session tools are not available"
      end
    end
  end

  describe "mutation lock inheritance" do
    test "inheritors run under the holder's lock without waiting and exclude each other" do
      key = {:session, "inherit-#{System.unique_integer([:positive])}"}
      holder = self()

      MutationLock.with_lock(key, fn ->
        assert MutationLock.held() == [key]

        for i <- 1..2 do
          Task.async(fn ->
            MutationLock.inherit([key], holder)

            MutationLock.with_lock(key, fn ->
              send(holder, {:enter, i})
              Process.sleep(150)
              send(holder, {:leave, i})
            end)
          end)
        end
        |> Task.await_many(5_000)
      end)

      events = for _ <- 1..4, do: assert_receive({kind, _} when kind in [:enter, :leave])
      assert [{:enter, a}, {:leave, a}, {:enter, b}, {:leave, b}] = events
      assert a != b
      assert MutationLock.held() == []
    end

    @tag :python3
    test "a bridged mutating call does not deadlock under the cell's session lock", ctx do
      key = {:session, ctx.session_id}
      test_pid = self()

      locking =
        tool("locking", fn _id, args, _signal, _on_update ->
          # Mirrors ToolRegistry's mutating-builtin wrapper plus a per-path lock.
          MutationLock.with_lock(key, fn ->
            MutationLock.with_lock(MutationLock.path_key(args["path"]), fn ->
              send(test_pid, {:locked_in, self()})
              %AgentToolResult{content: [%TextContent{text: "wrote #{args["path"]}"}]}
            end)
          end)
        end)

      opts = Keyword.put(ctx.opts, :tool_resolver, fn "locking" -> {:ok, locking} end)
      code = "r = await tools.locking(path='a.txt')\nprint(r['text'])"

      task =
        Task.async(fn ->
          MutationLock.with_lock(key, fn -> run(%{ctx | opts: opts}, "py", code) end)
        end)

      result = Task.await(task, 30_000)
      refute result.is_error, text(result)
      assert text(result) =~ "wrote a.txt"
      assert_received {:locked_in, inner}
      refute Process.alive?(inner)
      refute Map.has_key?(:sys.get_state(MutationLock).locks, key)
    end
  end

  describe "Session.bridge_tool/2" do
    setup do
      suffix = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      cwd = Path.join("/tmp", "lemon-eval-bridge-#{suffix}")
      File.mkdir_p!(cwd)
      session_dir = CodingAgent.SessionManager.get_session_dir(cwd)

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(session_dir)
      end)

      session =
        start_supervised!(
          {Session,
           [
             cwd: cwd,
             workspace_dir: Path.join(cwd, "workspace"),
             model: mock_model(),
             settings_manager: %SettingsManager{},
             mcp_tools: [],
             tool_policy: ToolPolicy.custom(deny: ["write"]),
             stream_fn: fn _, _, _ -> flunk("bridge tests must not call a model") end
           ]}
        )

      %{session: session, session_cwd: cwd}
    end

    test "resolves catalog tools and refuses eval, bridge and denied tools", %{session: session} do
      catalog = Session.get_state(session).tool_catalog
      assert Map.has_key?(catalog, "read")
      assert {:ok, %AgentTool{name: "read"}} = Session.bridge_tool(session, "read")

      for name <- ["eval", "write", "no_such_tool" | ToolDisclosure.bridge_names()] do
        assert Session.bridge_tool(session, name) ==
                 {:error, "unknown or unavailable tool: #{name}"}
      end

      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, _, _}
      assert Session.bridge_tool(dead, "read") == {:error, "session unavailable"}
    end

    @tag :python3
    test "the session's own eval reaches bash through the bridge under its lock", %{
      session: session,
      session_cwd: cwd
    } do
      %{tool: eval} = Session.get_state(session).tool_catalog["eval"]
      File.write!(Path.join(cwd, "marker.txt"), "bridged")

      code = """
      import asyncio
      rs = await asyncio.gather(tools.bash(command="cat marker.txt"), tools.read(path="marker.txt"))
      print([r["ok"] for r in rs], "bridged" in rs[0]["text"], "bridged" in rs[1]["text"])
      """

      result =
        eval.execute.("outer", %{"language" => "py", "code" => code, "timeout" => 30}, nil, nil)

      refute result.is_error, text(result)
      assert text(result) =~ "[True, True] True True"
    end
  end

  defp mock_model do
    %Model{
      id: "eval-bridge",
      name: "Eval Bridge",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }
  end
end
