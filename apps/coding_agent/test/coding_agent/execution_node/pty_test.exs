defmodule CodingAgent.ExecutionNode.PTYTest do
  use ExUnit.Case, async: false
  alias CodingAgent.ExecutionNode.PTY

  test "destination PTY has a terminal, accepts input and resize, and reports shell exit" do
    root = Path.join(System.tmp_dir!(), "lemon-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, pid} =
      PTY.start_link(self(), "pty-test", %{"cwd" => root, "cols" => 80, "rows" => 24},
        default_cwd: root,
        allowed_roots: [root]
      )

    assert_receive {:node_pty, "pty-test", "ready", %{}}, 5_000
    assert :ok = PTY.command(pid, "resize", %{"cols" => 100, "rows" => 40})
    input = "test -t 0 && printf '\\n__LEMON_REAL_PTY__\\n'; exit 7\n"
    assert :ok = PTY.command(pid, "input", %{"dataBase64" => Base.encode64(input)})
    {code, output} = receive_terminal(pid, "", 0)
    assert output =~ "\r\n__LEMON_REAL_PTY__\r\n"
    assert code == 7
  end

  test "worker policy rejects a cwd outside allowed roots" do
    Process.flag(:trap_exit, true)

    assert {:error, _} =
             PTY.start_link(self(), "blocked", %{"cwd" => "/"},
               default_cwd: System.user_home!(),
               allowed_roots: [System.user_home!()]
             )
  end

  test "helper pins cwd with NOFOLLOW rather than following a swapped directory" do
    root = Path.join(System.tmp_dir!(), "lemon-pty-race-#{System.unique_integer([:positive])}")
    outside = root <> "-outside"
    File.mkdir_p!(Path.join(root, "inside"))
    File.mkdir_p!(outside)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    script = """
    import json,os,struct,sys
    sys.path.insert(0,sys.argv[1])
    import node_pty,node_fs
    root=os.path.realpath(sys.argv[2]); outside=os.path.realpath(sys.argv[3])
    cwd=os.path.join(root,"inside")
    data=json.dumps({"cwd":root,"roots":[root]}).encode()
    read_fd,write_fd=os.pipe()
    try:
        os.write(write_fd,struct.pack("!I",len(data))+data)
    finally:
        os.close(write_fd)
    try:
        os.dup2(read_fd,0)
    finally:
        if read_fd != 0:
            os.close(read_fd)
    original=node_fs.Policy.parent
    def racing_parent(self,path):
        result=original(self,path)
        os.rename(path,path+".parked")
        os.symlink(outside,path)
        return result
    node_fs.Policy.parent=racing_parent
    try:
        fd=node_pty.admitted_cwd(cwd)
        os.close(fd)
        sys.exit(9)
    except OSError:
        print("blocked")
    """

    {output, status} =
      System.cmd(
        System.find_executable("python3"),
        ["-c", script, to_string(:code.priv_dir(:coding_agent)), root, outside],
        stderr_to_stdout: true
      )

    assert status == 0
    assert String.trim(output) == "blocked"
  end

  test "importing descriptor helpers neither consumes stdin nor emits service frames" do
    script = """
    import os,sys
    sys.path.insert(0,sys.argv[1])
    os.close(0)
    import node_fs,node_pty
    assert callable(node_fs.main)
    assert callable(node_fs.Policy.parent)
    assert callable(node_pty.admitted_cwd)
    print("import-safe")
    """

    {output, status} =
      System.cmd(
        System.find_executable("python3"),
        ["-c", script, to_string(:code.priv_dir(:coding_agent))],
        stderr_to_stdout: true
      )

    assert status == 0
    assert String.trim(output) == "import-safe"
  end

  test "binary policy startup preserves an immediately queued terminal input frame" do
    root = Path.join(System.tmp_dir!(), "lemon-pty-frames-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    helper = Path.join(to_string(:code.priv_dir(:coding_agent)), "node_pty.py")

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        {:packet, 4},
        {:args, [helper, root, System.find_executable("sh"), "80", "24"]}
      ])

    try do
      assert Port.command(port, Jason.encode!(%{"cwd" => root, "roots" => [root]}))
      input = "printf '\\n__FRAME_INPUT__\\n'; exit 3\n"

      assert Port.command(
               port,
               Jason.encode!(%{"type" => "input", "dataBase64" => Base.encode64(input)})
             )

      {code, ready, output} = receive_protocol(port, false, "", 0)
      assert ready
      assert code == 3
      assert output =~ "\r\n__FRAME_INPUT__\r\n"
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp receive_protocol(port, ready, output, count) when count < 100 do
    receive do
      {^port, {:data, bytes}} ->
        case Jason.decode!(bytes) do
          %{"type" => "ready"} ->
            receive_protocol(port, true, output, count + 1)

          %{"type" => "output", "dataBase64" => data} ->
            assert ready
            assert Port.command(port, Jason.encode!(%{"type" => "ack"}))
            receive_protocol(port, ready, output <> Base.decode64!(data), count + 1)

          %{"type" => "exit", "code" => code} ->
            {code, ready, output}

          other ->
            flunk("Unexpected PTY protocol frame: #{inspect(other)}")
        end

      {^port, {:exit_status, status}} ->
        flunk("PTY helper exited before its terminal exit frame: #{status}")
    after
      5_000 -> flunk("PTY binary startup did not process queued input")
    end
  end

  defp receive_protocol(_port, _ready, _output, _count),
    do: flunk("PTY protocol exceeded test bound")

  defp receive_terminal(pid, acc, count) when count < 100 do
    # The helper reads only one unacknowledged chunk. Keep draining after the
    # marker: interactive shells may emit a separate final `exit` chunk before
    # EOF, and waiting only for exit here would deadlock its backpressure.
    receive do
      {:node_pty, "pty-test", "output", %{"dataBase64" => data}} ->
        PTY.ack(pid)
        receive_terminal(pid, acc <> Base.decode64!(data), count + 1)

      {:node_pty, "pty-test", "exit", %{"code" => code}} ->
        {code, acc}
    after
      5_000 -> flunk("PTY did not report terminal exit")
    end
  end

  defp receive_terminal(_pid, _acc, _count), do: flunk("PTY output exceeded test bound")
end
