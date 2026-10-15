defmodule LemonOmp.ApprovalsTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport

  alias LemonCore.{Bus, Event, ExecApprovals, ExecApprovalStore}

  setup do
    use_fake_omp()
    put_app_env(:approvals, :bridge)
    put_app_env(:approval_timeout_ms, 10_000)
    Bus.subscribe("exec_approvals")
    Bus.subscribe(LemonOmp.bus_topic())

    on_exit(fn ->
      Bus.unsubscribe("exec_approvals")
      Bus.unsubscribe(LemonOmp.bus_topic())
    end)

    ws = workspace!()
    key = "agent:omp-approval:#{System.unique_integer([:positive])}"
    {:ok, ws: ws, owner: %{kind: :agent, session_key: key}, key: key}
  end

  defp start!(ctx, prompt, extra \\ %{}) do
    assert {:ok, wire} =
             LemonOmp.start(Map.merge(%{cwd: ctx.ws, prompt: prompt}, extra), owner: ctx.owner)

    wire["id"]
  end

  defp pending!(id) do
    assert_receive %Event{
                     type: :approval_requested,
                     payload: %{approval_id: approval_id, pending: pending}
                   },
                   5_000

    assert pending.id == approval_id
    assert pending.action["ompSession"] == id
    pending
  end

  defp reply!(ws) do
    wait_until(fn -> Enum.any?(received(ws), &(&1["type"] == "extension_ui_response")) end)
    Enum.find(received(ws), &(&1["type"] == "extension_ui_response"))
  end

  defp assert_cancelled(pending) do
    wait_until(fn -> ExecApprovalStore.get_pending(pending.id) == nil end)
    assert {:error, :cancelled} = ExecApprovals.resolve(pending.id, :approve_once)
  end

  test "bridges approval without blocking the Session and sends Approve", ctx do
    owner = Map.merge(ctx.owner, %{session_id: "native-session", run_id: "native-run"})
    id = start!(%{ctx | owner: owner}, "APPROVAL")
    pending = pending!(id)

    assert pending.session_key == ctx.key
    assert pending.session_id == "native-session"
    assert pending.run_id == "native-run"
    assert pending.tool == "omp:bash"

    assert pending.action == %{
             "type" => "omp_tool",
             "ompSession" => id,
             "tool" => "bash",
             "details" => "Allow tool: bash\nCommand: printf safe"
           }

    assert pending.rationale =~ id
    assert pending.rationale =~ ctx.ws
    wire = await_wire(id, &(&1["pendingApprovals"] != []))

    assert [%{"id" => approval_id, "tool" => "bash", "details" => details, "requestedAt" => at}] =
             wire["pendingApprovals"]

    assert approval_id == pending.id
    assert details == pending.action["details"]
    assert is_integer(at)
    assert wire["activity"] == "Waiting for approval: bash"
    assert wire["approvals"] == %{"approved" => 0, "denied" => 0, "expired" => 0}
    assert {:ok, summary} = LemonOmp.summary(id)
    assert summary =~ "Pending approvals: bash (#{approval_id})"
    assert summary =~ "exec.approval.resolve"
    assert summary =~ "Lemon's approval prompts"

    # A correlated control command is serviced while the approval helper waits.
    assert {:ok, %{"delivery" => "followUp"}} = LemonOmp.send_message(id, "later", :follow_up)
    assert {:ok, _receipt} = ExecApprovals.resolve(approval_id, :approve_once)

    assert reply!(ctx.ws) == %{
             "type" => "extension_ui_response",
             "id" => "ui-approval-1",
             "value" => "Approve"
           }

    wire = await_wire(id, &(&1["status"] == "idle"))
    assert wire["pendingApprovals"] == []
    assert wire["approvals"] == %{"approved" => 1, "denied" => 0, "expired" => 0}
    assert wire["declinedPrompts"] == 0

    assert_receive %Event{
      type: :omp_session,
      payload: %{
        "reason" => "approval_resolved",
        "session" => %{"id" => ^id, "pendingApprovals" => []}
      }
    }
  end

  test "operator approvals have no conversation session key and denial sends Deny", ctx do
    id = start!(%{ctx | owner: %{kind: :operator}}, "APPROVAL")
    pending = pending!(id)
    assert pending.session_key == nil
    assert pending.session_id == nil
    assert pending.run_id == nil
    assert {:ok, _} = ExecApprovals.resolve(pending.id, :deny)
    assert reply!(ctx.ws)["value"] == "Deny"
    wire = await_wire(id, &(&1["approvals"]["denied"] == 1))
    assert wire["pendingApprovals"] == []
    assert wire["approvals"] == %{"approved" => 0, "denied" => 1, "expired" => 0}
  end

  test "omp's timeout caps the configured timeout and sends cancelled plus timedOut", ctx do
    id = start!(ctx, "APPROVAL_TIMEOUT")
    pending = pending!(id)
    assert pending.expires_at_ms - pending.requested_at_ms <= 100

    assert reply!(ctx.ws) == %{
             "type" => "extension_ui_response",
             "id" => "ui-approval-1",
             "cancelled" => true,
             "timedOut" => true
           }

    wire = await_wire(id, &(&1["approvals"]["expired"] == 1))
    assert wire["pendingApprovals"] == []
    assert ExecApprovalStore.get_pending(pending.id) == nil
  end

  test "the configured timeout bounds an approval without an omp timeout", ctx do
    put_app_env(:approval_timeout_ms, 100)
    id = start!(ctx, "APPROVAL")
    pending = pending!(id)
    assert pending.expires_at_ms - pending.requested_at_ms <= 100
    assert reply!(ctx.ws)["timedOut"] == true
    assert %{"pendingApprovals" => []} = await_wire(id, &(&1["approvals"]["expired"] == 1))
  end

  test "omp cancelling a dialog removes Lemon's pending request and ignores late results", ctx do
    id = start!(ctx, "APPROVAL_CANCEL")
    pending = pending!(id)
    assert {:ok, _} = LemonOmp.send_message(id, "cancel dialog", :follow_up)
    wire = await_wire(id, &(&1["pendingApprovals"] == []))
    assert_cancelled(pending)

    send(
      session_pid(id),
      {:approval_result, "ui-approval-1", pending.id, {:ok, :approved, :approve_once}}
    )

    :sys.get_state(session_pid(id))
    refute Enum.any?(received(ctx.ws), &(&1["type"] == "extension_ui_response"))
    assert wire["approvals"] == %{"approved" => 0, "denied" => 0, "expired" => 0}
  end

  test "immediate omp cancellation cannot leave a late-registered prompt", ctx do
    id = start!(ctx, "APPROVAL_CANCEL_NOW")

    assert_receive %Event{
                     type: :omp_session,
                     payload: %{
                       "reason" => "approval_requested",
                       "session" => %{"id" => ^id, "pendingApprovals" => [%{"id" => approval_id}]}
                     }
                   },
                   5_000

    await_wire(id, &(&1["pendingApprovals"] == []))
    # The linked waiter is killed and its guardian confirms death before cleanup.
    assert ExecApprovalStore.get_pending(approval_id) == nil
    refute Enum.any?(received(ctx.ws), &(&1["type"] == "extension_ui_response"))
  end

  test "Lemon turn abort consumes omp's cancel frame without answering an abandoned dialog",
       ctx do
    id = start!(ctx, "APPROVAL")
    pending = pending!(id)
    assert {:ok, %{"cancelled" => true}} = LemonOmp.cancel(id)
    wire = await_wire(id, &(&1["lastTurn"] == "aborted"))
    assert wire["pendingApprovals"] == []
    assert_cancelled(pending)
    refute Enum.any?(received(ctx.ws), &(&1["type"] == "extension_ui_response"))
  end

  test "close cancels pending approvals and ends the omp OS process", ctx do
    id = start!(ctx, "APPROVAL")
    pending = pending!(id)
    os_pid = fake_pid(ctx.ws)
    kill_on_exit(os_pid)
    assert {:ok, %{"status" => "closed", "pendingApprovals" => []}} = LemonOmp.close(id)
    assert_cancelled(pending)
    wait_until(fn -> not os_alive?(os_pid) end)
  end

  test "a brutal Session death cancels its approval and closes omp stdin", ctx do
    id = start!(ctx, "APPROVAL")
    pending = pending!(id)
    os_pid = fake_pid(ctx.ws)
    kill_on_exit(os_pid)
    Process.exit(session_pid(id), :kill)
    assert %{"pendingApprovals" => []} = await_wire(id, &(&1["status"] == "failed"))
    assert_cancelled(pending)
    wait_until(fn -> not os_alive?(os_pid) end)
  end

  test "an approval helper crash fails closed and clears its pending request", ctx do
    id = start!(ctx, "APPROVAL")
    pending = pending!(id)
    %{approvals: %{"ui-approval-1" => %{pid: waiter}}} = :sys.get_state(session_pid(id))
    Process.exit(waiter, :kill)
    assert reply!(ctx.ws)["cancelled"] == true
    assert %{"pendingApprovals" => []} = await_wire(id, &(&1["approvals"]["expired"] == 1))
    assert_cancelled(pending)
  end

  test "omp exit cancels pending approvals", ctx do
    id = start!(ctx, "APPROVAL_EXIT")
    pending = pending!(id)
    assert {:ok, _} = LemonOmp.send_message(id, "exit", :follow_up)
    assert %{"pendingApprovals" => []} = await_wire(id, &(&1["status"] == "failed"))
    assert_cancelled(pending)
  end

  test "decline mode retains headless cancellation without creating an approval", ctx do
    put_app_env(:approvals, :decline)
    id = start!(ctx, "APPROVAL")

    assert reply!(ctx.ws) == %{
             "type" => "extension_ui_response",
             "id" => "ui-approval-1",
             "cancelled" => true
           }

    wire = await_wire(id, &(&1["declinedPrompts"] == 1))
    assert wire["pendingApprovals"] == []
    refute_receive %Event{type: :approval_requested}
  end

  test "other blocking UI requests remain declined and counted", ctx do
    id = start!(ctx, "OTHER_UI")
    wire = await_wire(id, &(&1["declinedPrompts"] == 3))
    assert wire["pendingApprovals"] == []

    wait_until(fn ->
      Enum.count(received(ctx.ws), &(&1["type"] == "extension_ui_response")) == 3
    end)

    replies = Enum.filter(received(ctx.ws), &(&1["type"] == "extension_ui_response"))
    assert Enum.sort(Enum.map(replies, & &1["id"])) == ~w(ui-editor ui-input ui-select)
    assert Enum.all?(replies, &(&1["cancelled"] == true))
    refute_receive %Event{type: :approval_requested}
  end

  test "valid approval modes reach argv and the snapshot; omitted leaves omp configuration alone",
       ctx do
    for mode <- ~w(always-ask write yolo) do
      id = start!(ctx, "normal", %{approval_mode: mode})
      assert {:ok, %{"approvalMode" => ^mode}} = LemonOmp.get(id)
      assert File.read!(Path.join(ctx.ws, ".fake_omp.args")) =~ "--approval-mode #{mode}"
      assert {:ok, _} = LemonOmp.close(id)
    end

    id = start!(ctx, "normal")
    assert {:ok, %{"approvalMode" => nil}} = LemonOmp.get(id)
    refute File.read!(Path.join(ctx.ws, ".fake_omp.args")) =~ "--approval-mode"
  end

  test "batch validation rejects an invalid approval mode before starting any worker", ctx do
    assert {:error, {:invalid_task, 1, :invalid_params}} =
             LemonOmp.start_many([
               %{cwd: ctx.ws, prompt: "valid", approval_mode: "write"},
               %{cwd: ctx.ws, prompt: "invalid", approval_mode: "unsafe"}
             ])

    refute File.exists?(Path.join(ctx.ws, ".fake_omp.pid"))
  end

  test "invalid approval modes are rejected before spawning", ctx do
    for mode <- ["always", "YOLO", :yolo, false, 42, %{}] do
      assert {:error, :invalid_params} =
               LemonOmp.start(%{cwd: ctx.ws, prompt: "hi", approval_mode: mode})
    end

    refute File.exists?(Path.join(ctx.ws, ".fake_omp.pid"))
  end
end
