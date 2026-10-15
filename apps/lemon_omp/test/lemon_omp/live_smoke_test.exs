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
             LemonOmp.send_message(
               id,
               "Call bash with command `sleep 60`, timeout 90 and async false. " <>
                 "This is a finite foreground command, not a service: omit the name and ready fields entirely. " <>
                 "Do not do anything else.",
               :steer
             )

    await_wire(id, &(&1["activeTools"] != []), 180_000)
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
               prompt:
                 "Call bash with command `sleep 60`, timeout 90 and async false. " <>
                   "This is a finite foreground command, not a service: omit the name and ready fields entirely. " <>
                   "Do not do anything else."
             })

    id = started["id"]
    os_pid = :sys.get_state(session_pid(id)).os_pid
    kill_on_exit(os_pid)

    await_wire(id, &(&1["activeTools"] != []), 180_000)

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
                 "First run sleep 30 using bash. After it finishes, use write to create restored.txt containing exactly ok. Then stop."
             })

    id = started["id"]
    os_pid = :sys.get_state(session_pid(id)).os_pid
    kill_on_exit(os_pid)

    await_wire(
      id,
      fn wire ->
        Enum.any?(wire["activeTools"], &String.contains?(&1["name"], "bash"))
      end,
      180_000
    )

    assert {_, 0} = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    crashed = await_wire(id, &(&1["status"] == "failed"), 20_000)
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

    assert {:ok, started} =
             LemonOmp.start(
               %{
                 cwd: ctx.cwd,
                 model: ctx.model,
                 thinking: "off",
                 approval_mode: "always-ask",
                 prompt:
                   "Use the write tool to create approved.txt containing exactly yes. Then stop."
               },
               owner: owner
             )

    id = started["id"]
    assert started["approvalMode"] == "always-ask"
    pending = await_approval(id, 180_000)
    assert pending.session_key == owner.session_key
    assert String.starts_with?(pending.tool, "omp:")
    wire = await_wire(id, &(&1["pendingApprovals"] != []), 5_000)
    assert wire["activity"] =~ "Waiting for approval"

    assert {:ok, %{outcome: :approved}} =
             LemonCore.ExecApprovals.resolve(pending.id, :approve_once)

    assert {:ok, approved, :settled} = LemonOmp.wait(id, 180_000)
    assert approved["lastTurn"] == "completed"
    assert approved["approvals"]["approved"] >= 1
    assert approved["pendingApprovals"] == []
    assert File.read!(Path.join(ctx.cwd, "approved.txt")) == "yes"

    # Deny every approval for the next turn: the model may retry another way.
    denier = spawn_link(fn -> deny_all(id) end)

    assert {:ok, _} =
             LemonOmp.send_message(
               id,
               "Use the write tool to create denied.txt containing exactly no. If it is denied, stop.",
               :steer
             )

    assert {:ok, denied, :settled} = LemonOmp.wait(id, 180_000)
    Process.unlink(denier)
    Process.exit(denier, :kill)
    assert denied["approvals"]["denied"] >= 1
    refute File.exists?(Path.join(ctx.cwd, "denied.txt"))
    assert {:ok, %{"status" => "closed"}} = LemonOmp.close(id)
  end

  test "real omp parallel workers start together and gather", ctx do
    dirs =
      for name <- ["alpha", "beta"] do
        dir = Path.join(ctx.cwd, name)
        File.mkdir_p!(dir)
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

  defp await_approval(id, timeout) do
    receive do
      %LemonCore.Event{
        type: :approval_requested,
        payload: %{pending: %{action: action} = pending}
      } ->
        if action["ompSession"] == id, do: pending, else: await_approval(id, timeout)
    after
      timeout -> flunk("omp never asked for approval")
    end
  end

  defp deny_all(id) do
    LemonCore.Bus.subscribe("exec_approvals")

    for {_id, _pid, wire} <- LemonOmp.Manager.all(),
        wire["id"] == id,
        approval <- wire["pendingApprovals"] || [] do
      LemonCore.ExecApprovals.resolve(approval["id"], :deny)
    end

    deny_loop(id)
  end

  defp deny_loop(id) do
    receive do
      %LemonCore.Event{
        type: :approval_requested,
        payload: %{pending: %{action: action} = pending}
      } ->
        if action["ompSession"] == id, do: LemonCore.ExecApprovals.resolve(pending.id, :deny)
        deny_loop(id)

      _other ->
        deny_loop(id)
    end
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
