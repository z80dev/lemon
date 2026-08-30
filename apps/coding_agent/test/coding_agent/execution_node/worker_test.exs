defmodule CodingAgent.ExecutionNode.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.ExecutionNode.{TokenStore, Worker}
  alias LemonCore.ResumeToken
  alias LemonGateway.ExecutionRequest

  defmodule FakeSocket do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def request(pid, method, params, tag, timeout_ms) do
      GenServer.call(pid, {:request, method, params, tag, timeout_ms})
    end

    def stop(pid), do: GenServer.stop(pid, :normal)

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:socket_started, self(), opts})
      {:ok, %{test_pid: test_pid}}
    end

    @impl true
    def handle_call({:request, method, params, tag, timeout_ms}, _from, state) do
      send(state.test_pid, {:socket_request, self(), method, params, tag, timeout_ms})
      {:reply, "fake-request-id", state}
    end
  end

  defmodule FakeExecutor do
    def start_run(%ExecutionRequest{} = request, opts, sink_pid) do
      run_ref = make_ref()
      runner_pid = spawn(fn -> Process.sleep(:infinity) end)
      context = %{runner_pid: runner_pid, marker: request.run_id}

      send(Process.whereis(:execution_node_worker_test), {
        :executor_started,
        request,
        opts,
        sink_pid,
        run_ref,
        context
      })

      {:ok, run_ref, context}
    end

    def cancel(context) do
      send(Process.whereis(:execution_node_worker_test), {:executor_cancelled, context})
      :ok
    end
  end

  setup do
    Process.register(self(), :execution_node_worker_test)

    on_exit(fn ->
      if Process.whereis(:execution_node_worker_test),
        do: Process.unregister(:execution_node_worker_test)
    end)

    :ok
  end

  @tag :tmp_dir
  test "runs targeted invocations locally, strips meta.node, and returns completion", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, socket_opts}
    assert get_in(socket_opts, [:connect_params, "auth", "token"]) == "node-token"

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    args = %{
      "version" => 1,
      "runId" => "run-1",
      "sessionKey" => "session-1",
      "prompt" => "do the work",
      "images" => [],
      "cwd" => tmp_dir,
      "resume" => nil,
      "lane" => nil,
      "toolPolicy" => nil,
      "meta" => %{"node" => "newphy", "agent_id" => "main"}
    }

    invoke(worker, socket, "invoke-1", "node-1", args)

    assert_receive {:executor_started, request, run_opts, ^worker, run_ref, context}
    assert request.cwd == tmp_dir
    assert request.prompt == "do the work"
    assert request.meta[:agent_id] == "main"
    refute Map.has_key?(request.meta, "node")
    refute Map.has_key?(request.meta, :node)
    refute Map.has_key?(run_opts, :node)

    send(worker, {:engine_delta, run_ref, "done "})
    send(worker, {:engine_delta, run_ref, "remotely"})

    send(worker, {
      :engine_event,
      run_ref,
      %{
        __event__: :completed,
        ok: true,
        answer: "",
        error: nil,
        usage: %{input_tokens: 4},
        meta: %{provider: "test"},
        resume: ResumeToken.new("lemon", "resume-1")
      }
    })

    assert_receive {:socket_request, ^socket, "node.invoke.result", result_params,
                    {:invoke_result, "invoke-1"}, 30_000}

    assert result_params["invokeId"] == "invoke-1"

    assert result_params["result"] == %{
             "completed" => %{
               "ok" => true,
               "answer" => "done remotely",
               "error" => nil,
               "usage" => %{"input_tokens" => 4},
               "meta" => %{"provider" => "test"},
               "resume" => %{"engine" => "lemon", "value" => "resume-1"}
             }
           }

    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "handles targeted cancellation through the existing executor", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    args = %{"version" => 1, "prompt" => "long run", "cwd" => nil, "meta" => %{}}
    invoke(worker, socket, "invoke-cancel", "node-1", args)

    assert_receive {:executor_started, _request, _opts, ^worker, _run_ref, context}

    send(worker, {
      :execution_node_socket,
      socket,
      {:event, "node.invoke.cancel", %{"invokeId" => "invoke-cancel"}}
    })

    assert_receive {:executor_cancelled, ^context}
    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "cancels local work when the controller connection is lost", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    args = %{"version" => 1, "prompt" => "long run", "cwd" => nil, "meta" => %{}}
    invoke(worker, socket, "invoke-disconnect", "node-1", args)

    assert_receive {:executor_started, _request, _opts, ^worker, run_ref, context}

    send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})

    assert_receive {:executor_cancelled, ^context}

    send(worker, {
      :engine_event,
      run_ref,
      %{
        __event__: :completed,
        ok: true,
        answer: "late",
        error: nil,
        usage: nil,
        meta: %{},
        resume: nil
      }
    })

    refute_receive {:socket_request, ^socket, "node.invoke.result", _, _, _}, 50
    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "pairs, stores the challenge-issued token privately, and reconnects as the node", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, pair: true, operator_token: "operator-secret")
    assert_receive {:socket_started, pairing_socket, pairing_opts}
    assert get_in(pairing_opts, [:connect_params, "auth", "token"]) == "operator-secret"

    send(worker, {:execution_node_socket, pairing_socket, {:connected, %{}}})

    assert_receive {:socket_request, ^pairing_socket, "node.pair.request", pair_params,
                    :pair_request, 30_000}

    assert pair_params["nodeName"] == "newphy"
    assert pair_params["capabilities"]["coding_agent.run"]["version"] == 1

    send(worker, {
      :execution_node_socket,
      pairing_socket,
      {:response, :pair_request, {:ok, %{"pairingId" => "pair-1"}}}
    })

    assert_receive {:socket_request, ^pairing_socket, "node.pair.approve",
                    %{"pairingId" => "pair-1"}, :pair_approve, 30_000}

    send(worker, {
      :execution_node_socket,
      pairing_socket,
      {:response, :pair_approve, {:ok, %{"challengeToken" => "challenge", "nodeId" => "node-1"}}}
    })

    assert_receive {:socket_request, ^pairing_socket, "connect.challenge",
                    %{"challenge" => "challenge"}, {:pair_challenge, "node-1"}, 30_000}

    send(worker, {
      :execution_node_socket,
      pairing_socket,
      {:response, {:pair_challenge, "node-1"},
       {:ok,
        %{
          "token" => "session-token",
          "identity" => %{"nodeId" => "node-1"}
        }}}
    })

    assert_receive {:socket_started, node_socket, node_opts}
    assert node_socket != pairing_socket
    assert get_in(node_opts, [:connect_params, "auth", "token"]) == "session-token"

    assert {:ok, stored} = TokenStore.load("newphy", root: Path.join(tmp_dir, "tokens"))
    assert stored["token"] == "session-token"
    assert stored["nodeId"] == "node-1"
    assert {:ok, path} = TokenStore.path("newphy", root: Path.join(tmp_dir, "tokens"))
    assert {:ok, %{mode: file_mode}} = File.stat(path)
    assert Bitwise.band(file_mode, 0o777) == 0o600

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "fails pairing with a redacted actionable reason when the controller requires a token", %{
    tmp_dir: tmp_dir
  } do
    Process.flag(:trap_exit, true)
    {:ok, worker} = start_worker(tmp_dir, pair: true)
    assert_receive {:socket_started, socket, socket_opts}
    refute Map.has_key?(socket_opts[:connect_params], "auth")

    secret = "must-never-appear-in-the-exit-reason"

    log =
      capture_log(fn ->
        send(worker, {
          :execution_node_socket,
          socket,
          {:authentication_error,
           %{
             "code" => "UNAUTHORIZED",
             "message" => "Operator token is required",
             "details" => secret
           }}
        })

        assert_receive {:execution_node_worker, ^worker, {:status, :authentication_error}}
        assert_receive {:EXIT, ^worker, :operator_token_required}
      end)

    refute log =~ secret
  end

  @tag :tmp_dir
  test "resumes the approved pairing id after a socket drop", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, pair: true)
    assert_receive {:socket_started, socket, _opts}

    send(worker, {:execution_node_socket, socket, {:connected, %{}}})
    assert_receive {:socket_request, ^socket, "node.pair.request", _, :pair_request, 30_000}

    send(worker, {
      :execution_node_socket,
      socket,
      {:response, :pair_request, {:ok, %{"pairingId" => "pair-recover"}}}
    })

    assert_receive {:socket_request, ^socket, "node.pair.approve",
                    %{"pairingId" => "pair-recover"}, :pair_approve, 30_000}

    send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})
    send(worker, {:execution_node_socket, socket, {:connected, %{}}})

    assert_receive {:socket_request, ^socket, "node.pair.approve",
                    %{"pairingId" => "pair-recover"}, :pair_approve, 30_000}

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "cancels execution before streamed result accumulation exceeds maxPayload", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}, "policy" => %{"maxPayload" => 8_500}}}
    })

    invoke(
      worker,
      socket,
      "invoke-bounded",
      "node-1",
      %{"version" => 1, "prompt" => "stream", "meta" => %{}}
    )

    assert_receive {:executor_started, _request, _opts, ^worker, run_ref, context}
    send(worker, {:engine_delta, run_ref, String.duplicate("x", 400)})

    assert_receive {:executor_cancelled, ^context}

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "invoke-bounded", "error" => "result_payload_limit_exceeded"},
                    {:invoke_result, "invoke-bounded"}, 30_000}

    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "rejects a stored token that authenticates as a different node", %{tmp_dir: tmp_dir} do
    token_root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "newphy",
               %{
                 "token" => "session-token",
                 "nodeId" => "expected-node",
                 "controller" => "ws://controller:4040/ws"
               },
               root: token_root
             )

    Process.flag(:trap_exit, true)
    {:ok, worker} = start_worker(tmp_dir, [])
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "different-node"}}}
    })

    assert_receive {:EXIT, ^worker,
                    {:authenticated_node_id_mismatch,
                     %{expected: "expected-node", actual: "different-node"}}},
                   1_000
  end

  @tag :tmp_dir
  test "rejects unsupported versions and nonexistent request cwd", %{tmp_dir: tmp_dir} do
    state = %Worker{name: "newphy", default_cwd: tmp_dir}

    assert {:error, :unsupported_protocol_version} =
             Worker.execution_request(%{"version" => 2, "prompt" => "work"}, state, "invoke")

    assert {:error, {:cwd_not_found, _path}} =
             Worker.execution_request(
               %{"version" => 1, "prompt" => "work", "cwd" => Path.join(tmp_dir, "missing")},
               state,
               "invoke"
             )
  end

  @tag :tmp_dir
  test "resolves relative invocation cwd from the node default", %{tmp_dir: tmp_dir} do
    nested = Path.join(tmp_dir, "projects/lemon")
    File.mkdir_p!(nested)
    state = %Worker{name: "newphy", default_cwd: tmp_dir}

    assert {:ok, request, _opts} =
             Worker.execution_request(
               %{"version" => 1, "prompt" => "work", "cwd" => "projects/lemon"},
               state,
               "invoke"
             )

    assert request.cwd == nested
  end

  defp start_worker(tmp_dir, extra_opts) do
    Worker.start_link(
      [
        node_name: "newphy",
        controller: "ws://controller:4040/ws",
        cwd: tmp_dir,
        notify_pid: self(),
        socket_module: FakeSocket,
        socket_opts: [test_pid: self()],
        executor_module: FakeExecutor,
        token_store_opts: [root: Path.join(tmp_dir, "tokens")]
      ] ++ extra_opts
    )
  end

  defp invoke(worker, socket, invoke_id, node_id, args) do
    send(worker, {
      :execution_node_socket,
      socket,
      {:event, "node.invoke.request",
       %{
         "invokeId" => invoke_id,
         "nodeId" => node_id,
         "nodeName" => "newphy",
         "method" => "coding_agent.run",
         "args" => args
       }}
    })
  end
end
