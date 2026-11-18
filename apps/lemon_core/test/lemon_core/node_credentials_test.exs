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

  test "drains a pipe handoff to EOF", %{tmp_dir: root} do
    fifo = Path.join(root, "pipe")
    {_, 0} = System.cmd("mkfifo", [fifo])

    writer =
      Task.async(fn ->
        System.cmd("sh", ["-c", ~s(printf 'LEMON_NODE_TOKEN\\0node\\0' > "$1"), "sh", fifo])
      end)

    assert NodeCredentials.read_pipe!(fifo) == "LEMON_NODE_TOKEN\0node\0"
    assert {_, 0} = Task.await(writer)
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
