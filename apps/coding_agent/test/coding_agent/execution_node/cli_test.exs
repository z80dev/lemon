defmodule CodingAgent.ExecutionNode.CLITest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.CLI

  test "parses the node join surface" do
    assert {:ok, opts} =
             CLI.parse([
               "--name",
               "newphy",
               "--controller",
               "wss://controller.example/ws",
               "--pair",
               "--cwd",
               "/tmp"
             ])

    assert opts[:name] == "newphy"
    assert opts[:controller] == "wss://controller.example/ws"
    assert opts[:pair] == true
    assert opts[:cwd] == "/tmp"
  end

  test "requires name and controller and documents environment token use" do
    assert {:error, "--name is required"} = CLI.parse(["--controller", "ws://host/ws"])
    assert {:error, "--controller is required"} = CLI.parse(["--name", "worker"])
    assert CLI.help() =~ "LEMON_NODE_OPERATOR_TOKEN"
    assert CLI.help() =~ "mode-0600"
  end

  test "uses the caller's launch cwd unless --cwd is explicit" do
    assert CLI.default_cwd([], "/caller/project", "/lemon/source") == "/caller/project"

    assert CLI.default_cwd([cwd: "/explicit/project"], "/caller/project", "/lemon/source") ==
             "/explicit/project"
  end
end
