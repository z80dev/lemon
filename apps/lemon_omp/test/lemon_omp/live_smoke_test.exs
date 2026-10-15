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
               "Run sleep 60 using bash now. Do not do anything else.",
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

  defp real_agent_dir! do
    # config/test.exs replaces HOME; ask the login shell's passwd-backed tilde expansion.
    {home, 0} = System.cmd("sh", ["-c", "eval echo ~\"$(id -un)\""])
    home = String.trim(home)

    assert Path.type(home) == :absolute,
           "set LEMON_OMP_LIVE_AGENT_DIR to your omp agent directory"

    Path.join(home, ".omp/agent")
  end
end
