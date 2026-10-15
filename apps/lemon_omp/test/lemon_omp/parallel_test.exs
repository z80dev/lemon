defmodule LemonOmp.ParallelTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  setup do
    use_fake_omp()
    put_app_env(:max_sessions, 4)
    key = "agent:omp-parallel:#{System.unique_integer([:positive])}"
    {:ok, owner: %{kind: :agent, session_key: key}, scope: [owner: {:session_key, key}]}
  end

  defp workers(ctx, count \\ 2) do
    tasks = for n <- 1..count, do: %{prompt: "HOLD worker #{n}", cwd: workspace!()}
    results = LemonOmp.start_many(tasks, owner: ctx.owner)
    assert is_list(results)

    Enum.map(results, fn result ->
      assert {:ok, wire} = result
      wire
    end)
  end

  test "batch tasks accept the same resume parameters as single starts", ctx do
    ws = workspace!()

    assert [{:ok, wire}] =
             LemonOmp.start_many(
               [%{cwd: ws, resume: "fake-resumed-0002", model: "fake/chosen", thinking: "low"}],
               owner: ctx.owner
             )

    assert wire["status"] == "idle"

    assert File.read!(Path.join(ws, ".fake_omp.args")) ==
             "--mode rpc --cwd #{ws} --model fake/chosen --thinking low --resume fake-resumed-0002\n"
  end

  test "all three prompts are in flight before any acknowledgement; order and cleanup", ctx do
    dirs = for _ <- 1..3, do: workspace!()
    tasks = Enum.map(dirs, &%{prompt: "ACK_GATE HOLD", cwd: &1, thinking: "low"})

    starter = Task.async(fn -> LemonOmp.start_many(tasks, owner: ctx.owner) end)

    wait_until(fn ->
      Enum.all?(dirs, fn dir -> Enum.any?(received(dir), &(&1["type"] == "prompt")) end)
    end)

    assert Enum.count(LemonOmp.list(ctx.scope), &(&1["status"] == "starting")) == 3
    assert Task.yield(starter, 0) == nil
    for dir <- dirs, do: File.write!(Path.join(dir, ".fake_omp_release"), "go")
    results = Task.await(starter, 5_000)
    wires = Enum.map(results, fn {:ok, wire} -> wire end)
    assert Enum.map(wires, & &1["cwd"]) == dirs
    assert Enum.all?(wires, &(&1["status"] == "running" and &1["thinking"] == "low"))

    for {wire, dir} <- Enum.zip(wires, dirs) do
      pid = fake_pid(dir)
      kill_on_exit(pid)
      assert {:ok, _} = LemonOmp.close(wire["id"], ctx.scope)
      wait_until(fn -> not os_alive?(pid) end)
    end
  end

  test "invalid tasks start nothing, including non-map tasks", ctx do
    ws = workspace!()
    before = LemonOmp.Manager.live_count()

    for {bad, reason} <- [
          {%{cwd: ws, prompt: " "}, :invalid_prompt},
          {%{cwd: ws, prompt: "ok", model: "bad model"}, :invalid_params},
          {%{cwd: ws, prompt: "ok", thinking: "wrong"}, :invalid_params},
          {%{cwd: "/definitely/missing", prompt: "ok"}, :invalid_cwd},
          {nil, :invalid_params}
        ] do
      assert {:error, {:invalid_task, 1, ^reason}} =
               LemonOmp.start_many([%{cwd: ws, prompt: "HOLD valid"}, bad], owner: ctx.owner)
    end

    assert LemonOmp.Manager.live_count() == before
    refute File.exists?(Path.join(ws, ".fake_omp.pid"))
  end

  test "batch exceeding remaining live slots is rejected before starting", ctx do
    put_app_env(:max_sessions, 2)
    [_] = workers(ctx, 1)
    dirs = [workspace!(), workspace!()]
    tasks = Enum.map(dirs, &%{cwd: &1, prompt: "HOLD rejected"})
    assert {:error, :too_many_sessions} = LemonOmp.start_many(tasks, owner: ctx.owner)
    for dir <- dirs, do: refute(File.exists?(Path.join(dir, ".fake_omp.pid")))
    assert LemonOmp.Manager.live_count() == 1
  end

  test "per-task rejection and outcome-unknown retain ordered results and ids", ctx do
    put_app_env(:command_timeout_ms, 300)
    dirs = [workspace!(), workspace!(), workspace!("hang")]
    [good, rejected, unknown] = dirs

    assert [{:ok, wire}, {:error, {:rejected, _}}, {:error, {:outcome_unknown, id}}] =
             LemonOmp.start_many(
               [
                 %{cwd: good, prompt: "HOLD accepted"},
                 %{cwd: rejected, prompt: "REJECT"},
                 %{cwd: unknown, prompt: "unacknowledged"}
               ],
               owner: ctx.owner
             )

    assert wire["cwd"] == good
    assert {:ok, %{"cwd" => ^unknown, "status" => "starting"}} = LemonOmp.get(id, ctx.scope)
    rejected_pid = fake_pid(rejected)
    wait_until(fn -> not os_alive?(rejected_pid) end)
  end

  test "all waits for every worker and streams complete ordered lists", ctx do
    wires = workers(ctx)
    ids = Enum.map(wires, & &1["id"])
    [first, second] = ids
    parent = self()

    task =
      Task.async(fn ->
        LemonOmp.wait_many(ids, 5_000,
          owner: ctx.scope[:owner],
          on_update: &send(parent, {:update, &1})
        )
      end)

    assert {:ok, _} = LemonOmp.send_message(first, "first done", :steer)
    await_wire(first, &(&1["status"] == "idle"))
    assert Task.yield(task, 100) == nil
    assert {:ok, _} = LemonOmp.close(second)
    assert {:ok, final, :settled} = Task.await(task, 6_000)
    assert Enum.map(final, & &1["id"]) == ids
    assert Enum.map(final, & &1["status"]) == ["idle", "closed"]
    assert_received {:update, ^final}
  end

  test "any returns when one worker settles, without stopping the others", ctx do
    [a, b] = workers(ctx)
    assert {:ok, _} = LemonOmp.cancel(a["id"])
    await_wire(a["id"], &(&1["status"] == "idle"))

    assert {:ok, [first, second], :settled} =
             LemonOmp.wait_many([a["id"], b["id"]], 1_000, mode: :any)

    assert first["lastTurn"] == "aborted"
    assert second["status"] == "running"
  end

  test "timeouts and aborts always emit final state, never cancel workers", ctx do
    wires = workers(ctx)
    ids = Enum.map(wires, & &1["id"])
    parent = self()
    update = &send(parent, {:final, &1})

    assert {:ok, final, :timeout} = LemonOmp.wait_many(ids, 50, on_update: update)
    assert_received {:final, ^final}
    assert Enum.all?(final, &(&1["status"] == "running"))

    signal = LemonAgent.AbortSignal.new()
    task = Task.async(fn -> LemonOmp.wait_many(ids, 5_000, signal: signal, on_update: update) end)
    :ok = LemonAgent.AbortSignal.abort(signal)
    assert {:ok, aborted, :aborted} = Task.await(task, 1_000)
    assert_received {:final, ^aborted}

    for wire <- wires do
      refute Enum.any?(received(wire["cwd"]), &(&1["type"] == "abort"))
    end
  end

  test "missing and foreign ids fail closed without callbacks", ctx do
    [wire] = workers(ctx, 1)
    assert {:error, :not_found} = LemonOmp.wait_many([wire["id"], "omp_missing"], 1, ctx.scope)

    assert {:error, :not_found} =
             LemonOmp.wait_many([wire["id"]], 1, owner: {:session_key, "someone_else"})

    assert {:ok, [], :settled} = LemonOmp.wait_many([], 1)
  end

  test "combined progress is throttled but always finishes with the latest full list", ctx do
    [wire] = workers(ctx, 1)
    id = wire["id"]
    parent = self()

    task =
      Task.async(fn ->
        LemonOmp.wait_many([id], 5_000,
          on_update: fn wires ->
            send(parent, {:tick, System.monotonic_time(:millisecond), wires})
          end
        )
      end)

    wait_until(fn ->
      match?(
        {:current_function, {LemonOmp, :wait_many_loop, 2}},
        Process.info(task.pid, :current_function)
      )
    end)

    # A burst spanning several throttle windows, without spawning more OS processes.
    for n <- 1..80 do
      LemonOmp.Manager.publish(
        session_pid(id),
        Map.put(wire, "activity", "progress #{n}"),
        "update"
      )

      Process.sleep(10)
    end

    assert {:ok, _} = LemonOmp.send_message(id, "finished", :steer)
    assert {:ok, [final], :settled} = Task.await(task, 6_000)
    ticks = collect_ticks([])
    assert length(ticks) >= 2
    assert length(ticks) <= 4
    assert {_, [^final]} = List.last(ticks)

    # The unconditional final callback may be less than 300 ms after progress.
    progress = Enum.drop(ticks, -1)
    for [{a, _}, {b, _}] <- Enum.chunk_every(progress, 2, 1, :discard), do: assert(b - a >= 300)
    assert final["result"] == "Steered: finished"
  end

  defp collect_ticks(acc) do
    receive do
      {:tick, time, wires} -> collect_ticks([{time, wires} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "combined usage sums all token categories and cost without modifying snapshots" do
    usage = %{
      "input" => 10,
      "output" => 5,
      "cacheRead" => 3,
      "cacheWrite" => 2,
      "totalTokens" => 20,
      "cost" => 0.25
    }

    wire = %{"usage" => usage}

    assert LemonOmp.Projection.combined_usage([wire, wire]) ==
             Map.new(usage, fn {key, value} -> {key, value * 2} end)

    assert wire["usage"] == usage
    assert LemonOmp.Projection.combined_usage([])["totalTokens"] == 0
  end
end
