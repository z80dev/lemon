defmodule CodingAgent.ExecutionNode.PTYTest do
  use ExUnit.Case, async: false
  alias CodingAgent.ExecutionNode.PTY

  test "destination PTY has a terminal, accepts input and resize, and reports shell exit" do
    root = Path.join(System.tmp_dir!(), "lemon-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, pid} = PTY.start_link(self(), "pty-test", %{"cwd" => root, "cols" => 80, "rows" => 24},
      default_cwd: root, allowed_roots: [root])
    assert_receive {:node_pty, "pty-test", "ready", %{}}, 5_000
    assert :ok = PTY.command(pid, "resize", %{"cols" => 100, "rows" => 40})
    input = "test -t 0 && printf '\\n__LEMON_REAL_PTY__\\n'; exit 7\n"
    assert :ok = PTY.command(pid, "input", %{"dataBase64" => Base.encode64(input)})
    output = receive_terminal(pid, "", 0)
    assert output =~ "__LEMON_REAL_PTY__"
    assert_receive {:node_pty, "pty-test", "exit", %{"code" => 7}}, 5_000
  end

  test "worker policy rejects a cwd outside allowed roots" do
    Process.flag(:trap_exit, true)
    assert {:error, _} = PTY.start_link(self(), "blocked", %{"cwd" => "/"},
      default_cwd: System.user_home!(), allowed_roots: [System.user_home!()])
  end

  defp receive_terminal(pid, acc, count) when count < 100 do
    receive do
      {:node_pty, "pty-test", "output", %{"dataBase64" => data}} ->
        PTY.ack(pid)
        next = acc <> Base.decode64!(data)
        if String.contains?(next, "\r\n__LEMON_REAL_PTY__\r\n"), do: next,
          else: receive_terminal(pid, next, count + 1)
    after
      5_000 -> flunk("PTY did not produce the destination terminal marker")
    end
  end
  defp receive_terminal(_pid, _acc, _count), do: flunk("PTY output exceeded test bound")
end
