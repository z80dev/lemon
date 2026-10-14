defmodule CodingAgent.Tools.BashBackgroundTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Tools.{Bash, BashOutput, KillProcess}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  setup do
    {:ok, session_id: "bash-bg-#{System.unique_integer([:positive])}"}
  end

  describe "timeout parameter" do
    test "kills a command that outlives the model-supplied timeout", %{tmp_dir: tmp_dir} do
      params = %{"command" => "sleep 5; echo done", "timeout" => 200}
      result = Bash.execute("c1", params, nil, nil, tmp_dir, [])

      assert %AgentToolResult{is_error: true, content: [%TextContent{text: text}]} = result
      assert text =~ "timed out after 200 ms"
      refute text =~ "done"
    end

    test "overrides the configured default timeout", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "c1",
          %{"command" => "sleep 0.3; echo finished", "timeout" => 5_000},
          nil,
          nil,
          tmp_dir,
          timeout_ms: 50
        )

      assert %AgentToolResult{is_error: false, content: [%TextContent{text: text}]} = result
      assert text =~ "finished"
    end

    test "rejects a non-positive timeout", %{tmp_dir: tmp_dir} do
      assert {:error, message} =
               Bash.execute("c1", %{"command" => "true", "timeout" => 0}, nil, nil, tmp_dir, [])

      assert message =~ "timeout"
    end
  end

  describe "run_in_background with bash_output and kill_process" do
    test "bash_output returns only new output, then the exit status", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      opts = [session_id: session_id]
      command = "echo one; while [ ! -f go ]; do sleep 0.05; done; echo two"

      process_id = start_background(command, tmp_dir, opts)

      first = await_output(process_id, opts, &(&1 =~ "one"))
      refute first =~ "two"
      assert first =~ "Status: running"

      File.write!(Path.join(tmp_dir, "go"), "")

      second = await_output(process_id, opts, &(&1 =~ "completed"))
      assert second =~ "two"
      refute second =~ "one"
      assert second =~ "Status: completed (exit code 0)"

      assert %AgentToolResult{content: third_content, details: details} =
               BashOutput.execute("c3", %{"process_id" => process_id}, nil, nil, tmp_dir, opts)

      third = Enum.map_join(third_content, "\n", fn %TextContent{text: text} -> text end)

      assert third =~ "(no new output)"
      assert details.status == :completed
      assert details.exit_code == 0
    end

    test "kill_process stops a running process", %{tmp_dir: tmp_dir, session_id: session_id} do
      opts = [session_id: session_id]
      process_id = start_background("sleep 30", tmp_dir, opts)

      assert %AgentToolResult{details: %{status: status, process_id: ^process_id}} =
               KillProcess.execute("k1", %{"process_id" => process_id}, nil, nil, tmp_dir, opts)

      assert status in [:killing, :killed]

      output = await_output(process_id, opts, &(&1 =~ "Status: killed"))
      assert output =~ "killed"

      assert {:error, message} =
               KillProcess.execute("k2", %{"process_id" => process_id}, nil, nil, tmp_dir, opts)

      assert message =~ "not running"
    end

    test "another session can neither read nor kill the process", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      process_id = start_background("sleep 30", tmp_dir, session_id: session_id)
      other = [session_id: session_id <> "-other"]

      assert {:error, read_error} =
               BashOutput.execute("c1", %{"process_id" => process_id}, nil, nil, tmp_dir, other)

      assert read_error =~ "No background process"

      assert {:error, kill_error} =
               KillProcess.execute("k1", %{"process_id" => process_id}, nil, nil, tmp_dir, other)

      assert kill_error =~ "No background process"

      assert %AgentToolResult{} =
               KillProcess.execute(
                 "k2",
                 %{"process_id" => process_id},
                 nil,
                 nil,
                 tmp_dir,
                 session_id: session_id
               )
    end

    test "the process is killed when its owning session exits", %{
      tmp_dir: tmp_dir,
      session_id: session_id
    } do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      opts = [session_id: session_id, session_pid: owner]
      process_id = start_background("sleep 30", tmp_dir, opts)

      Process.exit(owner, :kill)

      output = await_output(process_id, opts, &(&1 =~ "Status: killed"))
      assert output =~ "killed"
    end

    test "pty is rejected for background commands", %{tmp_dir: tmp_dir} do
      assert {:error, message} =
               Bash.execute(
                 "c1",
                 %{"command" => "true", "run_in_background" => true, "pty" => true},
                 nil,
                 nil,
                 tmp_dir,
                 []
               )

      assert message =~ "pty"
    end
  end

  defp start_background(command, tmp_dir, opts) do
    result =
      Bash.execute(
        "bg",
        %{"command" => command, "run_in_background" => true},
        nil,
        nil,
        tmp_dir,
        opts
      )

    assert %AgentToolResult{is_error: false, details: details} = result
    assert %{process_id: process_id, status: :running} = details

    process_id
  end

  # Poll bash_output, accumulating the text of every poll (earlier status
  # lines stripped) until `done?` holds; returns the accumulated text.
  defp await_output(process_id, opts, done?, acc \\ "", attempts \\ 100)

  defp await_output(_process_id, _opts, _done?, acc, 0),
    do: flunk("background output never matched; got: #{inspect(acc)}")

  defp await_output(process_id, opts, done?, acc, attempts) do
    %AgentToolResult{content: content} =
      BashOutput.execute("poll", %{"process_id" => process_id}, nil, nil, ".", opts)

    text = Enum.map_join(content, "\n", fn %TextContent{text: text} -> text end)

    combined = acc <> text

    if done?.(combined) do
      combined
    else
      Process.sleep(50)
      await_output(process_id, opts, done?, strip_status(combined) <> "\n", attempts - 1)
    end
  end

  defp strip_status(text), do: String.replace(text, ~r/\n*Status: .*$/m, "")
end
