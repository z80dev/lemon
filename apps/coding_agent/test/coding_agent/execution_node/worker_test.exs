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

  defmodule NativeDrainExecutor do
    alias LemonAi.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}

    def start_run(request, opts, sink_pid) do
      request = %{request | meta: Map.put(request.meta || %{}, :model, model())}
      owner = Process.whereis(:execution_node_worker_test)
      stream_fn = fn _model, _context, _options -> stream(owner, request.run_id) end
      case CodingAgent.Executor.start_run(request, Map.put(opts, :stream_fn, stream_fn), sink_pid) do
        {:ok, run_ref, context} ->
          context = context
            |> Map.put(:cancel_race, request.prompt == "cancel race")
            |> Map.put(:owner_pid, owner)
          send(owner, {:native_drain_started, request.run_id, run_ref, context})
          {:ok, run_ref, context}
        other -> other
      end
    end

    def cancel(context) do
      send(context.owner_pid, {:native_drain_cancelled, context.runner_pid})
      # Model a runner that exits between cancellation dispatch and GenServer.call.
      if context.cancel_race, do: GenServer.stop(context.runner_pid, :normal)
      CodingAgent.Executor.cancel(context)
    end

    defp stream(owner, run_id) do
      {:ok, stream} = LemonAi.EventStream.start_link()
      {:ok, producer} = Task.start(fn ->
        receive do
          :finish ->
            response = %AssistantMessage{
              role: :assistant, content: [%TextContent{text: "finished"}],
              api: :mock, provider: :mock_provider, model: "native-drain-model",
              usage: %Usage{input: 1, output: 1, total_tokens: 2, cost: %Cost{}},
              stop_reason: :stop, timestamp: System.system_time(:millisecond)
            }
            LemonAi.EventStream.push(stream, {:start, response})
            LemonAi.EventStream.push(stream, {:text_delta, 0, "finished", response})
            LemonAi.EventStream.push(stream, {:done, :stop, response})
            LemonAi.EventStream.complete(stream, response)
        end
      end)
      LemonAi.EventStream.attach_task(stream, producer)
      send(owner, {:native_drain_stream, run_id, producer})
      {:ok, stream}
    end

    defp model do
      %Model{
        id: "native-drain-model", name: "Native Drain Model", api: :mock,
        provider: :mock_provider, base_url: "https://api.mock.test",
        reasoning: false, input: [:text], cost: %ModelCost{input: 0.0, output: 0.0},
        context_window: 128_000, max_tokens: 4_096, headers: %{}, compat: nil
      }
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


    assert_receive {:socket_request, ^socket, "node.invoke.event",
                    %{"invokeId" => "invoke-1", "seq" => 1,
                      "event" => %{"type" => "delta", "text" => "done "}}, tag1, 30_000}
    send(worker, {:execution_node_socket, socket,
                  {:response, tag1, {:ok, %{"received" => true, "seq" => 1}}}})
    assert_receive {:socket_request, ^socket, "node.invoke.event",
                    %{"invokeId" => "invoke-1", "seq" => 2,
                      "event" => %{"type" => "delta", "text" => "remotely"}}, tag2, 30_000}
    send(worker, {:execution_node_socket, socket,
                  {:response, tag2, {:ok, %{"received" => true, "seq" => 2}}}})
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
  test "event acknowledgement failure cancels the run instead of silently losing output", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket,
                  {:connected, %{"auth" => %{"clientId" => "node-1"}}}})
    invoke(worker, socket, "invoke-stream-fail", "node-1",
           %{"version" => 1, "prompt" => "stream", "meta" => %{}})
    assert_receive {:executor_started, _request, _opts, ^worker, run_ref, context}
    send(worker, {:engine_delta, run_ref, "live"})
    assert_receive {:socket_request, ^socket, "node.invoke.event", _params, tag, 30_000}
    send(worker, {:execution_node_socket, socket, {:response, tag, {:error, :timeout}}})
    assert_receive {:executor_cancelled, ^context}
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"error" => "event_delivery_failed"}, _, 30_000}
    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "bounded unacknowledged events fail closed", %{tmp_dir: tmp_dir} do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket,
                  {:connected, %{"auth" => %{"clientId" => "node-1"}}}})
    invoke(worker, socket, "invoke-stream-bound", "node-1",
           %{"version" => 1, "prompt" => "stream", "meta" => %{}})
    assert_receive {:executor_started, _request, _opts, ^worker, run_ref, context}
    for _ <- 1..66, do: send(worker, {:engine_delta, run_ref, "x"})
    assert_receive {:executor_cancelled, ^context}
    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"error" => "event_backpressure_limit_exceeded"}, _, 30_000}
    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "finished native runners drain safely through cancel, disconnect and event failure", %{tmp_dir: tmp_dir} do
    for operation <- [:cancel, :disconnect, :event_failure] do
      worker = start_supervised!({Worker, [
        node_name: "native-drain", controller: "ws://controller:4040/ws",
        allow_insecure_controller: true, token: "node-token", cwd: tmp_dir,
        notify_pid: self(), socket_module: FakeSocket, socket_opts: [test_pid: self()],
        executor_module: NativeDrainExecutor
      ]})
      assert_receive {:socket_started, socket, _opts}
      send(worker, {:execution_node_socket, socket,
                    {:connected, %{"auth" => %{"clientId" => "node-1"}}}})
      finished_id = "finished-#{operation}"
      active_id = "active-#{operation}"
      invoke(worker, socket, finished_id, "node-1", %{
        "version" => 1, "runId" => finished_id, "sessionKey" => "agent:default:#{finished_id}",
        "prompt" => "finish", "meta" => %{}
      })
      assert_receive {:native_drain_started, ^finished_id, _finished_ref, finished_context}, 3_000
      assert_receive {:native_drain_stream, ^finished_id, producer}, 3_000
      finished_runner = finished_context.runner_pid
      finished_monitor = Process.monitor(finished_runner)
      assert_receive {:socket_request, ^socket, "node.invoke.event",
                      %{"invokeId" => ^finished_id}, event_tag, 30_000}, 3_000
      send(producer, :finish)
      assert_receive {:DOWN, ^finished_monitor, :process, ^finished_runner, :normal}, 3_000
      await_completed_drain(worker, finished_id)
      invoke(worker, socket, active_id, "node-1", %{
        "version" => 1, "runId" => active_id, "sessionKey" => "agent:default:#{active_id}",
        "prompt" => "remain active", "meta" => %{}
      })
      assert_receive {:native_drain_started, ^active_id, _active_ref, active_context}, 3_000
      assert_receive {:native_drain_stream, ^active_id, _active_producer}, 3_000
      active_runner = active_context.runner_pid
      assert Process.alive?(active_runner)

      case operation do
        :cancel ->
          send(worker, {:execution_node_socket, socket,
                        {:event, "node.invoke.cancel",
                         %{"nodeId" => "node-1", "invokeId" => finished_id}}})
        :disconnect ->
          send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})
        :event_failure ->
          send(worker, {:execution_node_socket, socket, {:response, event_tag, {:error, :timeout}}})
      end

      await_invocation_removed(worker, finished_id)
      assert Process.alive?(worker)
      refute_receive {:native_drain_cancelled, ^finished_runner}
      if operation == :disconnect do
        assert_receive {:native_drain_cancelled, ^active_runner}
        assert :sys.get_state(worker).invocations == %{}
      else
        assert Process.alive?(active_runner)
        assert Map.has_key?(:sys.get_state(worker).invocations, active_id)
      end
      stop_supervised(Worker)
    end
  end

  @tag :tmp_dir
  test "a native runner exiting concurrently with cancel does not crash the worker", %{tmp_dir: tmp_dir} do
    worker = start_supervised!({Worker, [
      node_name: "native-cancel-race", controller: "ws://controller:4040/ws",
      allow_insecure_controller: true, token: "node-token", cwd: tmp_dir,
      socket_module: FakeSocket, socket_opts: [test_pid: self()],
      executor_module: NativeDrainExecutor
    ]})
    assert_receive {:socket_started, socket, _opts}
    send(worker, {:execution_node_socket, socket,
                  {:connected, %{"auth" => %{"clientId" => "node-1"}}}})
    invoke(worker, socket, "cancel-race", "node-1", %{
      "version" => 1, "runId" => "cancel-race", "prompt" => "cancel race", "meta" => %{}
    })
    assert_receive {:native_drain_started, "cancel-race", _run_ref, context}, 3_000
    assert_receive {:native_drain_stream, "cancel-race", _producer}, 3_000
    runner = context.runner_pid
    monitor = Process.monitor(runner)
    send(worker, {:execution_node_socket, socket,
                  {:event, "node.invoke.cancel",
                   %{"nodeId" => "node-1", "invokeId" => "cancel-race"}}})
    assert_receive {:DOWN, ^monitor, :process, ^runner, :normal}, 3_000
    await_invocation_removed(worker, "cancel-race")
    assert Process.alive?(worker)
    stop_supervised(Worker)
  end

  defp await_completed_drain(worker, invoke_id, attempts \\ 300) do
    invocation = :sys.get_state(worker).invocations[invoke_id]
    if invocation && invocation.completed do
      :ok
    else
      assert attempts > 0, "native completion did not reach transport-draining state"
      Process.sleep(10)
      await_completed_drain(worker, invoke_id, attempts - 1)
    end
  end

  defp await_invocation_removed(worker, invoke_id, attempts \\ 300) do
    if Map.has_key?(:sys.get_state(worker).invocations, invoke_id) do
      assert attempts > 0, "invocation did not release its transport state"
      Process.sleep(10)
      await_invocation_removed(worker, invoke_id, attempts - 1)
    else
      :ok
    end
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
