defmodule LemonCli.PrintCommandTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

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

  test "--no-persona is accepted before validating the required prompt" do
    capture_io([input: "\n"], fn ->
      error =
        capture_io(:stderr, fn ->
          assert LemonCli.CLI.run(["-p", "--no-persona"]) == 2
        end)

      assert error =~ "prompt argument or stdin is required"
      refute error =~ "Invalid run options"
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
