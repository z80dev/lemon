defmodule CodingAgent.ExecutorRemoteNodeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Executor
  alias CodingAgent.Executor.RemoteSessionRunner
  alias LemonCore.NodeRegistry
  alias LemonGateway.ExecutionRequest

  setup do
    for node <- NodeRegistry.list() do
      NodeRegistry.unregister(node.id, node.pid)
    end

    on_exit(fn ->
      for node <- NodeRegistry.list() do
        NodeRegistry.unregister(node.id, node.pid)
      end
    end)

    :ok
  end

  test "targets a named node with a JSON-safe request and destination-local defaults" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    request =
      request(%{
        node: "newphy",
        remote_cwd_explicit: false,
        model: "openai:gpt-5",
        agent_id: "oracle"
      })

    {:ok, run_ref, %{runner_module: RemoteSessionRunner}} =
      Executor.start_run(
        request,
        %{stream_fn: fn -> :source_only end, api_key: "source-secret", cwd: "/source/default"},
        self()
      )

    assert_receive {:node_event, "node.invoke.request", invocation}
    assert invocation["nodeName"] == "newphy"
    assert invocation["method"] == "coding_agent.run"

    payload = invocation["args"]
    assert payload["runId"] == request.run_id
    assert payload["sessionKey"] == request.session_key
    assert payload["prompt"] == request.prompt
    assert payload["cwd"] == nil
    assert payload["meta"]["model"] == "openai:gpt-5"
    refute Map.has_key?(payload, "api_key")
    refute inspect(payload) =~ "source-secret"
    assert {:ok, _json} = Jason.encode(payload)

    assert_receive {:engine_event, ^run_ref,
                    %{__event__: :started, engine: "lemon", meta: %{node: "newphy", cwd: nil}}}

    assert :ok =
             NodeRegistry.complete("node-1", invocation["invokeId"], %{
               "ok" => true,
               "answer" => "remote answer",
               "resume" => %{"engine" => "lemon", "value" => "remote-session"},
               "meta" => %{"worker" => "fake"}
             })

    assert_receive {:engine_event, ^run_ref,
                    %{
                      __event__: :completed,
                      engine: "lemon",
                      ok: true,
                      answer: "remote answer",
                      resume: %LemonCore.ResumeToken{value: "remote-session"},
                      meta: %{"worker" => "fake", node: "newphy"}
                    }}
  end

  test "a canonical profile request reaches the executor-selected named node" do
    assert :ok = NodeRegistry.register("node-profile", "newphy", self())

    profile = %{
      "id" => "research",
      "name" => "Research",
      "node" => "newphy",
      "model" => nil,
      "canonicalSessionKey" => "agent:research:main",
      "paths" => %{"workspace" => "/controller-only/profile/workspace"}
    }

    assert {:ok, canonical} =
             LemonCore.ProfileStore.chat_request(profile, "remote profile work",
               meta: %{node: "forged", profile_id: "forged"}
             )

    execution = %ExecutionRequest{
      run_id: "profile-node-route",
      session_key: canonical.session_key,
      prompt: canonical.prompt,
      cwd: canonical.cwd,
      conversation_key: {:session, canonical.session_key},
      meta: canonical.meta
    }

    assert {:ok, run_ref, %{runner_module: RemoteSessionRunner}} =
             Executor.start_run(execution, %{}, self())

    assert_receive {:node_event, "node.invoke.request", invocation}
    assert invocation["nodeName"] == "newphy"
    assert invocation["args"]["cwd"] == nil
    assert invocation["args"]["meta"]["profile_id"] == "research"

    assert :ok =
             NodeRegistry.complete("node-profile", invocation["invokeId"], %{
               "ok" => true,
               "answer" => "routed"
             })

    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true}}
  end

  test "preserves an explicitly supplied remote cwd verbatim" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())

    request =
      request(%{
        node: "newphy",
        remote_cwd_explicit: true,
        remote_cwd: "projects/lemon"
      })

    assert {:ok, _run_ref, _ctx} = Executor.start_run(request, %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    assert invocation["args"]["cwd"] == "projects/lemon"

    assert :ok =
             NodeRegistry.complete("node-1", invocation["invokeId"], %{
               "ok" => true,
               "answer" => "done"
             })
  end

  test "maps a remote error to a failed gateway completion" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    assert {:ok, run_ref, _ctx} = Executor.start_run(request(%{node: "newphy"}), %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    assert_receive {:engine_event, ^run_ref, %{__event__: :started}}

    remote_error = %{"type" => "provider_error", "message" => "destination failed"}
    assert :ok = NodeRegistry.complete("node-1", invocation["invokeId"], nil, remote_error)

    assert_receive {:engine_event, ^run_ref,
                    %{
                      __event__: :completed,
                      ok: false,
                      answer: "",
                      error: {:remote, ^remote_error},
                      meta: %{node: "newphy"}
                    }}
  end

  test "fails closed when the named node is offline" do
    assert {:ok, run_ref, _ctx} =
             Executor.start_run(request(%{node: "missing"}), %{}, self())

    assert_receive {:engine_event, ^run_ref,
                    %{
                      __event__: :completed,
                      ok: false,
                      error: {:node_offline, "missing"}
                    }}
  end

  test "forwards cancellation to the selected node invocation" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    assert {:ok, _run_ref, ctx} = Executor.start_run(request(%{node: "newphy"}), %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}

    assert :ok = Executor.cancel(ctx)

    invoke_id = invocation["invokeId"]

    assert_receive {:node_event, "node.invoke.cancel",
                    %{"invokeId" => ^invoke_id, "reason" => ":user_requested"}}
  end

  test "waits for destination acceptance before reporting remote steer and redirect" do
    assert :ok = NodeRegistry.register("node-1", "newphy", self())
    assert {:ok, _run_ref, ctx} = Executor.start_run(request(%{node: "newphy"}), %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    invoke_id = invocation["invokeId"]
    run_id = invocation["args"]["runId"]

    steer = Task.async(fn -> Executor.steer(ctx, "verify the native session") end)

    assert_receive {:node_event, "node.invoke.control",
                    %{
                      "controlId" => steer_id,
                      "invokeId" => ^invoke_id,
                      "runId" => ^run_id,
                      "operation" => "steer",
                      "text" => "verify the native session"
                    }}

    assert :ok =
             NodeRegistry.complete_control_session(
               "node-1",
               self(),
               0,
               steer_id,
               invoke_id,
               run_id,
               true
             )

    assert :ok = Task.await(steer)

    redirect = Task.async(fn -> Executor.redirect(ctx, "replace the remaining direction") end)

    assert_receive {:node_event, "node.invoke.control",
                    %{
                      "controlId" => redirect_id,
                      "invokeId" => ^invoke_id,
                      "runId" => ^run_id,
                      "operation" => "redirect",
                      "text" => "replace the remaining direction"
                    }}

    assert :ok =
             NodeRegistry.complete_control_session(
               "node-1",
               self(),
               0,
               redirect_id,
               invoke_id,
               run_id,
               true
             )

    assert :ok = Task.await(redirect)

    assert :ok =
             NodeRegistry.complete("node-1", invoke_id, %{
               "ok" => true,
               "answer" => "done"
             })
  end

  test "bridges remote approvals through the controller store and returns the decision to the owning node" do
    :ok = LemonCore.Bus.subscribe("exec_approvals")
    assert :ok = NodeRegistry.register("node-approval", "approval-worker", self())
    request = request(%{node: "approval-worker", agent_id: "oracle"})
    assert {:ok, run_ref, _ctx} = Executor.start_run(request, %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    invoke_id = invocation["invokeId"]
    worker_id = "worker-approval-id"
    event = %{"type" => "approval_requested", "approvalId" => worker_id, "tool" => "bash",
              "action" => %{"command_hash" => "safe-test"}, "expiresAtMs" => LemonCore.Clock.now_ms() + 10_000}
    assert {:ok, :accepted} = NodeRegistry.event_session("node-approval", self(), 0, invoke_id, 1, event)
    assert_receive %LemonCore.Event{type: :approval_requested,
      payload: %{pending: %{id: controller_id, run_id: run_id, session_key: session_key}}}
    assert run_id == request.run_id
    assert session_key == request.session_key
    assert LemonCore.ExecApprovalStore.get_pending(controller_id).tool == "bash"
    refute controller_id == worker_id
    assert {:ok, %{decision: :approve_once, outcome: :approved}} =
      LemonCore.ExecApprovals.resolve(controller_id, :approve_once,
        expected_session_key: session_key, expected_run_id: run_id)
    assert_receive {:node_event, "node.invoke.approval",
      %{"nodeId" => "node-approval", "invokeId" => ^invoke_id, "runId" => ^run_id,
        "approvalId" => ^worker_id, "decision" => "approve_once"}}
    assert :ok = NodeRegistry.complete("node-approval", invoke_id, %{"ok" => true, "answer" => "approved"})
    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true, answer: "approved"}}
  end

  test "disconnect cancels pending controller approvals and cannot grant a late decision" do
    :ok = LemonCore.Bus.subscribe("exec_approvals")
    assert :ok = NodeRegistry.register("node-disconnect", "disconnect-worker", self())
    assert {:ok, run_ref, _ctx} = Executor.start_run(request(%{node: "disconnect-worker"}), %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    invoke_id = invocation["invokeId"]
    assert {:ok, :accepted} = NodeRegistry.event_session("node-disconnect", self(), 0, invoke_id, 1,
      %{"type" => "approval_requested", "approvalId" => "disconnect-approval", "tool" => "bash",
        "action" => %{"command_hash" => "disconnect-test"}})
    assert_receive %LemonCore.Event{type: :approval_requested, payload: %{pending: %{id: controller_id}}}
    assert :ok = NodeRegistry.unregister("node-disconnect", self())
    assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: false}}
    assert_receive %LemonCore.Event{type: :approval_resolved,
      payload: %{approval_id: ^controller_id, decision: :cancelled}}
    assert LemonCore.ExecApprovalStore.get_pending(controller_id) == nil
    assert {:error, :cancelled} = LemonCore.ExecApprovals.resolve(controller_id, :approve_once)
    refute_receive {:node_event, "node.invoke.approval", %{"decision" => "approve_once"}}
  end

  test "an expired remote approval returns denial without granting execution" do
    assert :ok = NodeRegistry.register("node-expired", "expired-worker", self())
    assert {:ok, _run_ref, ctx} = Executor.start_run(request(%{node: "expired-worker"}), %{}, self())
    assert_receive {:node_event, "node.invoke.request", invocation}
    invoke_id = invocation["invokeId"]
    assert {:ok, :accepted} = NodeRegistry.event_session("node-expired", self(), 0, invoke_id, 1,
      %{"type" => "approval_requested", "approvalId" => "expired-approval", "tool" => "bash",
        "action" => %{"command_hash" => "expired-test"}, "expiresAtMs" => LemonCore.Clock.now_ms() - 1})
    assert_receive {:node_event, "node.invoke.approval",
      %{"invokeId" => ^invoke_id, "approvalId" => "expired-approval", "decision" => "deny"}}
    :ok = Executor.cancel(ctx)
  end

  defp request(meta) do
    %ExecutionRequest{
      run_id: "remote-run-#{System.unique_integer([:positive])}",
      session_key: "agent:oracle:main",
      prompt: "do remote work",
      cwd: "/source/router/default",
      tool_policy: %{allow: :all, deny: ["agent"]},
      conversation_key: {:session, "agent:oracle:main"},
      meta: meta
    }
  end
end
