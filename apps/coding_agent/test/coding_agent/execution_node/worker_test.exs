defmodule CodingAgent.ExecutionNode.WorkerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodingAgent.ExecutionNode.{TokenStore, Worker}
  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonCore.{ExecutionContext, ResumeToken, ToolPolicy}
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
          context =
            context
            |> Map.put(:cancel_race, request.prompt == "cancel race")
            |> Map.put(:owner_pid, owner)

          send(owner, {:native_drain_started, request.run_id, run_ref, context})
          {:ok, run_ref, context}

        other ->
          other
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

      {:ok, producer} =
        Task.start(fn ->
          receive do
            :finish ->
              response = %AssistantMessage{
                role: :assistant,
                content: [%TextContent{text: "finished"}],
                api: :mock,
                provider: :mock_provider,
                model: "native-drain-model",
                usage: %Usage{input: 1, output: 1, total_tokens: 2, cost: %Cost{}},
                stop_reason: :stop,
                timestamp: System.system_time(:millisecond)
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
        id: "native-drain-model",
        name: "Native Drain Model",
        api: :mock,
        provider: :mock_provider,
        base_url: "https://api.mock.test",
        reasoning: false,
        input: [:text],
        cost: %ModelCost{input: 0.0, output: 0.0},
        context_window: 128_000,
        max_tokens: 4_096,
        headers: %{},
        compat: nil
      }
    end
  end

  defmodule FakeDiscovery do
    def discover(server, cwd) do
      send(
        Process.whereis(:execution_node_worker_test),
        {:discovery_started, self(), server, cwd}
      )

      receive do
        {:finish, result} -> result
        {:raise, secret} -> raise secret
      end
    end
  end

  defmodule FakeProfileSync do
    def apply(args, cwd) do
      send(
        Process.whereis(:execution_node_worker_test),
        {:profile_sync_started, self(), args, cwd}
      )

      receive do
        {:finish, result} -> result
      end
    end

    def status(args, cwd) do
      send(
        Process.whereis(:execution_node_worker_test),
        {:profile_sync_status_started, self(), args, cwd}
      )

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

    assert get_in(socket_opts, [
             :connect_params,
             "capabilities",
             "coding_agent.run",
             "nativePrivacyContext",
             "version"
           ]) == 1

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
                    %{
                      "invokeId" => "invoke-1",
                      "seq" => 1,
                      "event" => %{"type" => "delta", "text" => "done "}
                    }, tag1, 30_000}

    send(
      worker,
      {:execution_node_socket, socket,
       {:response, tag1, {:ok, %{"received" => true, "seq" => 1}}}}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.event",
                    %{
                      "invokeId" => "invoke-1",
                      "seq" => 2,
                      "event" => %{"type" => "delta", "text" => "remotely"}
                    }, tag2, 30_000}

    send(
      worker,
      {:execution_node_socket, socket,
       {:response, tag2, {:ok, %{"received" => true, "seq" => 2}}}}
    )

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
      {:event, "node.invoke.cancel", %{"invokeId" => "invoke-cancel", "nodeId" => "node-1"}}
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
      {:ok, execution_context} =
        ExecutionContext.new(run_id: "run-#{resume_source}", cwd: tmp_dir)

      request = %ExecutionRequest{
        run_id: "run-#{resume_source}",
        session_key: "session-#{resume_source}",
        prompt: "resume #{resume_source}",
        cwd: tmp_dir,
        execution_context: execution_context,
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
    assert pair_params["capabilities"]["coding_agent.run"]["version"] == 2

    for method <-
          ~w(memory.list memory.search memory.get memory.add memory.delete
      memory.transfer.prepare memory.transfer.snapshot memory.transfer.validate
      memory.transfer.preview memory.transfer.apply memory.transfer.status memory.transfer.inspect) do
      assert pair_params["capabilities"][method] == %{"version" => 1, "contextVersion" => 1}
    end

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
  test "authenticated wire proof is reconstructed only after exact run and header binding", %{
    tmp_dir: tmp_dir
  } do
    state = %Worker{name: "newphy", default_cwd: tmp_dir}
    id = "current-native-run"

    proof = %{
      "run_id" => id,
      "server_name" => "core",
      "server_url" => "https://bot.example/mcp",
      "header_name" => "X-Lemon-Bot-Invocation",
      "secret_name" => "lemon_bot/invocations/" <> id
    }

    servers = [
      %{
        "name" => "core",
        "url" => "https://bot.example/mcp",
        "headers" => %{"X-Lemon-Bot-Invocation" => "${LEMON_SECRET:lemon_bot/invocations/#{id}}"}
      }
    ]

    meta = %{
      "invocation_context_key" => "actor",
      "memory_context_key" => "audience",
      "memory_context_verified" => true,
      "shared_memory_grant" => false,
      "invocation_proof_verified" => true,
      "invocation_proof" => proof,
      "mcp_servers" => servers,
      "native_lineage_handle" => String.duplicate("x", 43),
      "native_lineage_run_id" => id
    }

    args = remote_args("invoke", %{"runId" => id, "prompt" => "work", "meta" => meta})
    assert {:ok, request, _} = Worker.execution_request(args, state, "invoke")
    assert request.meta.invocation_proof_verified == true

    assert request.meta.invocation_proof == %{
             run_id: id,
             server_name: "core",
             server_url: "https://bot.example/mcp",
             header_name: "X-Lemon-Bot-Invocation",
             secret_name: "lemon_bot/invocations/" <> id
           }

    assert request.meta.shared_memory_grant == false

    for forged <- [
          Map.put(proof, "run_id", "previous-run"),
          Map.put(proof, "header_name", "Authorization"),
          Map.put(proof, "secret_name", "lemon_bot/invocations/previous-run"),
          Map.put(proof, "unknown", "must-not-ignore")
        ] do
      assert {:error, :invalid_invocation_proof} =
               Worker.execution_request(
                 put_in(args, ["meta", "invocation_proof"], forged),
                 state,
                 "invoke"
               )
    end

    assert {:error, :invalid_invocation_proof} =
             Worker.execution_request(
               put_in(args, ["meta", "memory_context_verified"], false),
               state,
               "invoke"
             )
  end

  @tag :tmp_dir
  test "canonical false proof and grant cannot be upgraded by JSON aliases", %{tmp_dir: tmp_dir} do
    state = %Worker{name: "newphy", default_cwd: tmp_dir}

    args =
      remote_args("invoke", %{
        "version" => 2,
        "prompt" => "work",
        "meta" => %{
          "memory_context_verified" => true,
          "shared_memory_grant" => true,
          "invocation_proof_verified" => true,
          invocation_context_key: "actor",
          memory_context_key: "audience",
          memory_context_verified: false,
          shared_memory_grant: false,
          invocation_proof_verified: false
        }
      })

    assert {:ok, request, _} = Worker.execution_request(args, state, "invoke")
    assert request.meta.memory_context_verified == false
    assert request.meta.shared_memory_grant == false
    assert request.meta.invocation_proof_verified == false
  end

  @tag :tmp_dir
  test "native callbacks use source socket replies without calling the blocked Worker", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    invoke(worker, socket, "invoke-native-source", "node-1", %{
      "version" => 1,
      "prompt" => "work",
      "meta" => %{}
    })

    assert_receive {:executor_started, _request, opts, ^worker, _ref, context}
    source = %{run_id: "actual-source", lineage_handle: String.duplicate("x", 43)}
    caller = Task.async(fn -> opts.native_source_floor_fun.(source, %{allow: ["read"]}) end)

    assert_receive {:socket_request, ^socket, "node.native.lineage.floor",
                    %{
                      "sourceRunId" => "actual-source",
                      "lineageHandle" => _,
                      "toolPolicy" => %{"allow" => ["read"]}
                    }, {:native_reply, recipient, reply_ref}, 30_000}

    assert recipient == caller.pid
    send(recipient, {:native_controller_reply, reply_ref, {:ok, %{}}})
    assert Task.await(caller) == :ok
    :ok = GenServer.stop(worker)
    Process.exit(context.runner_pid, :kill)
  end

  @tag :tmp_dir
  test "rejects unsupported versions and nonexistent request cwd", %{tmp_dir: tmp_dir} do
    state = %Worker{name: "newphy", default_cwd: tmp_dir}

    for version <- [1, 3] do
      assert {:error, :unsupported_protocol_version} =
               Worker.execution_request(
                 %{"version" => version, "prompt" => "work"},
                 state,
                 "invoke"
               )
    end

    assert {:error, :invalid_execution_context} =
             Worker.execution_request(%{"version" => 2, "prompt" => "work"}, state, "invoke")

    assert {:error, {:cwd_not_found, _path}} =
             Worker.execution_request(
               remote_args("invoke", %{
                 "prompt" => "work",
                 "cwd" => Path.join(tmp_dir, "missing")
               }),
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
               remote_args("invoke", %{"prompt" => "work", "cwd" => "projects/lemon"}),
               state,
               "invoke"
             )

    assert request.cwd == nested
  end

  @tag :tmp_dir
  test "event acknowledgement failure cancels the run instead of silently losing output", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    invoke(worker, socket, "invoke-stream-fail", "node-1", %{
      "version" => 1,
      "prompt" => "stream",
      "meta" => %{}
    })

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

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    invoke(worker, socket, "invoke-stream-bound", "node-1", %{
      "version" => 1,
      "prompt" => "stream",
      "meta" => %{}
    })

    assert_receive {:executor_started, _request, _opts, ^worker, run_ref, context}
    for _ <- 1..66, do: send(worker, {:engine_delta, run_ref, "x"})
    assert_receive {:executor_cancelled, ^context}

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"error" => "event_backpressure_limit_exceeded"}, _, 30_000}

    Process.exit(context.runner_pid, :kill)
  end

  @tag :tmp_dir
  test "discovery rejects foreign and duplicate requests without exposing config", %{
    tmp_dir: tmp_dir
  } do
    {worker, socket} = start_service_worker(tmp_dir)
    server = discovery_server()

    service_invoke(worker, socket, "discovery", "foreign-node", "node.mcp.discover", %{
      "server" => server
    })

    refute_receive {:discovery_started, _, _, _}, 50

    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{
      "server" => server
    })

    assert_receive {:discovery_started, task_pid, _, _}
    state = :sys.get_state(worker)
    refute inspect(state.invocations) =~ "private-header-token"

    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{
      "server" => server
    })

    refute_receive {:discovery_started, _, _, _}, 50

    send(task_pid, {:finish, {:ok, discovery_result()}})

    assert_receive {:socket_request, ^socket, "node.invoke.result", params,
                    {:invoke_result, "discovery"}, 30_000}

    refute inspect(params) =~ "private-header-token"
    assert :sys.get_state(worker).invocations == %{}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "profile memory executes on the destination workspace without a local profile record", %{
    tmp_dir: tmp_dir
  } do
    previous_paths = Application.get_env(:lemon_core, :paths)
    state_dir = Path.join(tmp_dir, "worker-state")

    Application.put_env(:lemon_core, :paths,
      home_state_dir: state_dir,
      global_config: Path.join(state_dir, "config.toml")
    )

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    {:ok, paths} = LemonCore.ProfileStore.paths("remote-memory")
    File.mkdir_p!(paths["workspace"])
    assert {:error, :not_found} = LemonCore.ProfileStore.get("remote-memory")

    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => "memory-add",
          "nodeId" => "node-1",
          "method" => "memory.add",
          "args" => %{"profileId" => "remote-memory", "text" => "Prefers peppermint tea"}
        }}}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{
                      "invokeId" => "memory-add",
                      "result" => %{"ok" => true, "payload" => %{"item" => item}}
                    }, {:invoke_result, "memory-add"}, 30_000},
                   1_000

    assert item["source"] == "workspace"
    assert File.read!(Path.join(paths["workspace"], "MEMORY.md")) =~ "peppermint"
    refute_receive {:executor_started, _, _, _, _, _}

    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => "memory-get",
          "nodeId" => "node-1",
          "method" => "memory.get",
          "args" => %{"profileId" => "remote-memory", "id" => item["id"]}
        }}}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"result" => %{"ok" => true, "payload" => %{"item" => fetched}}},
                    {:invoke_result, "memory-get"}, 30_000},
                   1_000

    assert fetched["id"] == item["id"]
    assert {:ok, _} = LemonCore.JSONPayload.validate(fetched)

    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => "memory-invalid",
          "nodeId" => "node-1",
          "method" => "memory.add",
          "args" => %{"profileId" => "../outside", "text" => "must not write"}
        }}}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"result" => %{"ok" => false, "error" => "invalid_id"}},
                    {:invoke_result, "memory-invalid"}, 30_000},
                   1_000

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "finished native runners drain safely through cancel, disconnect and event failure", %{
    tmp_dir: tmp_dir
  } do
    for operation <- [:cancel, :disconnect, :event_failure] do
      worker =
        start_supervised!(
          {Worker,
           [
             node_name: "native-drain",
             controller: "ws://controller:4040/ws",
             allow_insecure_controller: true,
             token: "node-token",
             cwd: tmp_dir,
             notify_pid: self(),
             socket_module: FakeSocket,
             socket_opts: [test_pid: self()],
             executor_module: NativeDrainExecutor
           ]}
        )

      assert_receive {:socket_started, socket, _opts}

      send(
        worker,
        {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
      )

      finished_id = "finished-#{operation}"
      active_id = "active-#{operation}"

      invoke(worker, socket, finished_id, "node-1", %{
        "version" => 1,
        "runId" => finished_id,
        "sessionKey" => "agent:default:#{finished_id}",
        "prompt" => "finish",
        "meta" => %{}
      })

      assert_receive {:native_drain_started, ^finished_id, _finished_ref, finished_context}, 3_000
      assert_receive {:native_drain_stream, ^finished_id, producer}, 3_000
      finished_runner = finished_context.runner_pid
      finished_monitor = Process.monitor(finished_runner)

      assert_receive {:socket_request, ^socket, "node.invoke.event",
                      %{"invokeId" => ^finished_id}, event_tag, 30_000},
                     3_000

      send(producer, :finish)
      assert_receive {:DOWN, ^finished_monitor, :process, ^finished_runner, :normal}, 3_000
      await_completed_drain(worker, finished_id)

      invoke(worker, socket, active_id, "node-1", %{
        "version" => 1,
        "runId" => active_id,
        "sessionKey" => "agent:default:#{active_id}",
        "prompt" => "remain active",
        "meta" => %{}
      })

      assert_receive {:native_drain_started, ^active_id, _active_ref, active_context}, 3_000
      assert_receive {:native_drain_stream, ^active_id, _active_producer}, 3_000
      active_runner = active_context.runner_pid
      assert Process.alive?(active_runner)

      case operation do
        :cancel ->
          send(
            worker,
            {:execution_node_socket, socket,
             {:event, "node.invoke.cancel", %{"nodeId" => "node-1", "invokeId" => finished_id}}}
          )

        :disconnect ->
          send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})

        :event_failure ->
          send(
            worker,
            {:execution_node_socket, socket, {:response, event_tag, {:error, :timeout}}}
          )
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
  test "disconnect, explicit cancellation, invocation removal and worker stop kill discovery tasks",
       %{tmp_dir: tmp_dir} do
    for action <- [:disconnect, :cancel, :removal, :stop] do
      {worker, socket} = start_service_worker(tmp_dir)

      service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{
        "server" => discovery_server()
      })

      assert_receive {:discovery_started, task_pid, _, _}
      monitor = Process.monitor(task_pid)

      case action do
        :disconnect ->
          send(worker, {:execution_node_socket, socket, {:disconnected, :closed}})

        :cancel ->
          send(
            worker,
            {:execution_node_socket, socket,
             {:event, "node.invoke.cancel", %{"nodeId" => "node-1", "invokeId" => "discovery"}}}
          )

        :removal ->
          task = :sys.get_state(worker).invocations["discovery"].service_task
          send(worker, {task.ref, {:error, :connection_failed}})

        :stop ->
          GenServer.stop(worker)
      end

      assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}

      if action != :removal,
        do: refute_receive({:socket_request, ^socket, "node.invoke.result", _, _, _}, 50)

      if action != :stop do
        assert :sys.get_state(worker).invocations == %{}
        GenServer.stop(worker)
      end
    end
  end

  @tag :tmp_dir
  test "a native runner exiting concurrently with cancel does not crash the worker", %{
    tmp_dir: tmp_dir
  } do
    worker =
      start_supervised!(
        {Worker,
         [
           node_name: "native-cancel-race",
           controller: "ws://controller:4040/ws",
           allow_insecure_controller: true,
           token: "node-token",
           cwd: tmp_dir,
           socket_module: FakeSocket,
           socket_opts: [test_pid: self()],
           executor_module: NativeDrainExecutor
         ]}
      )

    assert_receive {:socket_started, socket, _opts}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    invoke(worker, socket, "cancel-race", "node-1", %{
      "version" => 1,
      "runId" => "cancel-race",
      "prompt" => "cancel race",
      "meta" => %{}
    })

    assert_receive {:native_drain_started, "cancel-race", _run_ref, context}, 3_000
    assert_receive {:native_drain_stream, "cancel-race", _producer}, 3_000
    runner = context.runner_pid
    monitor = Process.monitor(runner)

    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.cancel", %{"nodeId" => "node-1", "invokeId" => "cancel-race"}}}
    )

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

  @tag :tmp_dir
  test "abrupt owner death kills its supervised discovery task", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)

    service_invoke(worker, socket, "discovery", "node-1", "node.mcp.discover", %{
      "server" => discovery_server()
    })

    assert_receive {:discovery_started, task_pid, _, _}
    monitor = Process.monitor(task_pid)
    Process.unlink(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^task_pid, :killed}
  end

  @tag :tmp_dir
  test "discovery exceptions and unclassified service errors cannot expose config in replies or logs",
       %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)
    secret = "private-header-token"

    log =
      capture_log(fn ->
        service_invoke(worker, socket, "exception", "node-1", "node.mcp.discover", %{
          "server" => discovery_server()
        })

        assert_receive {:discovery_started, task_pid, _, _}
        send(task_pid, {:raise, secret})

        assert_receive {:socket_request, ^socket, "node.invoke.result",
                        %{"invokeId" => "exception", "error" => "discovery_failed"}, _, _}

        service_invoke(worker, socket, "unclassified", "node-1", "node.mcp.discover", %{
          "server" => discovery_server()
        })

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
  test "discovery rejects missing config and classifies task death without raw reasons", %{
    tmp_dir: tmp_dir
  } do
    {worker, socket} = start_service_worker(tmp_dir)
    service_invoke(worker, socket, "invalid", "node-1", "node.mcp.discover", %{})

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "invalid", "error" => "invalid_config"}, _, _}

    refute_receive {:discovery_started, _, _, _}, 50

    service_invoke(worker, socket, "down", "node-1", "node.mcp.discover", %{
      "server" => discovery_server()
    })

    assert_receive {:discovery_started, task_pid, _, _}
    Process.exit(task_pid, :kill)

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "down", "error" => "discovery_failed"}, _, _}

    assert :sys.get_state(worker).invocations == %{}
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "native execution arguments use the shared execution ceiling while service requests keep the negotiated ceiling",
       %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)

    send(
      worker,
      {:execution_node_socket, socket,
       {:connected, %{"auth" => %{"clientId" => "node-1"}, "policy" => %{"maxPayload" => 128}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    names = Enum.map(1..16_384, &"mcp_tool_#{&1}")
    args = %{"version" => 1, "prompt" => "run", "toolPolicy" => %{"require_approval" => names}}

    service_invoke(
      worker,
      socket,
      "bounded-discovery",
      "node-1",
      "node.mcp.discover",
      Map.put(args, "server", discovery_server())
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "bounded-discovery", "error" => _}, _, _}

    refute_receive {:discovery_started, _, _, _}, 50

    invoke(worker, socket, "dense-policy", "node-1", args)
    assert_receive {:executor_started, request, _opts, ^worker, _ref, context}
    assert request.run_id == "node:dense-policy"

    over_ceiling =
      Enum.map(1..LemonCore.ToolPolicy.execution_max_items(), &"t#{&1}")

    over_args = %{
      "version" => 1,
      "prompt" => "run",
      "toolPolicy" => %{"require_approval" => over_ceiling}
    }

    invoke(worker, socket, "over-ceiling", "node-1", over_args)

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "over-ceiling", "error" => _}, _, _}

    refute_receive {:executor_started, _, _, _, _, _}, 50
    GenServer.stop(worker)
    Process.exit(context.runner_pid, :kill)
  end

  @tag :tmp_dir
  test "dense bounded discovery schemas retain all JSON-safe items", %{tmp_dir: tmp_dir} do
    {worker, socket} = start_service_worker(tmp_dir)

    service_invoke(worker, socket, "dense-discovery", "node-1", "node.mcp.discover", %{
      "server" => discovery_server()
    })

    assert_receive {:discovery_started, task_pid, _, _}

    tools =
      Enum.map(1..16, fn index ->
        %{
          "name" => "tool_#{index}",
          "executionName" => "mcp_tool_#{index}",
          "description" => "",
          "readOnly" => false,
          "inputSchema" => %{"type" => "object", "enum" => List.duplicate(0, 1_024)}
        }
      end)

    result = Map.merge(discovery_result(), %{"tools" => tools, "count" => length(tools)})
    send(task_pid, {:finish, {:ok, result}})

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"invokeId" => "dense-discovery", "result" => ^result}, _, _}

    GenServer.stop(worker)
  end

  defp start_service_worker(tmp_dir) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())

    {:ok, worker} =
      start_worker(tmp_dir,
        token: "node-token",
        mcp_discovery_module: FakeDiscovery,
        profile_sync_module: FakeProfileSync,
        task_supervisor: supervisor
      )

    assert_receive {:socket_started, socket, _opts}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}
    {worker, socket}
  end

  defp service_invoke(worker, socket, invoke_id, node_id, method, args) do
    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{"invokeId" => invoke_id, "nodeId" => node_id, "method" => method, "args" => args}}}
    )
  end

  defp discovery_server do
    %{
      "name" => "bot",
      "url" => "https://example.com/mcp",
      "headers" => %{"Authorization" => "Bearer private-header-token"}
    }
  end

  defp discovery_result do
    %{
      "connected" => true,
      "server" => %{"name" => "bot", "status" => "connected"},
      "tools" => [],
      "count" => 0,
      "truncated" => false
    }
  end

  @tag :tmp_dir
  test "oversized private source snapshot is a bounded refusal, not an unknown transfer", %{
    tmp_dir: tmp_dir
  } do
    previous_paths = Application.get_env(:lemon_core, :paths)
    state_dir = Path.join(tmp_dir, "transfer-limit-state")

    Application.put_env(:lemon_core, :paths,
      home_state_dir: state_dir,
      global_config: Path.join(state_dir, "config.toml")
    )

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    {:ok, paths} = LemonCore.ProfileStore.paths("worker-transfer-limit")
    File.mkdir_p!(paths["workspace"])

    File.write!(
      Path.join(paths["workspace"], "MEMORY.md"),
      "# Memory\n\n" <> String.duplicate("Saved full fact.\n", 1_000)
    )

    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _opts}

    send(
      worker,
      {:execution_node_socket, socket,
       {:connected, %{"auth" => %{"clientId" => "node-1"}, "policy" => %{"maxPayload" => 16_384}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    send(
      worker,
      {:execution_node_socket, socket,
       {:event, "node.invoke.request",
        %{
          "invokeId" => "source-overflow",
          "nodeId" => "node-1",
          "method" => "memory.transfer.prepare",
          "args" => %{
            "profileId" => "worker-transfer-limit",
            "sourceNodeId" => "node-1",
            "nodeId" => "node-2",
            "mutationId" => "overflow-#{System.unique_integer([:positive])}"
          }
        }}}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result",
                    %{"result" => %{"ok" => false, "error" => "snapshot_too_large"}},
                    {:invoke_result, "source-overflow"}, 30_000},
                   1_000

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "completed remote runs index only original admitted ownership in the destination store", %{
    tmp_dir: tmp_dir
  } do
    store = :"worker_private_store_#{System.unique_integer([:positive])}"
    ingest = :"worker_private_ingest_#{System.unique_integer([:positive])}"
    start_supervised!({LemonMemory.Store, name: store, path: Path.join(tmp_dir, "memory")})

    start_supervised!(
      {LemonMemory.Ingest,
       name: ingest,
       memory_store: store,
       config_loader: fn ->
         %{
           features: %LemonCore.Config.Features{
             session_search: :"default-on",
             routing_feedback: :off
           }
         }
       end}
    )

    {:ok, worker} = start_worker(tmp_dir, token: "node-token", memory_ingest_server: ingest)
    assert_receive {:socket_started, socket, _}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    args = %{
      "version" => 1,
      "runId" => "private-indexed",
      "sessionKey" => "agent:worker-private:main",
      "prompt" => "Remember rainforest deployment decisions.",
      "cwd" => tmp_dir,
      "meta" => %{
        "agent_id" => "worker-private",
        "profile_id" => "worker-private",
        "invocation_context_key" => "invocation-epoch-1",
        "memory_context_key" => "actor-a",
        "memory_context_verified" => true,
        "mcp_servers" => %{"private" => %{"env" => %{"API_KEY" => "must-not-index"}}}
      }
    }

    invoke(worker, socket, "private-index", "node-1", args)
    assert_receive {:executor_started, request, _, ^worker, run_ref, context}
    assert request.meta[:memory_context_verified] == true
    assert request.meta[:memory_context_key] == "actor-a"
    assert LemonMemory.Store.get_by_session(store, args["sessionKey"], limit: 10) == []

    send(
      worker,
      {:engine_event, run_ref,
       %{
         __event__: :completed,
         ok: true,
         answer: "Rainforest releases require cypress approval.",
         error: nil,
         usage: nil,
         resume: nil,
         meta: %{
           memory_context_key: "actor-b",
           memory_context_verified: true,
           profile_id: "other-profile"
         }
       }}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result", _,
                    {:invoke_result, "private-index"}, 30_000}

    :sys.get_state(Process.whereis(ingest))
    assert [doc] = LemonMemory.Store.get_by_session(store, args["sessionKey"], limit: 10)
    assert doc.agent_id == "worker-private"
    assert doc.meta["memory_context_key"] == "actor-a"
    assert doc.meta["memory_context_verified"] == true
    refute Map.has_key?(doc.meta, "mcp_servers")
    refute Map.has_key?(doc.meta, :mcp_servers)
    assert Map.get(doc.meta, :profile_id, Map.get(doc.meta, "profile_id")) == "worker-private"
    {:ok, paths} = LemonCore.ProfileStore.paths("worker-private")

    {:ok, identity} =
      LemonMemory.Project.scope(%{
        session_scope: :main,
        agent_id: "worker-private",
        workspace_dir: paths["workspace"],
        cwd: tmp_dir
      })

    assert doc.meta["home_digest"] == identity.home_digest

    assert {:ok, [^doc]} =
             LemonMemory.Store.search_owned(
               store,
               "rainforest",
               "worker-private",
               identity.home_digest,
               {:private, "actor-a"}
             )

    assert {:ok, []} =
             LemonMemory.Store.search_owned(
               store,
               "rainforest",
               "worker-private",
               identity.home_digest,
               {:private, "actor-b"}
             )

    invoke(worker, socket, "private-aborted", "node-1", Map.put(args, "runId", "private-aborted"))
    assert_receive {:executor_started, _, _, ^worker, aborted_ref, aborted_context}

    send(
      worker,
      {:engine_event, aborted_ref,
       %{
         __event__: :completed,
         ok: false,
         answer: "",
         error: "watchdog_cancelled password=hunter2",
         usage: nil,
         resume: nil,
         meta: %{}
       }}
    )

    assert_receive {:socket_request, ^socket, "node.invoke.result", _,
                    {:invoke_result, "private-aborted"}, 30_000}

    :sys.get_state(Process.whereis(ingest))

    aborted =
      LemonMemory.Store.get_by_session(store, args["sessionKey"], limit: 10)
      |> Enum.find(&(&1.run_id == "private-aborted"))

    assert aborted.outcome == :aborted
    refute inspect(aborted) =~ "hunter2"
    Process.exit(aborted_context.runner_pid, :kill)
    Process.exit(context.runner_pid, :kill)
    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "canonical false and nil request proof cannot be upgraded by string aliases", %{
    tmp_dir: tmp_dir
  } do
    {:ok, worker} = start_worker(tmp_dir, token: "node-token")
    assert_receive {:socket_started, socket, _}

    send(
      worker,
      {:execution_node_socket, socket, {:connected, %{"auth" => %{"clientId" => "node-1"}}}}
    )

    assert_receive {:execution_node_worker, ^worker, {:status, :online, "node-1"}}

    for {canonical, suffix} <- [{false, "false"}, {nil, "nil"}] do
      invoke_id = "proof-#{suffix}"

      meta = %{
        "agent_id" => "worker-private",
        "invocation_context_key" => "invocation-1",
        "memory_context_key" => "actor-a",
        "memory_context_verified" => true,
        "shared_memory_grant" => true,
        memory_context_verified: canonical,
        shared_memory_grant: canonical
      }

      invoke(worker, socket, invoke_id, "node-1", %{
        "version" => 1,
        "prompt" => "bounded",
        "cwd" => tmp_dir,
        "meta" => meta
      })

      assert_receive {:executor_started, request, _, ^worker, run_ref, context}
      assert request.meta[:memory_context_verified] == canonical
      assert request.meta[:shared_memory_grant] == canonical
      refute Map.has_key?(request.meta, "memory_context_verified")
      refute Map.has_key?(request.meta, "shared_memory_grant")
      assert {:error, :unproven_context} = LemonMemory.ContextScope.scope(request.meta)

      send(
        worker,
        {:engine_event, run_ref,
         %{
           __event__: :completed,
           ok: true,
           answer: "done",
           error: nil,
           usage: nil,
           meta: %{},
           resume: nil
         }}
      )

      assert_receive {:socket_request, ^socket, "node.invoke.result", _,
                      {:invoke_result, ^invoke_id}, 30_000}

      Process.exit(context.runner_pid, :kill)
    end

    GenServer.stop(worker)
  end

  @tag :tmp_dir
  test "intersects remote authority with destination execution capabilities", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, context} =
             ExecutionContext.new(
               run_id: "capability-run",
               cwd: tmp_dir,
               tool_policy: ToolPolicy.custom(allow: ["read", "write"]),
               capabilities: ["read", "write"]
             )

    assert {:ok, remote_context} = ExecutionContext.for_remote(context, tmp_dir)
    assert {:ok, encoded_context} = ExecutionContext.encode(remote_context)

    state = %Worker{
      name: "newphy",
      default_cwd: tmp_dir,
      execution_capabilities: ["read"]
    }

    assert {:ok, request, _opts} =
             Worker.execution_request(
               %{
                 "version" => 2,
                 "runId" => "capability-run",
                 "prompt" => "work",
                 "cwd" => tmp_dir,
                 "executionContext" => encoded_context
               },
               state,
               "invoke"
             )

    assert request.execution_context.capabilities == ["read"]
    assert ToolPolicy.allowed?(request.tool_policy, "read")
    refute ToolPolicy.allowed?(request.tool_policy, "write")
  end

  @tag :tmp_dir
  test "validates wire authority identity, version and policy without losing destination ceilings",
       %{
         tmp_dir: tmp_dir
       } do
    state = %Worker{name: "newphy", default_cwd: tmp_dir, execution_capabilities: ["read"]}
    args = remote_args("authority", %{"prompt" => "work", "toolPolicy" => %{allow: :all}})

    assert {:error, :execution_context_run_id_mismatch} =
             Worker.execution_request(Map.put(args, "runId", "other-run"), state, "authority")

    future = put_in(args, ["executionContext", "version"], 2)

    assert {:error, {:unsupported_execution_context_version, 2}} =
             Worker.execution_request(future, state, "authority")

    malformed = Map.put(args, "toolPolicy", %{"allow" => 123})

    assert {:error, {:invalid_policy_field, :allow}} =
             Worker.execution_request(malformed, state, "authority")

    assert {:ok, request, _opts} = Worker.execution_request(args, state, "authority")
    assert request.execution_context.run_id == args["runId"]
    assert request.execution_context.workspace_scope.root == tmp_dir
    assert request.execution_context.capabilities == ["read"]
    assert ToolPolicy.allowed?(request.execution_context.tool_policy, "read")
    refute ToolPolicy.allowed?(request.execution_context.tool_policy, "write")

    narrower = Map.put(args, "toolPolicy", %{"deny" => ["read"]})
    assert {:ok, request, _opts} = Worker.execution_request(narrower, state, "authority")
    refute ToolPolicy.allowed?(request.execution_context.tool_policy, "read")
    refute ToolPolicy.allowed?(request.execution_context.tool_policy, "write")
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
    args = remote_args(invoke_id, args)

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

  defp remote_args(invoke_id, args) do
    if args["version"] == 2 and is_map(args["executionContext"]) do
      args
    else
      run_id = args["runId"] || "node:#{invoke_id}"

      {:ok, context} =
        ExecutionContext.new(run_id: run_id, cwd: File.cwd!())

      {:ok, context} = ExecutionContext.for_remote(context, args["cwd"])
      {:ok, encoded_context} = ExecutionContext.encode(context)

      args
      |> Map.put("version", 2)
      |> Map.put("runId", run_id)
      |> Map.put("executionContext", encoded_context)
    end
  end
end
