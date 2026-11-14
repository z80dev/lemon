defmodule LemonMCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias LemonMCP.Transport.Stdio

  test "subprocess exit terminates the transport so clients observe disconnect" do
    port = make_ref()
    state = %{port: port, buffer: ""}
    assert {:stop, :normal, %{port: nil}} = Stdio.handle_info({port, {:exit_status, 0}}, state)
  end

  test "rejects an unterminated protocol frame larger than eight MiB" do
    port = make_ref()
    state = %{port: port, buffer: String.duplicate("x", 8 * 1024 * 1024)}
    assert {:stop, :message_too_large, ^state} = Stdio.handle_info({port, {:data, "x"}}, state)
  end

  test "rejects empty command strings" do
    assert {:error, {:invalid_command, "command cannot be empty"}} =
             GenServer.start(Stdio, command: "")
  end

  test "rejects unknown executables without raising" do
    assert {:error, {:invalid_command, message}} =
             GenServer.start(Stdio, command: "definitely-not-a-real-executable")

    assert message =~ "Executable not found"
  end

  test "refused port opens keep failing startup without falling back to Port.open/2" do
    assert {:error, :boom} =
             GenServer.start(Stdio, command: "sh", port_open: fn _spec, _opts -> {:error, :boom} end)

    assert {:error, :invalid_port_open} =
             GenServer.start(Stdio, command: "sh", port_open: fn _spec -> :nope end)
  end

  if match?({:unix, _}, :os.type()) do
    describe "process group cleanup" do
      # A server that never reads stdin (so EOF is ignored), forks a child that
      # shares the Port's stdout pipe and records both pids. With `ignore_term`
      # it also ignores SIGTERM, forcing the SIGKILL escalation.
      @server_script """
      [ "$3" = ignore_term ] && trap '' TERM
      sleep 300 &
      echo $! > "$1"
      echo $$ > "$2"
      while :; do sleep 1; done
      """

      defp start_opts(dir, mode) do
        script = Path.join(dir, "server.sh")
        File.write!(script, @server_script)

        [
          command: "/bin/sh",
          args: [script, Path.join(dir, "child.pid"), Path.join(dir, "server.pid"), mode]
        ]
      end

      defp await_pids(dir) do
        wait_until("server pid files", fn ->
          with {:ok, child} <- read_pid(Path.join(dir, "child.pid")),
               {:ok, server} <- read_pid(Path.join(dir, "server.pid")) do
            [child, server]
          else
            _ -> nil
          end
        end)
      end

      defp read_pid(path) do
        with {:ok, content} <- File.read(path),
             {pid, ""} <- Integer.parse(String.trim(content)) do
          {:ok, pid}
        else
          _ -> :error
        end
      end

      defp wait_until(label, fun, attempts \\ 400) do
        cond do
          value = fun.() ->
            value

          attempts == 0 ->
            flunk("timed out waiting for #{label}")

          true ->
            Process.sleep(25)
            wait_until(label, fun, attempts - 1)
        end
      end

      # `kill -0` succeeds for zombies, which are already dead for our purposes.
      defp os_alive?(pid) do
        pid = Integer.to_string(pid)

        case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
          {_, 0} ->
            {stat, _} = System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true)
            not String.starts_with?(String.trim(stat), "Z")

          _ ->
            false
        end
      end

      defp await_all_gone(pids) do
        wait_until("pids #{inspect(pids)} to exit", fn ->
          not Enum.any?(pids, &os_alive?/1)
        end)
      end

      @tag :tmp_dir
      test "close/1 leaves no process behind even when the server ignores EOF and SIGTERM",
           %{tmp_dir: dir} do
        {:ok, transport} = Stdio.start_link(start_opts(dir, "ignore_term"))
        pids = await_pids(dir)
        assert Enum.all?(pids, &os_alive?/1)

        assert :ok = Stdio.close(transport)
        await_all_gone(pids)
        assert Stdio.connected?(transport) == false
      end

      @tag :tmp_dir
      test "stopping the transport terminates the server's process group", %{tmp_dir: dir} do
        {:ok, transport} = Stdio.start_link(start_opts(dir, "term_ok"))
        pids = await_pids(dir)

        assert :ok = GenServer.stop(transport)
        await_all_gone(pids)
      end

      @tag :tmp_dir
      test "owner death terminates the server's process group", %{tmp_dir: dir} do
        test_pid = self()
        opts = start_opts(dir, "ignore_term")

        owner =
          spawn(fn ->
            {:ok, transport} = Stdio.start_link(opts)
            send(test_pid, {:transport, transport})
            Process.sleep(:infinity)
          end)

        assert_receive {:transport, transport}, 5_000
        pids = await_pids(dir)
        monitor = Process.monitor(transport)

        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^transport, _reason}, 10_000
        await_all_gone(pids)
      end
    end
  end
end
