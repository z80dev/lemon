defmodule CodingAgent.ExecutionNode.CLITest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.CLI
  alias CodingAgent.ExecutionNode.Worker

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

  test "normalizes the destination execution capability ceiling" do
    assert {:ok, :all} = CLI.execution_capabilities([], nil)
    assert {:ok, :all} = CLI.execution_capabilities([capabilities: "*"], "read")

    assert {:ok, ["read", "write"]} =
             CLI.execution_capabilities([capabilities: " read,write,read "], nil)

    assert {:ok, ["bash"]} = CLI.execution_capabilities([], "bash")

    assert {:error, "--capabilities must be 'all' or a comma-separated tool list"} =
             CLI.execution_capabilities([capabilities: ""], nil)
  end
end
