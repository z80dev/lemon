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
