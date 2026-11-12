defmodule LemonCli.PrintCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  defmodule Client do
    def open, do: {:ok, :print_connection}
    def close(:print_connection), do: send(self(), :print_closed)

    def call(:print_connection, "agent", params) do
      send(self(), {:print_submission, params})
      {:ok, %{"run_id" => "print-run"}}
    end

    def call(:print_connection, "chat.abort", params) do
      send(self(), {:print_abort, params})
      {:ok, %{}}
    end

    def next_event(:print_connection, timeout) do
      send(self(), {:print_timeout, timeout})
      {:error, :timeout}
    end
  end

  setup do
    previous_client = Application.get_env(:lemon_cli, :control_plane_client)
    previous_launcher = System.get_env("LEMON_LAUNCHER")
    Application.put_env(:lemon_cli, :control_plane_client, Client)
    System.delete_env("LEMON_LAUNCHER")

    on_exit(fn ->
      if previous_client,
        do: Application.put_env(:lemon_cli, :control_plane_client, previous_client),
        else: Application.delete_env(:lemon_cli, :control_plane_client)

      if previous_launcher, do: System.put_env("LEMON_LAUNCHER", previous_launcher)
    end)
  end

  test "max-time extends the drain deadline and timeout still aborts and reports failure" do
    output =
      capture_io(fn ->
        assert LemonCli.CLI.run(["-p", "hello", "--max-time", "1200", "--output", "json"]) == 1
      end)

    assert_receive {:print_timeout, timeout}
    assert timeout in 1_199_000..1_200_000
    assert_receive {:print_submission, %{"project_memory_capture" => false}}
    assert_receive {:print_abort, %{"runId" => "print-run"}}
    assert_receive :print_closed
    assert %{"ok" => false, "error" => "timeout"} = Jason.decode!(output)
  end

  test "the default drain limit remains ten minutes" do
    capture_io(fn ->
      assert LemonCli.CLI.run(["-p", "hello", "--output", "json"]) == 1
    end)

    assert_receive {:print_timeout, timeout}
    assert timeout in 599_000..600_000
  end

  test "max-time rejects missing, noninteger and nonpositive values before submission" do
    for value <- [[], ["0"], ["-1"], ["1.5"], ["nope"]] do
      error =
        capture_io(:stderr, fn ->
          assert LemonCli.CLI.run(["-p", "hello", "--max-time"] ++ value) == 2
        end)

      assert error =~ "--max-time must be a positive integer in seconds"
      refute_received {:print_submission, _}
    end
  end

  test "run help advertises max-time and its default" do
    output = capture_io(fn -> assert LemonCli.CLI.run(["run", "--help"]) == 0 end)
    assert output =~ "--max-time SECONDS"
    assert output =~ "default 600"
  end

  test "cancelling after socket death returns a bounded error instead of exiting" do
    {pid, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}

    assert {:error, :disconnected} =
             LemonCli.ControlPlaneClient.call({pid, make_ref()}, "chat.abort", %{
               "runId" => "run-dead"
             })
  end

  test "a remote close during cancellation remains a structured connection error" do
    pid =
      spawn(fn ->
        receive do
          {:"$websockex_send", _from, _frame} -> exit({:remote, 1011, ""})
        end
      end)

    assert {:error, :disconnected} =
             LemonCli.ControlPlaneClient.call({pid, make_ref()}, "chat.abort", %{
               "runId" => "run-closing"
             })
  end

  test "piped empty input returns a usage error without starting a run" do
    capture_io([input: "\n"], fn ->
      error =
        capture_io(:stderr, fn ->
          assert LemonCli.CLI.run(["-p", "--output", "stream-json"]) == 2
        end)

      assert error =~ "prompt argument or stdin is required"
    end)
  end

  test "print aliases reject incompatible resume selectors" do
    error =
      capture_io(:stderr, fn ->
        assert LemonCli.CLI.run([
                 "--print",
                 "hello",
                 "--continue",
                 "--session",
                 "agent:default:main"
               ]) == 2
      end)

    assert error =~ "Choose --continue or --session"
  end

  test "invalid output does not silently execute a prompt" do
    error =
      capture_io(:stderr, fn ->
        assert LemonCli.CLI.run(["run", "hello", "--output", "yaml"]) == 2
      end)

    assert error =~ "Invalid run options"
  end
end
