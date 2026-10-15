defmodule LemonOmp.SessionLifecycleTest do
  # Spawns real OS processes (the fake omp) and shares the live-session cap.
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonCore.Event

  setup do
    use_fake_omp()
    key = "agent:omp-test:#{System.unique_integer([:positive])}"
    {:ok, key: key, owner: %{kind: :agent, session_key: key}, scope: [owner: {:session_key, key}]}
  end

  defp start!(ws, prompt, ctx, extra \\ %{}) do
    assert {:ok, wire} =
             LemonOmp.start(Map.merge(%{"prompt" => prompt, "cwd" => ws}, extra),
               owner: ctx.owner
             )

    wire
  end

  defp received_types(ws), do: ws |> received() |> Enum.map(& &1["type"])

  describe "status and validation" do
    test "status reports the installed binary and its version" do
      status = LemonOmp.status()

      assert status["available"] == true
      assert status["version"] == "omp 0.0.0-fake (test double)"
      assert status["reason"] == nil
      assert is_integer(status["live"])
      assert status["maxSessions"] == LemonOmp.Config.max_sessions()
    end

    test "a missing binary is not installed" do
      put_app_env(:executable, Path.join(tmp_dir!(), "no/omp"))

      assert %{"available" => false, "version" => nil, "reason" => "not_installed"} =
               LemonOmp.status()

      assert {:error, :not_installed} = LemonOmp.start(%{"prompt" => "hi", "cwd" => tmp_dir!()})
      assert LemonOmp.error_message(:not_installed) =~ "not installed"
    end

    test "start validates its parameters before spawning anything", ctx do
      ws = workspace!()

      assert {:error, :invalid_prompt} = LemonOmp.start(%{cwd: ws}, owner: ctx.owner)

      assert {:error, :invalid_prompt} =
               LemonOmp.start(%{cwd: ws, prompt: "   "}, owner: ctx.owner)

      assert {:error, :invalid_prompt} =
               LemonOmp.start(%{cwd: ws, prompt: String.duplicate("x", 65_537)}, owner: ctx.owner)

      assert {:error, :invalid_cwd} =
               LemonOmp.start(%{cwd: Path.join(ws, "missing"), prompt: "hi"})

      assert {:error, :invalid_cwd} = LemonOmp.start(%{prompt: "hi"})

      assert {:error, :invalid_params} =
               LemonOmp.start(%{cwd: ws, prompt: "hi", model: "bad model!"})

      assert {:error, :invalid_params} =
               LemonOmp.start(%{cwd: ws, prompt: "hi", thinking: "ultra"})

      assert {:error, :invalid_params} = LemonOmp.start(%{cwd: ws, resume: "../../etc"})

      assert {:error, :invalid_message} = LemonOmp.send_message("omp_nope", "  ", :steer)

      assert {:error, :invalid_message} =
               LemonOmp.send_message("omp_nope", String.duplicate("x", 16_385), :steer)

      assert {:error, :not_found} = LemonOmp.send_message("omp_nope", "hi", :steer)
      assert {:error, :not_found} = LemonOmp.cancel("omp_nope")
      assert {:error, :not_found} = LemonOmp.close("omp_nope")
      assert {:error, :not_found} = LemonOmp.get("omp_nope")
      assert {:error, :not_found} = LemonOmp.wait("omp_nope", 10)

      refute File.exists?(Path.join(ws, ".fake_omp.pid"))
    end
  end

  describe "a turn" do
    test "start returns a running snapshot, publishes on the bus and settles with results", ctx do
      LemonCore.Bus.subscribe(LemonOmp.bus_topic())
      on_exit(fn -> LemonCore.Bus.unsubscribe(LemonOmp.bus_topic()) end)
      ws = workspace!()

      wire =
        start!(ws, "Write the tests\nwith care", ctx, %{
          "model" => "fake/fake-model",
          "thinking" => "low"
        })

      id = wire["id"]

      assert id =~ ~r/\Aomp_[0-9a-f]{12}\z/
      assert wire["status"] == "running"
      assert wire["title"] == "Write the tests"
      assert wire["cwd"] == ws
      assert wire["model"] == "fake/fake-model"
      assert wire["thinking"] == "low"
      assert wire["owner"] == %{"kind" => "agent", "sessionKey" => ctx.key}

      assert_receive %Event{
        type: :omp_session,
        payload: %{"reason" => "started", "session" => %{"id" => ^id}}
      }

      assert_receive %Event{
                       type: :omp_session,
                       payload: %{"reason" => "settled", "session" => %{"id" => ^id} = settled}
                     },
                     5_000

      assert settled["status"] == "idle"
      assert settled["lastTurn"] == "completed"
      assert settled["result"] == "Done: Write the tests\nwith care"
      assert settled["turns"] == 1
      assert settled["toolCalls"] == 1
      assert settled["activeTools"] == []

      assert [%{"name" => "todo", "intent" => "Tracking tasks", "isError" => false}] =
               settled["recentTools"]

      assert settled["todos"] == [
               %{"phase" => "Tasks", "content" => "Read README.md", "status" => "completed"},
               %{"phase" => "Tasks", "content" => "Write tests", "status" => "in_progress"}
             ]

      assert settled["usage"]["totalTokens"] == 170
      assert settled["usage"]["cost"] == 0.0012

      # omp's own totals replace the accumulated usage once refreshed.
      stats = await_wire(id, &(&1["usage"]["totalTokens"] == 189))

      assert stats["usage"] == %{
               "input" => 111,
               "output" => 22,
               "cacheRead" => 55,
               "cacheWrite" => 1,
               "totalTokens" => 189,
               "cost" => 0.5
             }

      assert stats["ompSessionId"] == "fake-session-0001"
      assert stats["contextPercent"] == 12.35

      assert {:ok, summary} = LemonOmp.summary(id)
      assert summary =~ "Status: idle (last turn completed"
      assert summary =~ "todos 1/2 done"

      assert File.read!(Path.join(ws, ".fake_omp.args")) ==
               "--mode rpc --cwd #{ws} --model fake/fake-model --thinking low\n"

      assert "set_subagent_subscription" in received_types(ws)

      assert Enum.any?(
               received(ws),
               &match?(%{"type" => "prompt", "message" => "Write the tests\nwith care"}, &1)
             )

      # An idle session settles a wait at once.
      assert {:ok, %{"id" => ^id, "status" => "idle"}, :settled} = LemonOmp.wait(id, 1_000)
    end

    test "send delivers a prompt when idle, steer or follow-up while running", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD this turn", ctx)["id"]
      assert %{"status" => "running"} = await_wire(id, &(&1["activity"] =~ "todo"))

      assert {:ok, %{"delivery" => "followUp"}} =
               LemonOmp.send_message(id, "queue this", :follow_up, ctx.scope)

      assert {:ok, %{"delivery" => "steer"}} =
               LemonOmp.send_message(id, "go left", :steer, ctx.scope)

      idle = await_wire(id, &(&1["status"] == "idle"))
      assert idle["result"] == "Steered: go left"

      assert {:ok, %{"delivery" => "prompt"}} =
               LemonOmp.send_message(id, "next task", :steer, ctx.scope)

      idle = await_wire(id, &(&1["status"] == "idle" and &1["result"] == "Done: next task"))
      assert idle["lastTurn"] == "completed"

      sent = received(ws)
      assert Enum.any?(sent, &match?(%{"type" => "follow_up", "message" => "queue this"}, &1))
      assert Enum.any?(sent, &match?(%{"type" => "steer", "message" => "go left"}, &1))
      assert Enum.any?(sent, &match?(%{"type" => "prompt", "message" => "next task"}, &1))
    end

    test "redirect keeps existing waits running across abort, acknowledgement and the new turn",
         ctx do
      ws = workspace!()
      id = start!(ws, "HOLD the wrong turn", ctx)["id"]
      await_wire(id, &(&1["activeTools"] != []))
      parent = self()

      waiter =
        Task.async(fn ->
          LemonOmp.wait(id, 10_000,
            on_update: fn wire -> send(parent, {:redirect_update, wire}) end
          )
        end)

      assert_receive {:redirect_update, %{"status" => "running"}}
      many = Task.async(fn -> LemonOmp.wait_many([id], 10_000) end)

      wait_until(fn ->
        match?(
          {:current_function, {LemonOmp, :wait_many_loop, 2}},
          Process.info(many.pid, :current_function)
        )
      end)

      sender =
        Task.async(fn ->
          LemonOmp.send_message(id, "REDIRECT_GATE new task", :redirect, ctx.scope)
        end)

      aborted = await_wire(id, &(&1["lastTurn"] == "aborted"))
      assert aborted["status"] == "running"
      assert aborted["activeTools"] == []
      assert Task.yield(sender, 100) == nil
      assert Task.yield(waiter, 0) == nil
      assert Task.yield(many, 0) == nil

      File.write!(Path.join(ws, ".fake_omp_redirect_ack"), "")
      assert {:ok, %{"delivery" => "redirect"}} = Task.await(sender)

      # Even the old turn's fallback timer cannot settle a redirect awaiting start.
      assert Task.yield(waiter, 2_100) == nil
      assert {:ok, %{"status" => "running"}} = LemonOmp.get(id)
      File.write!(Path.join(ws, ".fake_omp_redirect_start"), "")
      await_wire(id, &(&1["turns"] == 2 and &1["activeTools"] != []))
      refute :sys.get_state(session_pid(id)).projection.settling
      assert Task.yield(waiter, 0) == nil

      File.write!(Path.join(ws, ".fake_omp_redirect_finish"), "")

      assert {:ok, final, :settled} = Task.await(waiter)
      assert final["status"] == "idle"
      assert final["lastTurn"] == "completed"
      assert final["result"] == "Redirected: REDIRECT_GATE new task"
      assert {:ok, [^final], :settled} = Task.await(many)

      assert [%{"type" => "abort_and_prompt", "message" => "REDIRECT_GATE new task"}] =
               Enum.filter(received(ws), &(&1["type"] == "abort_and_prompt"))

      refute "abort" in received_types(ws)
    end

    test "a redirect acknowledged after the new turn finishes does not reopen it", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD the old turn", ctx)["id"]
      await_wire(id, &(&1["activeTools"] != []))

      assert {:ok, %{"delivery" => "redirect"}} =
               LemonOmp.send_message(id, "LATE_REDIRECT new task", :redirect, ctx.scope)

      assert {:ok,
              %{"status" => "idle", "lastTurn" => "completed", "result" => "Redirected early"},
              :settled} = LemonOmp.wait(id, 3_000, ctx.scope)
    end

    test "an unacknowledged redirect does not hold an aborted session running", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD the old turn", ctx)["id"]
      await_wire(id, &(&1["activeTools"] != []))
      put_app_env(:command_timeout_ms, 300)

      assert {:error, :outcome_unknown} =
               LemonOmp.send_message(id, "REDIRECT_GATE new task", :redirect, ctx.scope)

      idle = await_wire(id, &(&1["status"] == "idle"), 4_000)
      assert idle["lastTurn"] == "aborted"

      # omp may still start the redirected turn later; its events win.
      File.write!(Path.join(ws, ".fake_omp_redirect_ack"), "")
      File.write!(Path.join(ws, ".fake_omp_redirect_start"), "")
      await_wire(id, &(&1["status"] == "running"))
      File.write!(Path.join(ws, ".fake_omp_redirect_finish"), "")
      await_wire(id, &(&1["status"] == "idle" and &1["lastTurn"] == "completed"))
    end

    test "redirect on an idle session delivers a plain prompt", ctx do
      ws = workspace!()
      id = start!(ws, "first task", ctx)["id"]
      await_wire(id, &(&1["status"] == "idle"))

      assert {:ok, %{"delivery" => "prompt"}} =
               LemonOmp.send_message(id, "replacement task", :redirect, ctx.scope)

      final = await_wire(id, &(&1["result"] == "Done: replacement task"))
      assert final["lastTurn"] == "completed"

      assert Enum.any?(
               received(ws),
               &match?(%{"type" => "prompt", "message" => "replacement task"}, &1)
             )

      refute "abort_and_prompt" in received_types(ws)
    end

    test "a rejected redirect leaves the original turn running", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD the original", ctx)["id"]
      await_wire(id, &(&1["activeTools"] != []))

      assert {:error, {:rejected, "Redirect refused"}} =
               LemonOmp.send_message(id, "REJECT this", :redirect, ctx.scope)

      assert {:ok, %{"status" => "running", "lastTurn" => nil}} = LemonOmp.get(id)
      assert {:ok, _} = LemonOmp.send_message(id, "finish original", :steer, ctx.scope)
      assert {:ok, %{"lastTurn" => "completed"}, :settled} = LemonOmp.wait(id, 3_000)
    end

    test "a redirect prompt failure after success records a turn error without another reply",
         ctx do
      for message <- ["PROMPT_FAIL", "PROMPT_FAIL_STARTED"] do
        ws = workspace!()
        id = start!(ws, "HOLD the original", ctx)["id"]
        await_wire(id, &(&1["activeTools"] != []))
        pid = session_pid(id)

        assert {:ok, %{"delivery" => "redirect"}} =
                 LemonOmp.send_message(id, message, :redirect, ctx.scope)

        final = await_wire(id, &(&1["lastTurn"] == "error"))
        assert final["status"] == "idle"
        assert final["error"] == "Redirect prompt failed"
        assert final["activeTools"] == []
        assert Process.alive?(pid)
        assert {:ok, _} = LemonOmp.send_message(id, "recover", :redirect, ctx.scope)

        assert %{"lastTurn" => "completed", "error" => nil} =
                 await_wire(id, &(&1["result"] == "Done: recover"))
      end
    end

    test "a prompt acknowledged after its turn finished leaves the session idle", ctx do
      ws = workspace!()
      id = start!(ws, "first", ctx)["id"]
      await_wire(id, &(&1["status"] == "idle"))

      assert {:ok, %{"delivery" => "prompt"}} =
               LemonOmp.send_message(id, "LATE_ACK please", :steer, ctx.scope)

      Process.sleep(300)
      assert {:ok, %{"status" => "idle", "result" => "Done early"}} = LemonOmp.get(id, ctx.scope)
    end

    test "cancel aborts the running turn and leaves the session open", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD this turn", ctx)["id"]

      assert {:ok, %{"cancelled" => true}} = LemonOmp.cancel(id, ctx.scope)
      aborted = await_wire(id, &(&1["status"] == "idle"))
      assert aborted["lastTurn"] == "aborted"
      assert "abort" in received_types(ws)

      assert {:error, :no_active_turn} = LemonOmp.cancel(id, ctx.scope)
      assert LemonOmp.error_message(:no_active_turn) =~ "no turn in progress"

      assert {:ok, %{"delivery" => "prompt"}} =
               LemonOmp.send_message(id, "again", :steer, ctx.scope)

      assert %{"lastTurn" => "completed"} = await_wire(id, &(&1["result"] == "Done: again"))
    end

    test "wait streams updates until the turn settles", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD this turn", ctx)["id"]
      parent = self()

      assert {:ok, %{"status" => "running"}, :timeout} = LemonOmp.wait(id, 100, ctx.scope)

      signal = LemonAgent.AbortSignal.new()
      :ok = LemonAgent.AbortSignal.abort(signal)
      assert {:ok, %{"status" => "running"}, :aborted} = LemonOmp.wait(id, 5_000, signal: signal)

      task =
        Task.async(fn ->
          LemonOmp.wait(
            id,
            5_000,
            Keyword.put(ctx.scope, :on_update, &send(parent, {:update, &1["status"]}))
          )
        end)

      wait_until(fn ->
        match?(
          {:current_function, {LemonOmp, :wait_loop, 4}},
          Process.info(task.pid, :current_function)
        )
      end)

      assert {:ok, %{"delivery" => "steer"}} = LemonOmp.send_message(id, "finish", :steer)

      assert {:ok, %{"status" => "idle", "result" => "Steered: finish"}, :settled} =
               Task.await(task, 6_000)

      assert_received {:update, _status}
      # Abandoning or finishing a wait never cancels omp.
      refute "abort" in received_types(ws)
    end

    test "idle sessions close after the idle timeout", ctx do
      put_app_env(:idle_timeout_ms, 200)
      ws = workspace!()
      id = start!(ws, "quick one", ctx)["id"]
      os_pid = fake_pid(ws)

      closed = await_wire(id, &(&1["status"] == "closed"))
      assert closed["exit"]["reason"] == "idle_timeout"
      assert closed["lastTurn"] == "completed"
      wait_until(fn -> not os_alive?(os_pid) end)
    end

    test "declines blocking UI requests and rejects host requests", ctx do
      ws = workspace!()
      id = start!(ws, "UI_REQUEST please", ctx)["id"]

      idle = await_wire(id, &(&1["status"] == "idle"))
      assert idle["declinedPrompts"] == 1
      assert idle["result"] == "UI answered"

      sent = received(ws)

      assert %{"type" => "extension_ui_response", "id" => "ui-confirm-1", "confirmed" => false} in sent
      refute Enum.any?(sent, &(&1["id"] == "ui-notify-1"))

      assert Enum.any?(
               sent,
               &match?(%{"type" => "host_tool_result", "id" => "host-1", "isError" => true}, &1)
             )

      assert {:ok, summary} = LemonOmp.summary(id)
      assert summary =~ "Declined 1 interactive omp prompt(s)"
    end

    test "skips malformed and oversized lines and reassembles long ones", ctx do
      ws = workspace!("garbage")
      id = start!(ws, "BIGTEXT please", ctx)["id"]

      idle = await_wire(id, &(&1["status"] == "idle"))
      assert String.length(idle["lastText"]) == 2_000
      assert String.ends_with?(idle["lastText"], "xxxEND")
      assert idle["lastTurn"] == "completed"

      # invalid JSON, a list, a typeless object, the > 4 MiB line, an id-less UI request
      assert :sys.get_state(session_pid(id)).malformed == 5
    end
  end

  describe "ending" do
    test "close ends the OS process and the session fails closed afterwards", ctx do
      LemonCore.Bus.subscribe(LemonOmp.bus_topic())
      on_exit(fn -> LemonCore.Bus.unsubscribe(LemonOmp.bus_topic()) end)
      ws = workspace!()
      id = start!(ws, "a task", ctx)["id"]
      os_pid = fake_pid(ws)
      assert os_alive?(os_pid)

      assert {:ok, closed} = LemonOmp.close(id, ctx.scope)
      assert closed["status"] == "closed"
      assert closed["exit"] == %{"code" => nil, "reason" => "closed"}
      assert is_integer(closed["endedAt"])
      refute os_alive?(os_pid)

      assert_receive %Event{
        payload: %{"reason" => "exited", "session" => %{"id" => ^id, "status" => "closed"}}
      }

      assert {:error, :not_running} = LemonOmp.send_message(id, "more", :steer, ctx.scope)
      assert {:error, :not_running} = LemonOmp.cancel(id, ctx.scope)
      assert {:error, :not_running} = LemonOmp.close(id, ctx.scope)
      assert {:ok, %{"status" => "closed"}} = LemonOmp.get(id, ctx.scope)
      assert {:ok, %{"status" => "closed"}, :settled} = LemonOmp.wait(id, 1_000, ctx.scope)
      assert LemonOmp.error_message(:not_running) =~ "no longer running"

      assert id in Enum.map(LemonOmp.list(ctx.scope), & &1["id"])

      refute id in Enum.map(
               LemonOmp.list(Keyword.put(ctx.scope, :include_ended, false)),
               & &1["id"]
             )
    end

    test "another owner cannot see or control a session", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD mine", ctx)["id"]
      other = [owner: {:session_key, "agent:someone-else"}]

      assert {:error, :not_found} = LemonOmp.get(id, other)
      assert {:error, :not_found} = LemonOmp.summary(id, other)
      assert {:error, :not_found} = LemonOmp.send_message(id, "hijack", :steer, other)
      assert {:error, :not_found} = LemonOmp.cancel(id, other)
      assert {:error, :not_found} = LemonOmp.close(id, other)
      assert {:error, :not_found} = LemonOmp.wait(id, 10, other)
      refute id in Enum.map(LemonOmp.list(other), & &1["id"])

      assert [%{"id" => ^id}] = LemonOmp.list(ctx.scope)
      assert {:ok, %{"id" => ^id}} = LemonOmp.get(id)
      refute "steer" in received_types(ws)

      # Operator-owned sessions are invisible to agent scopes too.
      op = LemonOmp.start(%{"prompt" => "HOLD operator", "cwd" => workspace!()})
      assert {:ok, %{"id" => op_id, "owner" => %{"kind" => "operator"}}} = op
      assert {:error, :not_found} = LemonOmp.get(op_id, ctx.scope)
    end

    test "killing the session process leaves no orphan and marks the snapshot failed", ctx do
      ws = workspace!()
      id = start!(ws, "HOLD running", ctx)["id"]
      os_pid = fake_pid(ws)
      kill_on_exit(os_pid)
      pid = session_pid(id)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

      # omp exits on stdin EOF once the port's owner is gone.
      wait_until(fn -> not os_alive?(os_pid) end)

      failed = await_wire(id, &(&1["status"] == "failed"))
      assert failed["error"] =~ "stopped unexpectedly"
      assert failed["exit"] == %{"code" => nil, "reason" => "crashed"}
      assert failed["activeTools"] == []
      assert {:error, :not_running} = LemonOmp.send_message(id, "hello?", :steer, ctx.scope)
    end

    test "stopping the session supervisor escalates to SIGKILL for an omp that ignores SIGTERM",
         ctx do
      ws = workspace!("ignore-term")
      id = start!(ws, "settle quickly", ctx)["id"]
      os_pid = fake_pid(ws)
      child = fake_pid(ws, ".fake_omp.child")
      kill_on_exit([os_pid, child])
      assert os_alive?(child)

      try do
        assert :ok = Supervisor.terminate_child(LemonOmp.Supervisor, LemonOmp.SessionSupervisor)
      after
        {:ok, _} = Supervisor.restart_child(LemonOmp.Supervisor, LemonOmp.SessionSupervisor)
      end

      refute os_alive?(os_pid)
      refute os_alive?(child)
      assert %{"status" => "closed"} = await_wire(id, &(&1["status"] == "closed"))
    end

    test "a supervisor shutdown terminates an omp that ignores stdin EOF", ctx do
      ws = workspace!("ignore-eof")
      id = start!(ws, "settle quickly", ctx)["id"]
      os_pid = fake_pid(ws)
      kill_on_exit(os_pid)

      assert :ok = DynamicSupervisor.terminate_child(LemonOmp.SessionSupervisor, session_pid(id))

      refute os_alive?(os_pid)
      assert %{"exit" => %{"reason" => "closed"}} = await_wire(id, &(&1["status"] == "closed"))
    end
  end

  describe "failures" do
    test "an unanswered prompt is outcome_unknown, never a failure", ctx do
      put_app_env(:command_timeout_ms, 300)
      ws = workspace!("hang")

      assert {:error, {:outcome_unknown, id}} =
               LemonOmp.start(%{"prompt" => "anyone?", "cwd" => ws}, owner: ctx.owner)

      assert LemonOmp.error_message({:outcome_unknown, id}) =~
               "session #{id} may already be working on it"

      assert Enum.any?(received(ws), &match?(%{"type" => "prompt", "message" => "anyone?"}, &1))

      # The process is kept under that fixed id, so the caller can reconcile or close it.
      os_pid = fake_pid(ws)
      assert os_alive?(os_pid)
      assert [%{"id" => ^id, "status" => "starting"}] = LemonOmp.list(ctx.scope)
      assert {:ok, %{"status" => "closed"}} = LemonOmp.close(id, ctx.scope)
      refute os_alive?(os_pid)
    end

    test "unanswered control commands are outcome_unknown", ctx do
      put_app_env(:command_timeout_ms, 300)
      ws = workspace!()
      id = start!(ws, "MUTE from now on", ctx)["id"]

      assert {:error, :outcome_unknown} = LemonOmp.cancel(id, ctx.scope)
      assert {:error, :outcome_unknown} = LemonOmp.send_message(id, "hello?", :steer, ctx.scope)

      assert {:error, :outcome_unknown} =
               LemonOmp.send_message(id, "start over?", :redirect, ctx.scope)

      assert 1 == Enum.count(received(ws), &(&1["type"] == "abort_and_prompt"))
      assert {:ok, %{"status" => "running"}} = LemonOmp.get(id)
    end

    test "a crash mid-turn fails the session with the stderr tail", ctx do
      ws = workspace!()
      id = start!(ws, "CRASH now", ctx)["id"]

      failed = await_wire(id, &(&1["status"] == "failed"))
      assert failed["error"] == "omp exited with status 3: fake omp: fatal crash during turn"
      assert failed["exit"] == %{"code" => 3, "reason" => "crashed"}
      assert failed["activity"] == nil
      assert {:error, :not_running} = LemonOmp.cancel(id, ctx.scope)
    end

    test "a crash at startup is startup_failed with a bounded stderr tail", ctx do
      ws = workspace!("crash-start")

      assert {:error, {:startup_failed, message}} =
               LemonOmp.start(%{"prompt" => "hi", "cwd" => ws}, owner: ctx.owner)

      assert message =~ "omp exited with status 3: "
      assert String.ends_with?(message, "fake omp: fatal: provider configuration is invalid")
      assert byte_size(message) < 1_000

      assert LemonOmp.error_message({:startup_failed, message}) =~
               "omp failed to start: omp exited"

      assert [failed] = LemonOmp.list(ctx.scope)
      assert failed["status"] == "failed"
      assert failed["error"] == message
    end

    test "omp that never becomes ready is startup_failed and stopped", ctx do
      put_app_env(:ready_timeout_ms, 300)
      ws = workspace!("slow-start")

      assert {:error, {:startup_failed, "omp did not become ready in time"}} =
               LemonOmp.start(%{"prompt" => "hi", "cwd" => ws}, owner: ctx.owner)

      os_pid = fake_pid(ws)
      kill_on_exit(os_pid)
      wait_until(fn -> not os_alive?(os_pid) end)

      assert [%{"status" => "failed", "error" => "omp did not become ready in time"}] =
               LemonOmp.list(ctx.scope)
    end

    test "the live-session cap refuses extra starts", ctx do
      put_app_env(:max_sessions, 1)
      first = start!(workspace!(), "HOLD one", ctx)["id"]

      assert {:error, :too_many_sessions} =
               LemonOmp.start(%{"prompt" => "two", "cwd" => workspace!()}, owner: ctx.owner)

      assert %{"live" => 1, "maxSessions" => 1} = LemonOmp.status()
      assert LemonOmp.error_message(:too_many_sessions) =~ "too many"

      assert {:ok, _} = LemonOmp.close(first)
      assert %{"status" => "running"} = start!(workspace!(), "two", ctx)
    end
  end

  describe "resume and discovery" do
    test "resume without a prompt opens idle and discovery marks the stored session live", ctx do
      agent_dir = tmp_dir!("lemon_omp_agent")
      put_app_env(:agent_dir, agent_dir)
      ws = workspace!()
      {out, 0} = System.cmd("/bin/pwd", ["-P"], cd: ws)
      canonical = String.trim(out)

      store =
        Path.join([
          agent_dir,
          "sessions",
          "--" <> String.replace(String.trim_leading(canonical, "/"), "/", "-") <> "--"
        ])

      File.mkdir_p!(store)

      File.write!(
        Path.join(store, "2026-10-13T10-00-00-000Z_01resume-0001.jsonl"),
        Jason.encode!(%{"type" => "session", "id" => "01resume-0001", "cwd" => canonical}) <> "\n"
      )

      assert {:ok, wire} =
               LemonOmp.start(%{"cwd" => ws, "resume" => "01resume-0001"}, owner: ctx.owner)

      assert wire["status"] == "idle"
      id = wire["id"]

      resumed = await_wire(id, &(&1["ompSessionId"] == "01resume-0001" and &1["todos"] != []))
      assert resumed["title"] == "Resumed fake session"

      assert resumed["todos"] == [
               %{"phase" => "Earlier", "content" => "Carry over", "status" => "pending"}
             ]

      assert File.read!(Path.join(ws, ".fake_omp.args")) =~ "--resume 01resume-0001"
      refute "prompt" in received_types(ws)

      assert {:ok, [found]} = LemonOmp.discover(ws)
      assert found["ompSessionId"] == "01resume-0001"
      assert found["liveId"] == id
      assert found["activeElsewhere"] == false

      assert {:ok, _} = LemonOmp.close(id)
      assert {:ok, [%{"liveId" => nil}]} = LemonOmp.discover(ws)
      assert {:error, :invalid_cwd} = LemonOmp.discover(Path.join(ws, "missing"))
      assert {:error, :invalid_cwd} = LemonOmp.discover(nil)
    end
  end
end
