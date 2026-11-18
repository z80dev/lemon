defmodule LemonCore.NodeCredentialsTest do
  # Mutates the BEAM OS environment and a global persistent term.
  use ExUnit.Case, async: false

  alias LemonCore.NodeCredentials

  @moduletag :tmp_dir

  setup do
    on_exit(fn ->
      System.delete_env("LEMON_NODE_CREDENTIAL_FD")
      NodeCredentials.consume_handoff()
    end)
  end

  # The real fd-3 pipe is exercised end to end by the launcher test in
  # CodingAgent.ExecutionNode.CredentialEnvTest; here only the drain itself.
  test "drains the handoff descriptor to EOF, NUL bytes and newlines intact",
       %{tmp_dir: root} do
    path = Path.join(root, "handoff")
    File.write!(path, "LEMON_NODE_TOKEN\0no\nde\0")
    assert NodeCredentials.read_pipe!(path) == "LEMON_NODE_TOKEN\0no\nde\0"
    File.write!(path, "")
    assert NodeCredentials.read_pipe!(path) == ""
  end

  test "an unreadable or malformed handoff refuses to start", %{tmp_dir: root} do
    assert_raise RuntimeError, ~r/handoff unreadable/, fn ->
      NodeCredentials.read_pipe!(Path.join(root, "missing"))
    end

    System.put_env("LEMON_NODE_CREDENTIAL_FD", "7")

    assert_raise RuntimeError,
                 ~r/invalid LEMON_NODE_CREDENTIAL_FD/,
                 &NodeCredentials.consume_handoff/0

    assert System.get_env("LEMON_NODE_CREDENTIAL_FD") == nil
  end

  test "without a handoff take/1 reads the variable once and removes it" do
    System.delete_env("LEMON_NODE_CREDENTIAL_FD")
    assert :ok = NodeCredentials.consume_handoff()
    System.put_env("LEMON_NODE_TOKEN", "direct")
    assert NodeCredentials.take("LEMON_NODE_TOKEN") == "direct"
    assert System.get_env("LEMON_NODE_TOKEN") == nil
    assert NodeCredentials.take("LEMON_NODE_TOKEN") == nil
  end
end
