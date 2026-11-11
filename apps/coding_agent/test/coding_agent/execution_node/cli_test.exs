defmodule CodingAgent.ExecutionNode.CLITest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.CLI
  alias CodingAgent.ExecutionNode.Worker

  defmodule UnavailableSocket do
    def start_link(_opts), do: {:error, :fixture_socket_unavailable}
  end

  setup do
    original = Application.fetch_env(:lemon_core, :require_owned_loopback)
    trust = System.get_env("LEMON_NODE_TRUST_LOOPBACK_LISTENER")

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :require_owned_loopback, value)
        :error -> Application.delete_env(:lemon_core, :require_owned_loopback)
      end

      if trust,
        do: System.put_env("LEMON_NODE_TRUST_LOOPBACK_LISTENER", trust),
        else: System.delete_env("LEMON_NODE_TRUST_LOOPBACK_LISTENER")
    end)
  end

  @tag :tmp_dir
  test "enables ownership checks unless the exact explicit trust opt-out is set", %{tmp_dir: root} do
    for {override, required?} <- [{nil, true}, {"true", true}, {"0", true}, {"1", false}] do
      if override,
        do: System.put_env("LEMON_NODE_TRUST_LOOPBACK_LISTENER", override),
        else: System.delete_env("LEMON_NODE_TRUST_LOOPBACK_LISTENER")

      assert {:error, _} =
               CLI.run(
                 [
                   "--name",
                   "guard-fixture",
                   "--controller",
                   "ws://127.0.0.1:4044/ws",
                   "--token",
                   "fixture-token",
                   "--cwd",
                   root
                 ],
                 configure_state: fn _ -> :ok end,
                 ensure_all_started: fn _ -> {:ok, []} end,
                 socket_module: UnavailableSocket,
                 status_writer: fn _, _ -> :ok end
               )

      assert Application.get_env(:lemon_core, :require_owned_loopback) == required?
    end

    assert CLI.help() =~ "LEMON_NODE_TRUST_LOOPBACK_LISTENER=1"
    assert CLI.help() =~ "another uid"
  end

  test "explains refused loopback ownership without exposing credentials" do
    assert {:error, reason} =
             CLI.run(
               [
                 "--name",
                 "guard-fixture",
                 "--controller",
                 "ws://127.0.0.1:4044/ws",
                 "--token",
                 "private-node-token"
               ],
               configure_state: fn _ -> {:error, :loopback_listener_not_owned} end
             )

    assert reason =~ "not owned by this user"
    assert reason =~ "LEMON_NODE_TRUST_LOOPBACK_LISTENER=1"
    refute reason =~ "private-node-token"
  end

  @tag :tmp_dir
  test "forwards an isolated status writer to a real worker", %{tmp_dir: tmp_dir} do
    parent = self()

    assert {:error, _} =
             CLI.run(
               [
                 "--name",
                 "status-writer-fixture",
                 "--controller",
                 "ws://127.0.0.1:12345/ws",
                 "--token",
                 "fixture-token",
                 "--cwd",
                 tmp_dir
               ],
               configure_state: fn _ -> :ok end,
               ensure_all_started: fn _ -> {:ok, []} end,
               socket_module: UnavailableSocket,
               status_writer: fn name, status ->
                 send(parent, {:worker_status, name, status})
                 :ok
               end
             )

    assert_receive {:worker_status, "status-writer-fixture", %{"state" => "starting"}}
  end

  test "parses the node join surface" do
    assert {:ok, opts} =
             CLI.parse([
               "--name",
               "newphy",
               "--controller",
               "wss://controller.example/ws",
               "--pair",
               "--node-id",
               "node-1",
               "--repair",
               "--allow-insecure-controller",
               "--cwd",
               "/tmp",
               "--capabilities",
               "read,write"
             ])

    assert opts[:name] == "newphy"
    assert opts[:controller] == "wss://controller.example/ws"
    assert opts[:pair] == true
    assert opts[:node_id] == "node-1"
    assert opts[:repair] == true
    assert opts[:allow_insecure_controller] == true
    assert opts[:cwd] == "/tmp"
    assert opts[:capabilities] == "read,write"
  end

  test "requires name and controller and documents environment token use" do
    assert {:error, "--name is required"} = CLI.parse(["--controller", "ws://host/ws"])
    assert {:error, "--controller is required"} = CLI.parse(["--name", "worker"])
    assert CLI.help() =~ "LEMON_NODE_OPERATOR_TOKEN"
    assert CLI.help() =~ "mode-0600"
    assert CLI.help() =~ "--allow-insecure-controller"
    assert CLI.help() =~ "--capabilities"
    assert CLI.help() =~ "LEMON_NODE_CAPABILITIES"
    assert CLI.help() =~ "verified encrypted overlay"
  end

  test "uses the caller's launch cwd unless --cwd is explicit" do
    assert CLI.default_cwd([], "/caller/project", "/lemon/source") == "/caller/project"

    assert CLI.default_cwd([cwd: "/explicit/project"], "/caller/project", "/lemon/source") ==
             "/explicit/project"
  end

  test "accepts the insecure controller environment override explicitly" do
    previous = System.get_env("LEMON_NODE_ALLOW_INSECURE_CONTROLLER")

    on_exit(fn ->
      if previous,
        do: System.put_env("LEMON_NODE_ALLOW_INSECURE_CONTROLLER", previous),
        else: System.delete_env("LEMON_NODE_ALLOW_INSECURE_CONTROLLER")
    end)

    System.delete_env("LEMON_NODE_ALLOW_INSECURE_CONTROLLER")
    refute CLI.allow_insecure_controller?([])

    System.put_env("LEMON_NODE_ALLOW_INSECURE_CONTROLLER", "true")
    assert CLI.allow_insecure_controller?([])
    assert CLI.allow_insecure_controller?(allow_insecure_controller: true)
  end

  test "invite enrollment implies pairing without operator credentials" do
    assert {:ok, opts} =
             CLI.parse([
               "--name",
               "bot",
               "--controller",
               "wss://controller.example/ws",
               "--invite-code-stdin"
             ])

    assert opts[:pair]
    assert opts[:invite_code_stdin]
    refute opts[:invite_code]
    refute opts[:operator_token]
  end

  test "rejects invite recovery combinations and never echoes enrollment secrets" do
    base = ["--name", "bot", "--controller", "wss://controller.example/ws", "--invite-code-stdin"]

    for flags <- [
          ["--repair"],
          ["--node-id", "other"],
          ["--token", "session"],
          ["--operator-token", "operator"]
        ] do
      assert {:error, message} = CLI.parse(base ++ flags)
      refute message =~ "sensitive-enrollment"
    end

    assert {:error, _} =
             CLI.parse([
               "--name",
               "bot",
               "--controller",
               "wss://controller.example/ws",
               "--invite-code",
               "retired-argument-credential"
             ])

    assert {:error, message} = CLI.parse(base ++ ["--bad-option=sensitive-enrollment"])
    refute message =~ "sensitive-enrollment"
  end

  test "repeatable allowed roots are destination-local and extend the home default" do
    assert CLI.allowed_roots([]) == [System.user_home!()]

    assert {:ok, opts} =
             CLI.parse([
               "--name",
               "bot",
               "--controller",
               "wss://controller.example/ws",
               "--allowed-root",
               "/srv/bots",
               "--allowed-root",
               "/mnt/data"
             ])

    assert CLI.allowed_roots(opts) == [System.user_home!(), "/srv/bots", "/mnt/data"]
    assert CLI.help() =~ "--allowed-root"
  end

  test "compatibility JSON inspection gates enrollment without starting a worker" do
    snapshot = %{
      "protocol" => 1,
      "lemonVersion" => "2026.10.3",
      "features" => %{"hostIO" => false},
      "missingFeatures" => ["hostIO"],
      "botReady" => false,
      "methods" => []
    }

    deps = [runtime_features: fn -> snapshot end]

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.run(["capabilities", "--json"], deps)
      end)

    assert Jason.decode!(output) == snapshot

    ExUnit.CaptureIO.capture_io(fn ->
      assert {:error, message} = CLI.run(["capabilities", "--json", "--require-bot"], deps)
      assert message =~ "missing"
    end)

    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, message} =
             CLI.run(
               ["--name", "bot", "--controller", "ws://127.0.0.1:1/ws", "--invite-code-stdin"],
               deps
             )

    assert message =~ "matching source checkout"
    refute message =~ "private-enrollment"
  end

  test "compatible inspection requires an exact optional version pin and redacts bad flags" do
    snapshot = %{
      "protocol" => 1,
      "lemonVersion" => "2026.10.3",
      "features" => %{},
      "missingFeatures" => [],
      "botReady" => true,
      "methods" => []
    }

    deps = [runtime_features: fn -> snapshot end]

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok =
               CLI.run(
                 ["capabilities", "--json", "--require-bot", "--expected-version", "2026.10.3"],
                 deps
               )

      assert {:error, _} = CLI.run(["capabilities", "--expected-version", "2026.10.4"], deps)
      assert {:error, _} = CLI.run(["capabilities", "--expected-version", "latest"], deps)
    end)

    assert {:error, message} = CLI.run(["capabilities", "--bad-option=private"], deps)
    refute message =~ "private"
  end

  test "invalid stdin credentials fail before worker startup without normalizing input" do
    deps = [runtime_features: fn -> %{"botReady" => true} end]
    argv = ["--name", "bot", "--controller", "wss://controller.example/ws", "--invite-code-stdin"]

    for input <- [
          "",
          "short\n",
          String.duplicate("A", 44) <> "\n",
          String.duplicate("A", 42) <> "!\n",
          String.duplicate("A", 42) <> "\0\n",
          String.duplicate("A", 43) <> "\nextra",
          String.duplicate("A", 43) <> "\r\n"
        ] do
      output =
        ExUnit.CaptureIO.capture_io([input: input], fn ->
          assert {:error, message} = CLI.run(argv, deps)
          assert message =~ "stdin"
          refute message =~ String.duplicate("A", 42)
        end)

      assert output == ""
    end
  end

  test "unsafe enrollment destinations fail without consuming stdin" do
    for url <- [
          "ws://remote.example/ws",
          "wss://user:secret@host/ws",
          "wss://host/ws?secret=value",
          "wss://host/ws#fragment"
        ] do
      assert {:error, _} =
               CLI.parse(["--name", "bot", "--controller", url, "--invite-code-stdin"])
    end
  end

  test "uncertain invite exchange stops rather than replaying its immutable credential" do
    state = %Worker{
      socket: self(),
      socket_mode: :pairing,
      invite_code: String.duplicate("A", 43),
      pairing_stage: :requesting
    }

    for tag <- [:pair_request, :pair_approve, {:pair_challenge, "bound-node"}],
        reason <- [:timeout, :disconnected] do
      assert {:stop, {:pairing_failed, :outcome_unknown}, ^state} =
               Worker.handle_info(
                 {:execution_node_socket, self(), {:response, tag, {:error, reason}}},
                 state
               )
    end

    assert {:stop, {:pairing_failed, :outcome_unknown}, ^state} =
             Worker.handle_info({:execution_node_socket, self(), {:disconnected, :closed}}, state)

    assert {:stop, {:pairing_failed, :outcome_unknown}, ^state} =
             Worker.handle_info({:execution_node_socket, self(), {:connected, %{}}}, state)
  end

  test "one-shot local runtime startup failure has a bounded non-rejection result" do
    deps = [
      runtime_features: fn -> %{"botReady" => true} end,
      configure_state: fn _ -> :ok end,
      ensure_all_started: fn _ ->
        {:error, {:coding_agent, {:health, :eaddrinuse, "/private/path"}}}
      end
    ]

    ExUnit.CaptureIO.capture_io([input: String.duplicate("A", 43) <> "\n"], fn ->
      assert {:error, :enroll_start_failed} =
               CLI.run(
                 [
                   "--name",
                   "bot",
                   "--controller",
                   "wss://controller.example/ws",
                   "--invite-code-stdin",
                   "--enroll-only"
                 ],
                 deps
               )
    end)
  end

  test "only an explicit pre-consumption controller refusal rejects an invite" do
    state = %Worker{socket: self(), socket_mode: :pairing, invite_code: String.duplicate("A", 43)}
    rejection = %{"code" => "UNAUTHORIZED", "message" => "private server diagnostic"}

    assert {:stop, {:pairing_failed, :invite_rejected}, ^state} =
             Worker.handle_info(
               {:execution_node_socket, self(), {:response, :pair_request, {:error, rejection}}},
               state
             )

    assert {:stop, {:pairing_failed, :outcome_unknown}, ^state} =
             Worker.handle_info(
               {:execution_node_socket, self(),
                {:response, {:pair_challenge, "node"}, {:error, rejection}}},
               state
             )

    for {stage, outcome} <- [{nil, :invite_rejected}, {:requesting, :outcome_unknown}] do
      current = %{state | pairing_stage: stage}

      assert {:noreply, ^current} =
               Worker.handle_info(
                 {:execution_node_socket, self(), {:authentication_error, rejection}},
                 current
               )

      assert_receive {:stop_after_authentication_error, {:pairing_failed, ^outcome}}
    end

    worker =
      spawn(fn ->
        receive do
          :reject -> exit({:pairing_failed, :invite_rejected})
        end
      end)

    monitor = Process.monitor(worker)
    send(worker, :reject)
    assert {:error, :invite_rejected} = CLI.await_worker(worker, monitor, enroll_only: true)
  end

  test "normalizes the destination execution capability ceiling" do
    assert {:ok, :all} = CLI.execution_capabilities([], nil)
    assert {:ok, :all} = CLI.execution_capabilities([capabilities: "*"], "read")

    assert {:ok, ["read", "write"]} =
             CLI.execution_capabilities([capabilities: " read,write,read "], nil)

    assert {:ok, ["bash"]} = CLI.execution_capabilities([], "bash")

    assert {:error, "--capabilities must be 'all' or a comma-separated tool list"} =
             CLI.execution_capabilities([capabilities: ""], nil)
  end

  test "--enroll-only requires --invite-code-stdin" do
    assert {:error, "--enroll-only requires --invite-code-stdin"} =
             CLI.parse([
               "--name",
               "bot",
               "--controller",
               "wss://controller.example/ws",
               "--enroll-only"
             ])

    assert {:ok, opts} =
             CLI.parse([
               "--name",
               "bot",
               "--controller",
               "wss://controller.example/ws",
               "--invite-code-stdin",
               "--enroll-only"
             ])

    assert opts[:enroll_only] == true
    assert opts[:invite_code_stdin] == true
  end

  test "--enroll-only stops the worker before returning the first online status" do
    {:ok, worker} = Agent.start(fn -> :enrolled end)
    monitor = Process.monitor(worker)
    send(self(), {:execution_node_worker, worker, {:status, :online, "node-abc"}})

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok = CLI.await_worker(worker, monitor, enroll_only: true)
      end)

    assert output =~ "Execution node online (node-abc)"
    refute Process.alive?(worker)
  end

  test "uncertain enrollment returns its stable code without another exchange" do
    worker =
      spawn(fn ->
        receive do
          :fail -> exit({:pairing_failed, :outcome_unknown})
        end
      end)

    monitor = Process.monitor(worker)
    send(worker, :fail)

    assert {:error, :enrollment_outcome_unknown} =
             CLI.await_worker(worker, monitor, enroll_only: true)

    refute Process.alive?(worker)
  end

  test "a parked one-shot enrollment exits without leaving a worker running" do
    {:ok, worker} = Agent.start(fn -> :enrolling end)
    monitor = Process.monitor(worker)
    send(self(), {:execution_node_worker, worker, {:status, :needs_reauthorization, :expired}})

    ExUnit.CaptureIO.capture_io(fn ->
      assert {:error, :enrollment_outcome_unknown} =
               CLI.await_worker(worker, monitor, enroll_only: true)
    end)

    refute Process.alive?(worker)
  end

  test "normal exit before online never claims one-shot enrollment succeeded" do
    {:ok, worker} = Agent.start(fn -> :enrolling end)
    monitor = Process.monitor(worker)
    Agent.stop(worker)

    assert {:error, :enrollment_outcome_unknown} =
             CLI.await_worker(worker, monitor, enroll_only: true)
  end
end
