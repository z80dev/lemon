defmodule CodingAgent.ExecutionNode.CLITest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.CLI

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
               "/tmp"
             ])

    assert opts[:name] == "newphy"
    assert opts[:controller] == "wss://controller.example/ws"
    assert opts[:pair] == true
    assert opts[:node_id] == "node-1"
    assert opts[:repair] == true
    assert opts[:allow_insecure_controller] == true
    assert opts[:cwd] == "/tmp"
  end

  test "requires name and controller and documents environment token use" do
    assert {:error, "--name is required"} = CLI.parse(["--controller", "ws://host/ws"])
    assert {:error, "--controller is required"} = CLI.parse(["--name", "worker"])
    assert CLI.help() =~ "LEMON_NODE_OPERATOR_TOKEN"
    assert CLI.help() =~ "mode-0600"
    assert CLI.help() =~ "--allow-insecure-controller"
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
end
