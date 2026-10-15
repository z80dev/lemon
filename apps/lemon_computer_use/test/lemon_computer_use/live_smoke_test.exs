defmodule LemonComputerUse.LiveSmokeTest do
  @moduledoc """
  Drives Calculator end to end through the installed LCU runtime, the real
  `cua_js` tool and the real Lemon approval plane. Excluded by default; run on a
  Mac with LCU set up:

      scripts/test path apps/lemon_computer_use/test --include computer_use_live

  Calculator is quit afterwards only when the test launched it.
  """

  use ExUnit.Case, async: false

  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent
  alias LemonComputerUse.Tools.Js

  @moduletag :computer_use_live
  @moduletag timeout: 180_000

  setup do
    start_supervised!({LemonComputerUse.Server, []})
    test_pid = self()
    approver = spawn_link(fn -> approver(test_pid) end)
    receive do: ({:approver_ready, ^approver} -> :ok)
    %{approver: approver}
  end

  # Stands in for the operator: approves Calculator for the session, denies
  # anything else, and reports each request to the test.
  defp approver(test_pid) do
    LemonCore.Bus.subscribe("exec_approvals")
    send(test_pid, {:approver_ready, self()})
    approve_loop(test_pid)
  end

  defp approve_loop(test_pid) do
    receive do
      %LemonCore.Event{type: :approval_requested, payload: %{approval_id: id, pending: pending}} ->
        decision =
          if pending.tool == "computer_use" and
               pending.action == %{"app" => "com.apple.calculator"},
             do: :approve_session,
             else: :deny

        send(test_pid, {:approval_requested, pending.action})
        LemonCore.ExecApprovals.resolve(id, decision)
        approve_loop(test_pid)

      _other ->
        approve_loop(test_pid)
    end
  end

  defp text(%AgentToolResult{content: content}) do
    content |> Enum.filter(&match?(%TextContent{}, &1)) |> Enum.map_join("\n", & &1.text)
  end

  defp index!(state, id) do
    [_, index] = Regex.run(~r/(\d+) button (?:[^\n]*ID: #{id}\b|#{id}$)/m, state)
    index
  end

  test "computes 7 + 5 in Calculator through cua_js" do
    {_, status} = System.cmd("pgrep", ["-x", "Calculator"])
    already_running? = status == 0

    # The runtime remembers ended turns and session grants across restarts, so
    # every run uses fresh identities.
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    run_id = "lemon-cua-smoke-run-" <> nonce
    js = Js.tool("/tmp", session_id: "lemon-cua-smoke-" <> nonce, run_id: run_id)
    assert js.description =~ "Control native apps"

    call = fn code ->
      js.execute.("call-#{System.unique_integer([:positive])}", %{"code" => code}, nil, nil)
    end

    opened = call.(~s|const calc = await cua.getApp("Calculator");|)
    assert %AgentToolResult{is_error: false, trust: :untrusted} = opened
    state = text(opened)
    assert state =~ "Calculator"

    [seven, add, five, equals, clear] =
      Enum.map(~w(Seven Add Five Equals AllClear), &index!(state, &1))

    computed =
      call.("""
      await calc.click(#{clear});
      await calc.click(#{seven});
      await calc.click(#{add});
      await calc.click(#{five});
      await calc.click(#{equals});
      await calc.getAXState({ disableDiffing: true });
      """)

    assert %AgentToolResult{is_error: false} = computed
    assert text(computed) =~ ~r/text \W*12\b/

    unless already_running? do
      assert %AgentToolResult{is_error: false} = call.(~s|await calc.pressKey("super+q");|)
    end

    # One Lemon approval (session scope) covered every action on Calculator.
    assert_received {:approval_requested, %{"app" => "com.apple.calculator"}}
    refute_received {:approval_requested, _}

    # The Lemon run ends: LCU's original turn cleanup runs and the turn is closed.
    LemonCore.Bus.broadcast(
      "run:" <> run_id,
      LemonCore.Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{completed: %{ok: true}}),
        %{run_id: run_id}
      )
    )

    Process.sleep(3_000)
    after_end = call.("await cua.listApps();")
    assert text(after_end) =~ "current turn ended"
  end
end
