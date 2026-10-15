defmodule CodingAgent.Tools.OutputRecoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{Bash, BashOutput, Patch}
  alias CodingAgent.{ProcessManager, ProcessStore}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  test "killing a foreground tool worker cannot orphan its shell descendants", %{tmp_dir: cwd} do
    parent = self()

    worker =
      spawn(fn ->
        Bash.execute(
          "owner",
          %{"command" => "echo ready; sleep 1; echo escaped > escaped.txt"},
          nil,
          fn _update -> send(parent, :shell_ready) end,
          cwd,
          []
        )
      end)

    monitor = Process.monitor(worker)
    assert_receive :shell_ready, 2_000
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000
    Process.sleep(1_200)
    refute File.exists?(Path.join(cwd, "escaped.txt"))
  end

  test "shell UTF-8 survives split chunks and invalid bytes do not drop later text", %{
    tmp_dir: cwd
  } do
    result =
      Bash.execute(
        "encoding",
        %{"command" => "printf '\\360\\237'; sleep 0.1; printf '\\214\\215'; printf '\\377tail'"},
        nil,
        nil,
        cwd,
        []
      )

    assert %AgentToolResult{content: [%TextContent{text: "🌍�tail"}]} = result
  end

  test "timed-out huge commands expose their complete output", %{tmp_dir: cwd} do
    result =
      Bash.execute(
        "timeout",
        %{"command" => "yes payload | head -n 20000; sleep 5", "timeout" => 500},
        nil,
        nil,
        cwd,
        []
      )

    assert %AgentToolResult{is_error: false, details: details} = result
    assert details.timed_out
    assert details.background
    {:ok, output} = ProcessManager.read_output(details.process_id)
    assert File.read!(output.full_output_path) |> String.starts_with?("payload\n")
    ProcessManager.kill(details.process_id)
  end

  test "background output remains recoverable after scrolling out of its buffer", %{tmp_dir: cwd} do
    owner = "output-recovery-#{System.unique_integer([:positive])}"

    {:ok, id} =
      ProcessManager.exec(
        command: "printf 'first\\n'; yes payload | head -n 2000",
        cwd: cwd,
        owner: owner,
        owner_pid: self(),
        max_log_lines: 5
      )

    on_exit(fn ->
      ProcessManager.kill(id)
      ProcessStore.delete(id)
    end)

    await_exit(id, 500)
    result = BashOutput.execute("output", %{"process_id" => id}, nil, nil, cwd, session_id: owner)
    assert %AgentToolResult{content: content, details: details} = result
    assert details.dropped_lines > 0
    assert Enum.any?(content, &String.contains?(&1.text, details.artifact_uri))

    assert %AgentToolResult{content: [%TextContent{text: recovered}], trust: :untrusted} =
             CodingAgent.Tools.Read.execute(
               "recover",
               %{"path" => details.artifact_uri, "offset" => 1, "limit" => 1},
               nil,
               nil,
               cwd,
               session_id: owner
             )

    assert recovered =~ "first"
    ProcessStore.delete(id)
    refute File.exists?(details.full_output_path)
  end

  test "malformed and empty update patches fail rather than claim success", %{tmp_dir: cwd} do
    File.write!(Path.join(cwd, "a.txt"), "before")

    for body <- ["", "-before\n+after", "@@\n before", "@@\nbefore\nafter"] do
      patch = "*** Begin Patch\n*** Update File: a.txt\n#{body}\n*** End Patch"
      assert {:error, _} = Patch.execute("patch", %{"patch_text" => patch}, nil, nil, cwd, [])
      assert File.read!(Path.join(cwd, "a.txt")) == "before"
    end
  end

  test "bash refuses malformed arguments without raising", %{tmp_dir: cwd} do
    for params <- [
          %{},
          %{"command" => 7},
          %{"command" => "true", "pty" => "true"},
          %{"command" => "true", "run_in_background" => "false"}
        ] do
      assert {:error, _} = Bash.execute("invalid", params, nil, nil, cwd, [])
    end

    assert %AgentToolResult{is_error: true} =
             Bash.execute("failure", %{"command" => "exit 3"}, nil, nil, cwd, [])
  end

  defp await_exit(_id, 0), do: flunk("background command did not exit")

  defp await_exit(id, attempts) do
    case ProcessManager.poll(id) do
      {:ok, %{status: :running}} ->
        Process.sleep(20)
        await_exit(id, attempts - 1)

      {:ok, %{status: status}} when status in [:completed, :error] ->
        :ok

      other ->
        flunk("unexpected process status: #{inspect(other)}")
    end
  end
end
