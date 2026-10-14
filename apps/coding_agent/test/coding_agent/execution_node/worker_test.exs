defmodule CodingAgent.ExecutionNode.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.ExecutionNode.{TokenStore, Worker}
  alias CodingAgent.Executor.RemoteRequestCodec
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

    def steer(context, text) do
      send(Process.whereis(:execution_node_worker_test), {:executor_steered, context, text})
      :ok
    end
  end

  defmodule FakeDiscovery do
    def discover(server, cwd) do
      send(Process.whereis(:execution_node_worker_test), {:discovery_started, self(), server, cwd})

      receive do
        {:finish, result} -> result
        {:raise, secret} -> raise secret
      end
    end
  end

  defmodule FakeProfileSync do
    def apply(args, cwd) do
      send(Process.whereis(:execution_node_worker_test), {:profile_sync_started, self(), args, cwd})
      receive do
        {:finish, result} -> result
      end
    end

    def status(args, cwd) do
      send(Process.whereis(:execution_node_worker_test), {:profile_sync_status_started, self(), args, cwd})
      receive do
        {:finish, result} -> result
      end
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
  test "steers the live invocation context and acknowledges only after executor acceptance", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    invoke(
      worker,
      socket,
      "invoke-steer",
      "node-1",
      %{
        "version" => 1,
        "runId" => "run-steer",
        "prompt" => "long run",
        "cwd" => nil,
        "meta" => %{}
      }
    )

    assert_receive {:executor_started, _request, _opts, ^worker, _run_ref, context}

    send(worker, {
      :execution_node_socket,
      socket,
      {:event, "node.invoke.control",
       %{
         "nodeId" => "node-1",
         "controlId" => "control-steer",
         "invokeId" => "invoke-steer",
         "runId" => "run-steer",
         "operation" => "steer",
         "text" => "focus on the protocol"
       }}
    })

    assert_receive {:executor_steered, ^context, "focus on the protocol"}

    assert_receive {:socket_request, ^socket, "node.invoke.control.result",
                    %{
                      "controlId" => "control-steer",
                      "invokeId" => "invoke-steer",
                      "runId" => "run-steer",
                      "accepted" => true
                    }, {:invoke_control_result, "control-steer"}, 30_000}

    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "preserves auto and explicit resume sources across the remote codec boundary", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    for resume_source <- [:auto, :explicit] do
      request = %ExecutionRequest{
        run_id: "run-#{resume_source}",
        session_key: "session-#{resume_source}",
        prompt: "resume #{resume_source}",
        cwd: tmp_dir,
        meta: %{resume_source: resume_source}
      }

      assert {:ok, args} = RemoteRequestCodec.encode(request)
      assert args["meta"]["resume_source"] == Atom.to_string(resume_source)

      invoke_id = "invoke-#{resume_source}"
      invoke(worker, socket, invoke_id, "node-1", args)

      assert_receive {:executor_started, remote_request, _opts, ^worker, run_ref, context}
      assert remote_request.meta[:resume_source] == resume_source

      send(worker, {
        :engine_event,
        run_ref,
        %{
          __event__: :completed,
          ok: true,
          answer: "done",
          error: nil,
          usage: nil,
          meta: %{},
          resume: nil
        }
      })

      assert_receive {:socket_request, ^socket, "node.invoke.result", %{"invokeId" => ^invoke_id},
                      {:invoke_result, ^invoke_id}, 30_000}

      Process.exit(context.runner_pid, :kill)
    end

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
      {:response, :pair_approve,
       {:ok,
        %{
          "challengeToken" => "challenge",
          "nodeId" => "node-1",
          "token" => "recovery-token"
        }}}
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

    assert {:ok, stored} =
             TokenStore.load("newphy",
               root: Path.join(tmp_dir, "tokens"),
               controller: "ws://controller:4040/ws"
             )

    assert stored["token"] == "session-token"
    assert stored["nodeId"] == "node-1"
    assert stored["recoveryToken"] == "recovery-token"
    assert {:ok, path} = TokenStore.node_path("node-1", root: Path.join(tmp_dir, "tokens"))
    assert {:ok, %{mode: file_mode}} = File.stat(path)
    assert Bitwise.band(file_mode, 0o777) == 0o600

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "re-pairs a stored node ID with its recovery credential after session expiry", %{
    tmp_dir: tmp_dir
  } do
    token_root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "newphy",
               %{
                 "token" => "expired-session",
                 "nodeId" => "node-1",
                 "controller" => "ws://controller:4040/ws",
                 "recoveryToken" => "recovery-secret"
               },
               root: token_root
             )

    {:ok, worker} = start_worker(tmp_dir, pair: true, operator_token: "operator-secret")
    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket, {:connected, %{}}})

    assert_receive {:socket_request, ^socket, "node.pair.request", pair_params, :pair_request,
                    30_000}

    assert pair_params["nodeId"] == "node-1"
    assert pair_params["recoveryToken"] == "recovery-secret"
    refute Map.has_key?(pair_params, "repair")

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "uses explicit operator repair for a legacy credential without a recovery token", %{
    tmp_dir: tmp_dir
  } do
    token_root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "newphy",
               %{
                 "token" => "legacy-session",
                 "nodeId" => "legacy-node-1",
                 "controller" => "ws://controller:4040/ws"
               },
               root: token_root
             )

    {:ok, worker} =
      start_worker(tmp_dir,
        pair: true,
        repair: true,
        node_id: "legacy-node-1",
        operator_token: "operator-secret"
      )

    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket, {:connected, %{}}})

    assert_receive {:socket_request, ^socket, "node.pair.request", pair_params, :pair_request,
                    30_000}

    assert pair_params["nodeId"] == "legacy-node-1"
    assert pair_params["repair"] == true
    refute Map.has_key?(pair_params, "recoveryToken")

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "loads the durable node credential after the configured name changes", %{tmp_dir: tmp_dir} do
    token_root = Path.join(tmp_dir, "tokens")

    assert :ok =
             TokenStore.save(
               "Before Rename",
               %{
                 "token" => "session-token",
                 "nodeId" => "node-1",
                 "controller" => "ws://controller:4040/ws"
               },
               root: token_root
             )

    {:ok, worker} =
      Worker.start_link(
        node_name: "After Rename",
        node_id: "node-1",
        controller: "ws://controller:4040/ws",
        allow_insecure_controller: true,
        cwd: tmp_dir,
        notify_pid: self(),
        socket_module: FakeSocket,
        socket_opts: [test_pid: self()],
        executor_module: FakeExecutor,
        token_store_opts: [root: token_root]
      )

    assert_receive {:socket_started, socket, socket_opts}
    assert get_in(socket_opts, [:connect_params, "auth", "token"]) == "session-token"

    send(worker, {
      :execution_node_socket,
      socket,
      {:connected, %{"auth" => %{"clientId" => "node-1"}}}
    })

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "blocks non-loopback plaintext controllers unless explicitly overridden", %{
    tmp_dir: tmp_dir
  } do
    previous_trap_exit = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous_trap_exit) end)

    assert {:error, :insecure_controller_url} =
             Worker.start_link(
               node_name: "secure-default",
               controller: "ws://controller.internal:4040/ws",
               token: "token",
               cwd: tmp_dir,
               socket_module: FakeSocket,
               socket_opts: [test_pid: self()]
             )

    assert {:ok, worker} =
             Worker.start_link(
               node_name: "trusted-overlay",
               controller: "ws://100.100.100.100:4040/ws",
               allow_insecure_controller: true,
               token: "token",
               cwd: tmp_dir,
               socket_module: FakeSocket,
               socket_opts: [test_pid: self()]
             )

    assert_receive {:socket_started, _socket, _opts}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "allows plaintext loopback without an override", %{tmp_dir: tmp_dir} do
    assert {:ok, worker} =
             Worker.start_link(
               node_name: "loopback",
               controller: "ws://127.0.0.1:4040/ws",
               token: "token",
               cwd: tmp_dir,
               socket_module: FakeSocket,
               socket_opts: [test_pid: self()]
             )

    assert_receive {:socket_started, _socket, _opts}
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

  @tag :tmp_dir
  test "advertises discovery and profile sync capabilities during pairing", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, pair: true)
    assert_receive {:socket_started, socket, _}
    send(worker, {:execution_node_socket, socket, {:connected, %{}}})
    assert_receive {:socket_request, ^socket, "node.pair.request", params, :pair_request, 30_000}
    assert params["capabilities"]["node.mcp.discover"] == %{"version" => 1}
    assert params["capabilities"]["node.profile.sync"] == %{"version" => 1}
    assert params["capabilities"]["node.profile.sync.status"] == %{"version" => 1}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "discovery is supervised, targeted, nonblocking and returns the exact service payload", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    server = discovery_server()
    service_invoke(worker, socket, "discovery", "foreign-node", "node.mcp.discover", %{"server" => server})
    refute_receive {:discovery_started, _, _, _}, 50
    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{"server" => server})
    assert_receive {:discovery_started, task_pid, ^server, ^tmp_dir}
    state = :sys.get_state(worker)
    assert state.invocations["discovery"].service_task.pid == task_pid
    assert state.invocations["discovery"].service_task.owner == worker
    refute inspect(state.invocations) =~ "private-header-token"
    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{"server" => server})
    refute_receive {:discovery_started, _, _, _}, 50

    send(task_pid, {:finish, {:ok, discovery_result()}})
    assert_receive {:socket_request, ^socket, "node.invoke.result", params, {:invoke_result, "discovery"}, 30_000}
    assert params == %{"invokeId" => "discovery", "result" => discovery_result()}
    refute inspect(params) =~ "private-header-token"
    assert :sys.get_state(worker).invocations == %{}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "disconnect, explicit cancellation, invocation removal and worker stop kill discovery tasks", %{tmp_dir: tmp_dir} do
    for action <- [:disconnect, :cancel, :removal, :stop] do
      {worker, socket} = start_service_worker(tmp_dir)
      service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{"server" => discovery_server()})
      assert_receive {:discovery_started, task_pid, _, _}
      monitor = Process.monitor(task_pid)

      case action do
        :disconnect ->
          send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})
        :cancel ->
          send(worker, {:execution_node_socket, socket, {:event, "node.invoke.cancel", %{"invokeId" => "discovery"}}})
        :removal ->
          task = :sys.get_state(worker).invocations["discovery"].service_task
          send(worker, {task.ref, {:error, :connection_failed}})
        :stop ->
          GenServer.stop(worker)
      end

      assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}
      if action != :removal, do: refute_receive({:socket_request, ^socket, "node.invoke.result", _, _, _}, 50)
      if action != :stop do
        assert :sys.get_state(worker).invocations == %{}
        GenServer.stop(worker)
      end
    end
  end

  @tag :tmp_dir
  test "abrupt owner death kills its supervised discovery task", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{"server" => discovery_server()})
    assert_receive {:discovery_started, task_pid, _, _}
    monitor = Process.monitor(task_pid)
    Process.unlink(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}
  end

  @tag :tmp_dir
  test "discovery exceptions and unclassified service errors cannot expose config in replies or logs", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    secret = "private-header-token"

    log = capture_log(fn ->
      service_invoke(worker, socket, "exception", "node-1", "node.mcp.discover", %{"server" => discovery_server()})
      assert_receive {:discovery_started, task_pid, _, _}
      send(task_pid, {:raise, secret})
      assert_receive {:socket_request, ^socket, "node.invoke.result",
                      %{"invokeId" => "exception", "error" => "discovery_failed"}, _, _}
      service_invoke(worker, socket, "unclassified", "node-1", "node.mcp.discover", %{"server" => discovery_server()})
      assert_receive {:discovery_started, task_pid, _, _}
      send(task_pid, {:finish, {:error, {:secret, secret}}})
      assert_receive {:socket_request, ^socket, "node.invoke.result",
                      %{"invokeId" => "unclassified", "error" => "discovery_failed"}, _, _}
    end)

    refute log =~ secret
    refute log =~ "Authorization"
    refute log =~ "LEMON_SECRET"
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "discovery origin policy failures retain static classifications without destination details", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)

    for reason <- [
          :invalid_url, :invalid_origin_policy, :origin_not_allowed,
          :dns_resolution_failed, :invalid_dns_answer, :too_many_dns_addresses,
          :destination_not_public, :destination_not_allowed
        ] do
      invoke_id = Atom.to_string(reason)
      service_invoke(worker, socket, invoke_id, "node-1", "node.mcp.discover", %{"server" => discovery_server()})
      assert_receive {:discovery_started, task_pid, _, _}
      send(task_pid, {:finish, {:error, reason}})
      assert_receive {:socket_request, ^socket, "node.invoke.result",
                      %{"invokeId" => ^invoke_id, "error" => ^invoke_id}, _, _}
    end

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "discovery rejects missing config and classifies task death without raw reasons", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    service_invoke(worker, socket, "invalid", "node-1", "node.mcp.discover", %{})
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "invalid", "error" => "invalid_config"}, _, _}
    refute_receive {:discovery_started, _, _, _}, 50
    service_invoke(worker, socket, "down", "node-1", "node.mcp.discover", %{"server" => discovery_server()})
    assert_receive {:discovery_started, task_pid, _, _}
    Process.exit(task_pid, :kill)
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "down", "error" => "discovery_failed"}, _, _}
    assert :sys.get_state(worker).invocations == %{}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "profile synchronization uses the same cancellable supervised service lifecycle", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    args = %{"profileId" => "writer", "model" => nil, "systemPrompt" => "Evidence first", "personaInstructions" => %{"SOUL.md" => "Be careful"}, "revisionDigest" => "digest", "mutationId" => "mutation"}
    service_invoke(worker, socket, "sync", "node-1", "node.profile.sync", args)
    assert_receive {:profile_sync_started, task_pid, ^args, ^tmp_dir}
    result = %{"profileId" => "writer", "revisionDigest" => "digest", "mutationId" => "mutation", "acknowledged" => true}
    send(task_pid, {:finish, {:ok, result}})
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "sync", "result" => ^result}, _, _}

    service_invoke(worker, socket, "sync-cancel", "node-1", "node.profile.sync", args)
    assert_receive {:profile_sync_started, task_pid, _, _}
    monitor = Process.monitor(task_pid)
    send(worker, {:execution_node_socket, socket, {:event, "node.invoke.cancel", %{"invokeId" => "sync-cancel"}}})
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "sync status is a targeted read-only cancellable service dispatch", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    args = %{"profileId" => "writer", "mutationId" => "fixed", "revisionDigest" => String.duplicate("a", 64)}
    service_invoke(worker, socket, "status-foreign", "foreign-node", "node.profile.sync.status", args)
    refute_receive {:profile_sync_status_started, _, _, _}, 50
    service_invoke(worker, socket, "status", "node-1", "node.profile.sync.status", args)
    assert_receive {:profile_sync_status_started, task_pid, ^args, ^tmp_dir}
    refute_receive {:profile_sync_started, _, _, _}, 50
    result = Map.merge(args, %{"status" => "acknowledged", "acknowledged" => true})
    send(task_pid, {:finish, {:ok, result}})
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "status", "result" => ^result}, _, _}
    service_invoke(worker, socket, "status-cancel", "node-1", "node.profile.sync.status", args)
    assert_receive {:profile_sync_status_started, task_pid, _, _}
    monitor = Process.monitor(task_pid)
    send(worker, {:execution_node_socket, socket, {:event, "node.invoke.cancel", %{"invokeId" => "status-cancel"}}})
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "full native policy traversal reaches the executor and respects advertised bytes", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    names = Enum.map(1..16_384, &"mcp_tool_#{&1}")
    args = %{"version" => 1, "prompt" => "run", "toolPolicy" => %{"require_approval" => names}}
    invoke(worker, socket, "dense-policy", "node-1", args)
    assert_receive {:executor_started, request, _opts, ^worker, _ref, context}
    assert request.tool_policy["require_approval"] == names
    send(worker, {:execution_node_socket, socket, {:connected,
      %{"auth" => %{"clientId" => "node-1"}, "policy" => %{"maxPayload" => 128}}}})
    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}
    invoke(worker, socket, "bounded-policy", "node-1", args)
    assert_receive {:socket_request, ^socket, "node.invoke.result",
      %{"invokeId" => "bounded-policy", "error" => _}, _, _}
    refute_receive {:executor_started, _, _, _, _, _}, 50
    GenServer.stop(worker)
    Process.exit(context.runner_pid, :kill)
  end

  @tag :tmp_dir
  test "dense bounded discovery schemas retain all JSON-safe items", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    service_invoke(worker, socket, "dense-discovery", "node-1", "node.mcp.discover",
      %{"server" => discovery_server()})
    assert_receive {:discovery_started, task_pid, _, _}
    tools = Enum.map(1..16, fn index ->
      %{"name" => "tool_#{index}", "executionName" => "mcp_tool_#{index}",
        "description" => "", "readOnly" => false,
        "inputSchema" => %{"type" => "object", "enum" => List.duplicate(0, 1_024)}}
    end)
    result = Map.merge(discovery_result(), %{"tools" => tools, "count" => length(tools)})
    send(task_pid, {:finish, {:ok, result}})
    assert_receive {:socket_request, ^socket, "node.invoke.result",
      %{"invokeId" => "dense-discovery", "result" => ^result}, _, _}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "profile path lookup dispatches the read-only destination owner", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    {:ok, paths} = LemonCore.ProfileStore.paths("owning-skill-path")
    args = %{"profileId" => "owning-skill-path"}
    service_invoke(worker, socket, "paths-foreign", "foreign-node", "node.profile.paths", args)
    refute_receive {:socket_request, ^socket, "node.invoke.result", _, _, _}, 50
    service_invoke(worker, socket, "paths", "node-1", "node.profile.paths", args)
    expected = %{"profileId" => "owning-skill-path", "workspacePath" => paths["workspace"], "skillsPath" => paths["skills"]}
    assert_receive {:socket_request, ^socket, "node.invoke.result",
      %{"invokeId" => "paths", "result" => ^expected}, _, _}
    refute_receive {:profile_sync_started, _, _, _}, 50
    refute_receive {:executor_started, _, _, _, _, _}, 50
    GenServer.stop(worker)
  end

  defp start_service_worker(tmp_dir) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())
    {:ok, worker} = start_worker(tmp_dir, token: "node-token", mcp_discovery_module: FakeDiscovery, profile_sync_module: FakeProfileSync, task_supervisor: supervisor)
    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}})
    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}
    {worker, socket}
  end

  defp service_invoke(worker, socket, invoke_id, node_id, method, args) do
    send(worker, {:execution_node_socket, socket, {:event, "node.invoke.request",
      %{"invokeId" => invoke_id, "nodeId" => node_id, "method" => method, "args" => args}}})
  end

  defp discovery_server do
    %{"name" => "bot", "url" => "https://example.com/mcp", "headers" => %{"Authorization" => "Bearer private-header-token"}}
  end

  defp discovery_result do
    %{"connected" => true, "server" => %{"name" => "bot", "status" => "connected"}, "tools" => [], "count" => 0, "truncated" => false}
  end

  defp start_worker(tmp_dir, extra_opts) do
    Worker.start_link(
      [
        node_name: "newphy",
        controller: "ws://controller:4040/ws",
        allow_insecure_controller: true,
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
