defmodule LemonOmp.LiveSmokeTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  @moduletag :omp_live
  @moduletag timeout: 800_000
  @free_model "openrouter/nvidia/nemotron-3-super-120b-a12b:free"

  setup do
    executable = System.get_env("LEMON_OMP_BIN") || System.find_executable("omp")
    assert executable, "install omp or set LEMON_OMP_BIN"
    put_app_env(:executable, executable)

    agent_dir = System.get_env("LEMON_OMP_LIVE_AGENT_DIR") || real_agent_dir!()
    previous = System.get_env("PI_CODING_AGENT_DIR")
    System.put_env("PI_CODING_AGENT_DIR", agent_dir)

    on_exit(fn ->
      close_all_sessions()

      if previous,
        do: System.put_env("PI_CODING_AGENT_DIR", previous),
        else: System.delete_env("PI_CODING_AGENT_DIR")
    end)

    model = System.get_env("LEMON_OMP_LIVE_MODEL") || @free_model
    assert String.ends_with?(model, ":free"), "live smoke only permits zero-cost :free models"
    cwd = tmp_dir!("lemon_omp_live")
    assert {_, 0} = System.cmd("git", ["init", "--quiet", cwd])
    File.write!(Path.join(cwd, "README.md"), "Tiny omp smoke workspace.\n")
    pin_free_models!(%{cwd: cwd, model: model, agent_dir: agent_dir})
    {:ok, cwd: cwd, model: model, agent_dir: agent_dir}
  end

  test "real omp catalog includes the free smoke model" do
    assert {:ok, models} = LemonOmp.models(free_only: true, limit: 200)
    assert Enum.any?(models, &(&1["selector"] == @free_model and &1["free"]))
  end

  test "real omp writes, follows up, cancels, closes, discovers and resumes", ctx do
    assert {:ok, started} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               model: ctx.model,
               thinking: "off",
               approval_mode: "yolo",
               prompt: "Use the write tool to create hello.txt containing exactly hi. Then stop."
             })

    id = started["id"]
    os_pid = :sys.get_state(session_pid(id)).os_pid
    kill_on_exit(os_pid)
    test_pid = self()

    assert {:ok, first, :settled} =
             LemonOmp.wait(id, 180_000,
               on_update: fn wire -> send(test_pid, {:progress, wire}) end
             )

    assert first["status"] == "idle"
    assert first["lastTurn"] == "completed"
    assert File.read!(Path.join(ctx.cwd, "hello.txt")) == "hi"
    assert first["toolCalls"] >= 1
    assert Enum.any?(first["recentTools"], &String.contains?(&1["name"], "write"))
    assert first["usage"]["totalTokens"] > 0
    assert is_binary(first["ompSessionId"]) and first["ompSessionId"] != ""
    assert_receive {:progress, %{"status" => "running"}}, 1_000

    assert {:ok, _} =
             LemonOmp.send_message(
               id,
               "Use write to create second.txt containing exactly two. Then stop.",
               :steer
             )

    assert {:ok, second, :settled} = LemonOmp.wait(id, 180_000)
    assert second["lastTurn"] == "completed"
    assert File.read!(Path.join(ctx.cwd, "second.txt")) == "two"
    assert second["turns"] > first["turns"]

    assert {:ok, _} =
             LemonOmp.send_message(id, bash_prompt(ctx, "cancel.started"), :steer)

    await_bash(id, ctx, "cancel.started", second["toolCalls"])
    assert {:ok, _} = LemonOmp.cancel(id)
    assert {:ok, cancelled, :settled} = LemonOmp.wait(id, 20_000)
    assert cancelled["status"] == "idle"
    assert cancelled["lastTurn"] == "aborted"
    assert os_alive?(os_pid)

    assert {:ok, %{"status" => "closed"}} = LemonOmp.close(id)
    wait_until(fn -> not os_alive?(os_pid) end, 20_000)
    omp_id = first["ompSessionId"]

    assert {:ok, sessions} =
             LemonOmp.discover(ctx.cwd, sessions_dir: Path.join(ctx.agent_dir, "sessions"))

    assert Enum.any?(sessions, &(&1["ompSessionId"] == omp_id))

    assert {:ok, resumed} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               model: ctx.model,
               thinking: "off",
               resume: omp_id,
               prompt: "Use write to create resumed.txt containing exactly back. Then stop."
             })

    assert {:ok, final, :settled} = LemonOmp.wait(resumed["id"], 180_000)
    assert final["lastTurn"] == "completed"
    assert final["ompSessionId"] == omp_id
    assert File.read!(Path.join(ctx.cwd, "resumed.txt")) == "back"
    assert {:ok, %{"status" => "closed"}} = LemonOmp.close(resumed["id"])
  end

  test "real omp redirects an active bash tool into a completed write turn", ctx do
    assert {:ok, started} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               model: ctx.model,
               thinking: "off",
               approval_mode: "yolo",
               prompt: bash_prompt(ctx, "redirect.started")
             })

    id = started["id"]
    os_pid = :sys.get_state(session_pid(id)).os_pid
    kill_on_exit(os_pid)

    await_bash(id, ctx, "redirect.started")

    parent = self()

    waiter =
      Task.async(fn ->
        LemonOmp.wait(id, 180_000,
          on_update: fn wire -> send(parent, {:redirect_progress, wire}) end
        )
      end)

    assert_receive {:redirect_progress, %{"status" => "running"}}

    assert {:ok, %{"delivery" => "redirect"}} =
             LemonOmp.send_message(
               id,
               "Stop that. Instead create redirected.txt containing exactly ok using the write tool, then stop.",
               :redirect
             )

    assert {:ok, final, :settled} = Task.await(waiter, 190_000)
    assert final["status"] == "idle"
    assert final["lastTurn"] == "completed"
    assert File.read!(Path.join(ctx.cwd, "redirected.txt")) == "ok"
    assert Enum.any?(final["recentTools"], &String.contains?(&1["name"], "write"))
    assert {:ok, %{"status" => "closed"}} = LemonOmp.close(id)
    wait_until(fn -> not os_alive?(os_pid) end, 20_000)
  end

  test "explicit continuation starts a new turn on the same history after SIGKILL", ctx do
    assert {:ok, started} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               model: ctx.model,
               thinking: "off",
               approval_mode: "yolo",
               prompt:
                 bash_prompt(ctx, "continue.started") <>
                   " After bash finishes, use write to create restored.txt containing exactly ok. Then stop."
             })

    id = started["id"]
    os_pid = :sys.get_state(session_pid(id)).os_pid
    kill_on_exit(os_pid)

    await_bash(id, ctx, "continue.started")
    refute File.exists?(Path.join(ctx.cwd, "restored.txt"))

    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    crashed = await_live_wire(id, &(&1["status"] == "failed"), ctx, 20_000)
    assert is_binary(crashed["ompSessionId"])

    assert {:ok, resumed} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               resume: crashed["ompSessionId"],
               continue: true,
               model: ctx.model,
               thinking: "off",
               approval_mode: "yolo"
             })

    # The free model can loop on an interrupted bash transcript. Assert the
    # headless contract we actually provide, not native --restore recovery:
    # an acknowledged new turn on the crashed session's persisted history.
    assert resumed["status"] == "running"
    assert resumed["ompSessionId"] == crashed["ompSessionId"]
    assert resumed["id"] != crashed["id"]
    assert {:ok, _} = LemonOmp.cancel(resumed["id"])
    assert {:ok, stopped, :settled} = LemonOmp.wait(resumed["id"], 20_000)
    assert stopped["status"] == "idle"
  end

  test "real omp tool approvals round-trip through Lemon's shared approvals", ctx do
    put_app_env(:approvals, :bridge)
    LemonCore.Bus.subscribe("exec_approvals")
    on_exit(fn -> LemonCore.Bus.unsubscribe("exec_approvals") end)
    owner = %{kind: :agent, session_key: "agent:omp-live:#{System.unique_integer([:positive])}"}
    approve_prompt = write_prompt("approved.txt", "yes")

    assert {:ok, started} =
             LemonOmp.start(
               %{
                 cwd: ctx.cwd,
                 model: ctx.model,
                 thinking: "off",
                 approval_mode: "always-ask",
                 prompt: approve_prompt
               },
               owner: owner
             )

    id = started["id"]
    assert started["approvalMode"] == "always-ask"
    pending = await_pending_approval(id, ctx, approve_prompt)
    assert pending.session_key == owner.session_key
    assert pending.tool == "omp:write"
    wire = await_live_wire(id, &(&1["pendingApprovals"] != []), ctx, 5_000)
    assert wire["activity"] =~ "Waiting for approval"

    assert {:ok, %{outcome: :approved}} =
             LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

    approved = settle_with_approvals(id, ctx, :approve_once)
    assert approved["lastTurn"] == "completed"
    assert approved["approvals"]["approved"] >= 1
    assert approved["pendingApprovals"] == []
    assert File.read!(Path.join(ctx.cwd, "approved.txt")) == "yes"

    deny_prompt = write_prompt("denied.txt", "no")
    assert {:ok, _} = LemonOmp.send_message(id, deny_prompt, :steer)
    pending = await_pending_approval(id, ctx, deny_prompt, approved["toolCalls"])
    assert pending.session_key == owner.session_key
    assert pending.tool == "omp:write"
    assert {:ok, %{outcome: :denied}} = LemonCore.ExecApprovals.resolve(pending.id, :deny)

    denied = settle_with_approvals(id, ctx, :deny)
    assert denied["lastTurn"] == "completed", live_diagnostics(id, ctx)
    assert denied["approvals"]["denied"] >= 1, live_diagnostics(id, ctx)
    assert denied["pendingApprovals"] == []
    refute File.exists?(Path.join(ctx.cwd, "denied.txt"))

    assert {:ok, %{"status" => "closed"}} = LemonOmp.close(id)
  end

  test "real omp parallel workers start together and gather", ctx do
    dirs =
      for name <- ["alpha", "beta"] do
        dir = Path.join(ctx.cwd, name)
        File.mkdir_p!(dir)
        pin_free_models!(%{ctx | cwd: dir})
        {name, dir}
      end

    tasks =
      for {name, dir} <- dirs do
        %{
          cwd: dir,
          model: ctx.model,
          thinking: "off",
          approval_mode: "yolo",
          prompt:
            "Use the write tool to create #{name}.txt containing exactly #{name}. Then stop."
        }
      end

    results = LemonOmp.start_many(tasks)
    assert [{:ok, a}, {:ok, b}] = results
    test_pid = self()

    assert {:ok, wires, :settled} =
             LemonOmp.wait_many([a["id"], b["id"]], 240_000,
               on_update: fn wires -> send(test_pid, {:progress, wires}) end
             )

    assert Enum.all?(wires, &(&1["lastTurn"] == "completed"))
    assert_receive {:progress, [_, _]}, 1_000

    for {name, dir} <- dirs do
      assert File.read!(Path.join(dir, "#{name}.txt")) == name
    end

    assert LemonOmp.Projection.combined_usage(wires)["totalTokens"] > 0
    for wire <- wires, do: assert({:ok, _} = LemonOmp.close(wire["id"]))
  end

  test "real omp isolates parallel workers and keeps their uncommitted files", ctx do
    assert {_, 0} = System.cmd("git", ["-C", ctx.cwd, "add", "."])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               ctx.cwd,
               "-c",
               "user.name=Smoke",
               "-c",
               "user.email=smoke@example.invalid",
               "commit",
               "--quiet",
               "-m",
               "smoke base"
             ])

    tasks =
      for name <- ["alpha", "beta"] do
        %{
          cwd: ctx.cwd,
          isolate: true,
          model: ctx.model,
          thinking: "off",
          approval_mode: "yolo",
          prompt:
            "Use the write tool to create #{name}.txt containing exactly #{name}. Do not commit. Then stop."
        }
      end

    assert [{:ok, a}, {:ok, b}] = LemonOmp.start_many(tasks)
    refute a["cwd"] == b["cwd"]
    for wire <- [a, b], do: kill_on_exit(:sys.get_state(session_pid(wire["id"])).os_pid)
    assert {:ok, wires, :settled} = LemonOmp.wait_many([a["id"], b["id"]], 240_000)

    for {wire, name, other} <- [{hd(wires), "alpha", "beta"}, {List.last(wires), "beta", "alpha"}] do
      assert wire["lastTurn"] == "completed"
      assert File.read!(Path.join(wire["cwd"], "#{name}.txt")) == name
      refute File.exists?(Path.join(wire["cwd"], "#{other}.txt"))
      refute File.exists?(Path.join(ctx.cwd, "#{name}.txt"))
      os_pid = :sys.get_state(session_pid(wire["id"])).os_pid
      assert {:ok, ended} = LemonOmp.close(wire["id"])
      assert ended["worktree"]["kept"] == true
      assert ended["worktree"]["dirty"] > 0
      assert File.dir?(ended["worktree"]["path"])
      wait_until(fn -> not os_alive?(os_pid) end, 20_000)
    end
  end

  test "real omp task subagents expose progress and transcript tails", ctx do
    assert {:ok, started} =
             LemonOmp.start(%{
               cwd: ctx.cwd,
               model: ctx.model,
               thinking: "off",
               approval_mode: "yolo",
               prompt:
                 "Use the task tool to spawn exactly one subagent for this trivial job: " <>
                   "create sub.txt containing exactly sub. Use agent task, whose model is " <>
                   "configured to the same free model as you. Wait for that subagent to finish, then stop."
             })

    id = started["id"]
    kill_on_exit(:sys.get_state(session_pid(id)).os_pid)
    assert {:ok, wire, :settled} = LemonOmp.wait(id, 240_000)

    case wire["subagents"] do
      [] ->
        # Free models can decline/mis-call task or implement the job themselves.
        # Keep provider compliance separate from deterministic protocol coverage.
        IO.puts(
          "omp subagent live assertion conditional: free model #{ctx.model} did not spawn " <>
            "an observable task child (lastTurn=#{wire["lastTurn"]}); fake omp tests cover the protocol."
        )

      [sub | _] ->
        assert is_binary(sub["id"]) and sub["id"] != ""
        assert is_binary(sub["agent"]) and sub["agent"] != ""
        assert sub["status"] in ["running", "completed", "failed", "aborted"]
        assert {:ok, transcript} = LemonOmp.subagent(id, sub["id"])
        assert transcript["messages"] != []
        assert Enum.all?(transcript["messages"], &(String.length(&1["text"]) <= 2000))
    end

    assert {:ok, _} = LemonOmp.close(id)
  end

  defp bash_prompt(ctx, marker) do
    args = %{
      i: "Starting foreground smoke command",
      command: "touch #{marker} && sleep 60",
      cwd: ctx.cwd,
      timeout: 90,
      async: false,
      pty: false,
      name: "",
      ready: nil
    }

    "Call the bash tool now with exactly these JSON arguments: #{Jason.encode!(args)}. " <>
      "This is a finite foreground command, not a service. " <>
      "The name must be the empty string and ready must be null, not a readiness object. " <>
      "Do not substitute another tool or answer without making this tool call."
  end

  defp write_prompt(path, content) do
    args = %{i: "Writing smoke file", path: path, content: content}

    "Call the write tool now with exactly these JSON arguments: #{Jason.encode!(args)}. " <>
      "Actually attempt the call; do not predict whether approval will be granted. " <>
      "After the tool result, stop. If denied, do not retry or use another tool."
  end

  defp await_bash(id, ctx, marker, baseline \\ 0) do
    await_action(id, ctx, %{
      tool: "bash",
      baseline: baseline,
      prompt: bash_prompt(ctx, marker),
      observed?: fn wire ->
        File.exists?(Path.join(ctx.cwd, marker)) and
          Enum.any?(wire["activeTools"], &(&1["name"] == "bash"))
      end
    })
  end

  defp await_pending_approval(id, ctx, prompt, baseline \\ 0) do
    wire =
      await_action(id, ctx, %{
        tool: "write",
        baseline: baseline,
        prompt: prompt,
        observed?: fn wire -> Enum.any?(wire["pendingApprovals"], &(&1["tool"] == "write")) end
      })

    approval = Enum.find(wire["pendingApprovals"], &(&1["tool"] == "write"))
    await_approval(id, approval["id"], ctx)
  end

  defp await_action(id, ctx, action) do
    deadline = System.monotonic_time(:millisecond) + 180_000
    do_await_action(id, ctx, action, [], deadline)
  end

  defp do_await_action(id, ctx, action, attempts, deadline) do
    {:ok, wire} = LemonOmp.get(id)
    attempt = Map.take(wire, ~w(status lastTurn lastText toolCalls recentTools error))

    cond do
      action.observed?.(wire) ->
        wire

      wire["status"] == "idle" and wire["lastTurn"] == "completed" and
        not called_tool?(wire, action.tool, action.baseline) and attempts == [] and
          System.monotonic_time(:millisecond) < deadline ->
        IO.puts(
          "omp live #{action.tool}: attempt 1/2 completed without the required tool; re-prompting"
        )

        assert {:ok, _} = LemonOmp.send_message(id, action.prompt, :steer)
        action = %{action | baseline: wire["toolCalls"]}
        do_await_action(id, ctx, action, [attempt], deadline)

      wire["status"] in ["idle", "closed", "failed"] or
          System.monotonic_time(:millisecond) >= deadline ->
        flunk(
          "required #{action.tool} action not observed (max 2 attempts): " <>
            inspect(attempts ++ [attempt], pretty: true, printable_limit: 4_000) <>
            "\n" <> live_diagnostics(id, ctx)
        )

      true ->
        Process.sleep(20)
        do_await_action(id, ctx, action, attempts, deadline)
    end
  end

  defp called_tool?(wire, name, baseline) do
    wire["recentTools"]
    |> Enum.take(-(wire["toolCalls"] - baseline))
    |> Enum.any?(&(&1["name"] == name))
  end

  defp await_live_wire(id, pred, ctx, timeout) do
    await_wire(id, pred, timeout)
  rescue
    error in ExUnit.AssertionError ->
      flunk(Exception.message(error) <> "\n" <> live_diagnostics(id, ctx))
  end

  defp live_diagnostics(id, ctx) do
    {:ok, wire} = LemonOmp.get(id)

    snapshot =
      Map.take(wire, ~w(status lastText activeTools recentTools lastTurn error approvals))

    "omp live snapshot: #{inspect(snapshot, pretty: true, printable_limit: 8_000)}\n" <>
      "omp session transcript tail: #{inspect(transcript_tail(wire, ctx), printable_limit: 12_000)}"
  end

  defp transcript_tail(wire, ctx) do
    sessions_dir = Path.join(ctx.agent_dir, "sessions")

    with {:ok, sessions} <- LemonOmp.discover(wire["cwd"], sessions_dir: sessions_dir),
         %{"cwd" => cwd} <-
           Enum.find(sessions, &(&1["ompSessionId"] == wire["ompSessionId"])),
         {canonical, 0} <- System.cmd("realpath", [cwd], stderr_to_stdout: true) do
      canonical
      |> String.trim()
      |> LemonOmp.SessionFiles.candidate_dir_names(wire["cwd"])
      |> Enum.find_value(fn name ->
        dir = Path.join(sessions_dir, name)

        with {:ok, names} <- File.ls(dir),
             name when is_binary(name) <-
               Enum.find(names, &String.ends_with?(&1, "_#{wire["ompSessionId"]}.jsonl")),
             path = Path.join(dir, name),
             {:ok, %{size: size}} <- File.stat(path),
             {:ok, io} <- File.open(path, [:read, :binary]) do
          tail = :file.pread(io, max(size - 8_192, 0), 8_192)
          File.close(io)
          tail
        else
          _ -> nil
        end
      end)
    else
      other -> {:not_discovered, other}
    end
  end

  defp await_approval(id, approval_id, ctx) do
    receive do
      %LemonCore.Event{
        type: :approval_requested,
        payload: %{pending: %{id: ^approval_id, action: %{"ompSession" => ^id}} = pending}
      } ->
        pending
    after
      5_000 -> flunk("omp never asked for approval\n" <> live_diagnostics(id, ctx))
    end
  end

  defp settle_with_approvals(id, ctx, decision) do
    # A free model may repeat a successful call, or try another after a denial.
    # Answer every request in this turn, without installing a session grant.
    responder = spawn_link(fn -> resolve_all(id, decision) end)

    try do
      assert {:ok, wire, :settled} = LemonOmp.wait(id, 180_000), live_diagnostics(id, ctx)
      wire
    after
      Process.unlink(responder)
      Process.exit(responder, :kill)
    end
  end

  defp resolve_all(id, decision) do
    LemonCore.Bus.subscribe("exec_approvals")

    for {_id, _pid, wire} <- LemonOmp.Manager.all(),
        wire["id"] == id,
        approval <- wire["pendingApprovals"] || [] do
      LemonCore.ExecApprovals.resolve(approval["id"], decision)
    end

    resolve_loop(id, decision)
  end

  defp resolve_loop(id, decision) do
    receive do
      %LemonCore.Event{
        type: :approval_requested,
        payload: %{pending: %{action: action} = pending}
      } ->
        if action["ompSession"] == id, do: LemonCore.ExecApprovals.resolve(pending.id, decision)
        resolve_loop(id, decision)

      _other ->
        resolve_loop(id, decision)
    end
  end

  defp pin_free_models!(ctx) do
    # The task model is not a task-call parameter. Pin its configured role and
    # override (plus tiny labels/advisor roles), and disable paid retry fallback.
    # Disable user-defined agents so their frontmatter cannot select a paid model.
    disabled =
      case File.ls(Path.join(ctx.agent_dir, "agents")) do
        {:ok, names} -> for name <- names, String.ends_with?(name, ".md"), do: Path.rootname(name)
        {:error, :enoent} -> []
      end

    config = %{
      "modelRoles" => Map.new(~w(default task smol slow plan tiny advisor), &{&1, ctx.model}),
      "retry" => %{"modelFallback" => false},
      "advisor" => %{"enabled" => false},
      "task" => %{
        "agentModelOverrides" => %{"task" => ctx.model},
        "agentAdvisor" => %{"task" => "off"},
        "agentPrewalk" => %{"task" => "off"},
        "prewalk" => false,
        "disabledAgents" => disabled
      }
    }

    File.mkdir_p!(Path.join(ctx.cwd, ".omp"))
    # JSON is valid YAML; config.yml owns native per-project model-role overrides.
    File.write!(Path.join(ctx.cwd, ".omp/config.yml"), Jason.encode!(config))
  end

  defp real_agent_dir! do
    # config/test.exs replaces HOME; ask the login shell's passwd-backed tilde expansion.
    {home, 0} = System.cmd("sh", ["-c", "eval echo ~\"$(id -un)\""])
    home = String.trim(home)

    assert Path.type(home) == :absolute,
           "set LEMON_OMP_LIVE_AGENT_DIR to your omp agent directory"

    Path.join(home, ".omp/agent")
  end
end
