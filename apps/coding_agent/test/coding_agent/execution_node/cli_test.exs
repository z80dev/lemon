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
  test "invite enrollment implies pairing without operator credentials" do
    assert {:ok, opts} =
             CLI.parse(["--name", "bot", "--controller", "wss://controller.example/ws",
               "--invite-code", "single-use-enrollment"])
    assert opts[:pair]
    assert opts[:invite_code] == "single-use-enrollment"
    refute opts[:operator_token]
    assert CLI.help() =~ "--invite-code"
  end

  test "rejects invite recovery combinations and never echoes enrollment secrets" do
    base = ["--name", "bot", "--controller", "wss://controller.example/ws",
      "--invite-code", "sensitive-enrollment"]
    for flags <- [["--repair"], ["--node-id", "other"], ["--token", "session"],
                  ["--operator-token", "operator"]] do
      assert {:error, message} = CLI.parse(base ++ flags)
      refute message =~ "sensitive-enrollment"
    end
    assert {:error, _} = CLI.parse(["--name", "bot", "--controller", "wss://controller.example/ws",
      "--invite-code", ""])
    assert {:error, message} = CLI.parse(base ++ ["--bad-option=sensitive-enrollment"])
    refute message =~ "sensitive-enrollment"
  end

  test "repeatable allowed roots are destination-local and extend the home default" do
    assert CLI.allowed_roots([]) == [System.user_home!()]
    assert {:ok, opts} = CLI.parse(["--name", "bot", "--controller", "wss://controller.example/ws",
      "--allowed-root", "/srv/bots", "--allowed-root", "/mnt/data"])
    assert CLI.allowed_roots(opts) == [System.user_home!(), "/srv/bots", "/mnt/data"]
    assert CLI.help() =~ "--allowed-root"
  end

end
