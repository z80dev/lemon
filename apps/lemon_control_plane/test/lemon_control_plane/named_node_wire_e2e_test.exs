defmodule LemonControlPlane.NamedNodeWireE2ETest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.Worker
  alias LemonControlPlane.Auth.TokenStore
  alias LemonControlPlane.NodeStore
  alias LemonGateway.ExecutionRequest

  defmodule FakeExecutor do
    @moduledoc false

    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      owner = Process.whereis(__MODULE__)
      run_ref = make_ref()
      runner_pid = spawn_link(fn -> receive do: (:stop -> :ok) end)
      context = %{runner_pid: runner_pid, run_id: request.run_id}

      send(owner, {:fake_executor_started, request, opts, sink_pid, run_ref, context})
      {:ok, run_ref, context}
    end

    def cancel(context) do
      send(Process.whereis(__MODULE__), {:fake_executor_cancelled, context})
      send(context.runner_pid, :stop)
      :ok
    end
  end

  setup do
    true = Process.register(self(), FakeExecutor)
    :ok
  end

  @tag :tmp_dir
  test "named node crosses the real WebSocket boundary for invoke, result, and cancel", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    node_id = "wire-node-#{suffix}"
    node_name = "Wire Node #{suffix}"
    token = "wire-token-#{suffix}"

    put_node(node_id, node_name)
    assert {:ok, _token_info} = TokenStore.store(token, %{"type" => "node", "nodeId" => node_id})

    on_exit(fn ->
      LemonCore.Store.delete(:session_tokens, token)
      LemonCore.Store.delete(:nodes_by_name, node_name)
      LemonCore.Store.delete(:nodes_registry, node_id)
    end)

    bandit_id = {:named_node_wire_bandit, suffix}

    bandit =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: LemonControlPlane.HTTP.Router, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: bandit_id,
          restart: :temporary
        )
      )

    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(bandit)

    worker_id = {:named_node_wire_worker, suffix}

    worker =
      start_supervised!(%{
        id: worker_id,
        start:
          {Worker, :start_link,
           [
             [
               node_name: node_name,
               controller: "ws://127.0.0.1:#{port}/ws",
               cwd: tmp_dir,
               token: token,
               notify_pid: self(),
               executor_module: FakeExecutor,
               socket_opts: [reconnect_delay_ms: 10]
             ]
           ]},
        restart: :temporary
      })

    assert_receive {:execution_node_worker, ^worker, {:status, :online, ^node_id}}, 3_000

    assert {:ok, %{id: ^node_id, name: ^node_name, pid: connection_pid}} =
             LemonCore.NodeRegistry.resolve(node_name)

    assert is_pid(connection_pid)
    assert connection_pid != worker

    invoke_args = %{
      "version" => 1,
      "runId" => "wire-run-#{suffix}",
      "prompt" => "cross the wire",
      "cwd" => tmp_dir,
      "meta" => %{}
    }

    assert {:ok, invoke_id} =
             LemonCore.NodeRegistry.invoke(node_name, "coding_agent.run", invoke_args,
               recipient: self(),
               timeout_ms: 3_000
             )

    assert NodeStore.get_invocation(invoke_id) == nil

    assert_receive {:fake_executor_started, request, run_opts, ^worker, run_ref, context}, 3_000
    assert request.prompt == "cross the wire"
    assert request.cwd == tmp_dir
    assert run_opts == %{cwd: tmp_dir, run_id: "wire-run-#{suffix}"}

    send(worker, {:engine_delta, run_ref, "wire "})
    send(worker, {:engine_delta, run_ref, "complete"})

    send(worker, {
      :engine_event,
      run_ref,
      %{
        __event__: :completed,
        ok: true,
        answer: "",
        error: nil,
        usage: %{input_tokens: 3},
        meta: %{provider: "fake-boundary"},
        resume: nil
      }
    })

    assert_receive {:lemon_node_result, ^invoke_id, {:ok, result}}, 3_000
    assert get_in(result, ["completed", "answer"]) == "wire complete"
    assert get_in(result, ["completed", "usage", "input_tokens"]) == 3
    assert NodeStore.get_invocation(invoke_id) == nil
    send(context.runner_pid, :stop)

    assert {:ok, cancel_id} =
             LemonCore.NodeRegistry.invoke(
               node_name,
               "coding_agent.run",
               Map.put(invoke_args, "runId", "wire-cancel-#{suffix}"),
               recipient: self(),
               timeout_ms: 3_000
             )

    assert_receive {:fake_executor_started, _request, _opts, ^worker, _cancel_run_ref,
                    cancel_context},
                   3_000

    assert :ok = LemonCore.NodeRegistry.cancel(cancel_id, :test_cancelled)
    assert_receive {:fake_executor_cancelled, ^cancel_context}, 3_000
    assert_receive {:lemon_node_result, ^cancel_id, {:error, :test_cancelled}}, 3_000

    assert :ok = stop_supervised(worker_id)
    assert_eventually(fn -> not LemonCore.NodeRegistry.online?(node_name) end)
  end

  defp put_node(node_id, name) do
    NodeStore.put_node(node_id, %{
      id: node_id,
      name: name,
      type: "coding_agent",
      capabilities: %{"coding_agent.run" => %{"version" => 1}},
      status: :offline
    })
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
