defmodule CodingAgent.BashExecutorTest do
  use ExUnit.Case, async: true

  alias CodingAgent.BashExecutor
  alias CodingAgent.BashExecutor.Result
  alias AgentCore.AbortSignal

  describe "execute/3" do
    test "executes simple command and returns Result struct" do
      {:ok, result} = BashExecutor.execute("echo hello", "/tmp")
      assert %Result{} = result
      assert result.output =~ "hello"
      assert result.exit_code == 0
      assert result.cancelled == false
      assert result.truncated == false
    end

    test "captures non-zero exit code" do
      {:ok, result} = BashExecutor.execute("exit 42", "/tmp")
      assert result.exit_code == 42
      assert result.cancelled == false
    end

    test "captures stderr (merged with stdout)" do
      {:ok, result} = BashExecutor.execute("echo error >&2", "/tmp")
      assert result.output =~ "error"
      assert result.exit_code == 0
    end

    test "respects working directory" do
      {:ok, result} = BashExecutor.execute("pwd", "/tmp")
      assert result.output =~ "/tmp"
    end

    test "handles command with multiple outputs" do
      {:ok, result} = BashExecutor.execute("echo line1; echo line2; echo line3", "/tmp")
      assert result.output =~ "line1"
      assert result.output =~ "line2"
      assert result.output =~ "line3"
    end

    test "handles timeout" do
      {:ok, result} = BashExecutor.execute("sleep 10", "/tmp", timeout: 100)
      # Should timeout and return result with cancelled=true
      assert result.cancelled == true
      assert result.exit_code == nil
    end

    test "handles abort signal" do
      signal = AbortSignal.new()

      # Start a long-running command
      task =
        Task.async(fn ->
          BashExecutor.execute("sleep 10", "/tmp", signal: signal)
        end)

      # Give it a moment to start
      Process.sleep(50)

      # Abort it
      AbortSignal.abort(signal)

      # Wait for result
      {:ok, result} = Task.await(task, 5_000)

      assert result.cancelled == true
      assert result.exit_code == nil

      # Cleanup
      AbortSignal.clear(signal)
    end

    test "calls on_chunk callback for streaming" do
      # Use an Agent to collect chunks since the callback runs synchronously
      {:ok, agent} = Agent.start_link(fn -> [] end)

      callback = fn chunk ->
        Agent.update(agent, fn chunks -> [chunk | chunks] end)
      end

      {:ok, result} = BashExecutor.execute("echo line1; echo line2", "/tmp", on_chunk: callback)

      # Get collected chunks
      chunks = Agent.get(agent, fn chunks -> Enum.reverse(chunks) end)
      Agent.stop(agent)

      # Should have received at least some output chunks
      assert length(chunks) > 0
      combined = Enum.join(chunks, "")
      assert combined =~ "line1"
      assert combined =~ "line2"

      # The final result should also have the output
      assert result.output =~ "line1"
    end

    test "handles empty output command" do
      {:ok, result} = BashExecutor.execute("true", "/tmp")
      assert result.exit_code == 0
      assert result.cancelled == false
    end

    test "handles command with environment variables" do
      {:ok, result} = BashExecutor.execute("echo $HOME", "/tmp")
      assert result.exit_code == 0
      # Should have output (the home directory)
      assert String.trim(result.output) != ""
    end

    test "handles command with special characters" do
      {:ok, result} = BashExecutor.execute("echo 'hello world'", "/tmp")
      assert result.output =~ "hello world"
    end

    test "handles piped commands" do
      {:ok, result} = BashExecutor.execute("echo 'hello' | tr 'h' 'H'", "/tmp")
      assert result.output =~ "Hello"
    end

    test "handles command that produces large output with truncation" do
      # Generate more than default max_lines (2000 lines)
      {:ok, result} =
        BashExecutor.execute(
          "for i in $(seq 1 3000); do echo line$i; done",
          "/tmp",
          max_bytes: 10_000
        )

      assert result.truncated == true
      assert result.output =~ "[Output truncated."
      # Should contain later lines (tail truncation keeps the end)
      assert result.output =~ "line3000"
      # Full output should be saved to temp file
      assert result.full_output_path != nil
      assert File.exists?(result.full_output_path)

      # Cleanup temp file
      File.rm(result.full_output_path)
    end

    test "handles output exceeding OS pipe buffer without deadlock" do
      # Generate output larger than OS pipe buffer (64KB on Linux, 16KB on macOS).
      # This is a regression test for pipe deadlock issues.
      # Using Python if available, otherwise use a shell loop
      command = """
      if command -v python3 >/dev/null 2>&1; then
        python3 -c "print('A' * 131072)"
      elif command -v python >/dev/null 2>&1; then
        python -c "print('A' * 131072)"
      else
        # Fallback: use dd to generate large output
        dd if=/dev/zero bs=1024 count=130 2>/dev/null | tr '\\0' 'A'
      fi
      """

      # Should complete without hanging (deadlock)
      # Set a timeout to detect deadlock
      task = Task.async(fn ->
        BashExecutor.execute(command, "/tmp", max_bytes: 10_000)
      end)

      # Wait for result with timeout - if it deadlocks, this will timeout
      case Task.yield(task, 10_000) do
        {:ok, {:ok, result}} ->
          assert result.exit_code == 0
          assert result.truncated == true
          assert result.output =~ "[Output truncated."
          # Should contain the 'A' characters
          assert result.output =~ "AAAA"

          # Cleanup temp file if created
          if result.full_output_path do
            File.rm(result.full_output_path)
          end

        {:ok, {:error, reason}} ->
          flunk("Command failed: #{inspect(reason)}")

        nil ->
          Task.shutdown(task, :brutal_kill)
          flunk("Command timed out - possible pipe deadlock")
      end
    end

    test "does not truncate small output" do
      {:ok, result} = BashExecutor.execute("echo small", "/tmp")
      assert result.truncated == false
      assert result.full_output_path == nil
    end
  end

  describe "sanitize_output/1" do
    test "strips ANSI escape codes (color)" do
      input = "\e[31mred\e[0m text"
      output = BashExecutor.sanitize_output(input)
      assert output == "red text"
    end

    test "strips ANSI escape codes (bold, etc.)" do
      input = "\e[1mbold\e[0m \e[4munderline\e[0m"
      output = BashExecutor.sanitize_output(input)
      assert output == "bold underline"
    end

    test "strips cursor movement codes" do
      input = "\e[2Jcleared\e[H"
      output = BashExecutor.sanitize_output(input)
      assert output == "cleared"
    end

    test "handles invalid UTF-8 gracefully" do
      # Binary with invalid UTF-8 sequence
      input = <<104, 101, 108, 108, 111, 255, 254>>
      output = BashExecutor.sanitize_output(input)
      assert is_binary(output)
      assert output =~ "hello"
      # Should not raise
    end

    test "removes carriage returns (Windows line endings)" do
      input = "line1\r\nline2\r\n"
      output = BashExecutor.sanitize_output(input)
      assert output == "line1\nline2\n"
    end

    test "removes standalone carriage returns" do
      input = "progress\rprogress2\rdone"
      output = BashExecutor.sanitize_output(input)
      assert output == "progressprogress2done"
    end

    test "preserves tabs and newlines" do
      input = "col1\tcol2\nrow2col1\trow2col2"
      output = BashExecutor.sanitize_output(input)
      assert output == "col1\tcol2\nrow2col1\trow2col2"
    end

    test "handles empty input" do
      assert BashExecutor.sanitize_output("") == ""
    end

    test "handles plain text without changes" do
      input = "hello world 123"
      output = BashExecutor.sanitize_output(input)
      assert output == input
    end
  end

  describe "truncate_tail/2" do
    test "keeps last N lines when line limit exceeded" do
      content = Enum.map(1..100, &"line #{&1}") |> Enum.join("\n")

      {truncated, was_truncated, info} = BashExecutor.truncate_tail(content, max_lines: 10)

      assert was_truncated == true
      assert info.total_lines == 100
      assert info.output_lines == 10
      # Should contain the truncation notice
      assert truncated =~ "[Output truncated."
      # Should contain later lines (tail keeps end)
      assert truncated =~ "line 100"
      assert truncated =~ "line 91"
    end

    test "returns unchanged when within line limits" do
      content = "short output"
      {truncated, was_truncated, info} = BashExecutor.truncate_tail(content)

      assert was_truncated == false
      assert info.total_lines == 1
      assert info.output_lines == 1
      assert truncated == content
    end

    test "returns unchanged when exactly at limits" do
      # Create content with exactly max_lines
      content = Enum.map(1..2000, &"line #{&1}") |> Enum.join("\n")

      {truncated, was_truncated, _info} = BashExecutor.truncate_tail(content, max_lines: 2000)

      # If not exceeding byte limit, should not be truncated
      if byte_size(content) <= 50_000 do
        assert was_truncated == false
        assert truncated == content
      end
    end

    test "truncates by bytes when byte limit exceeded" do
      # Create content that exceeds byte limit but not line limit
      content = String.duplicate("x", 60_000)

      {truncated, was_truncated, info} = BashExecutor.truncate_tail(content, max_bytes: 10_000)

      assert was_truncated == true
      assert info.total_bytes == 60_000
      assert info.output_bytes <= 10_000
      assert truncated =~ "[Output truncated."
    end

    test "handles empty content" do
      {truncated, was_truncated, info} = BashExecutor.truncate_tail("")

      assert was_truncated == false
      assert truncated == ""
      # empty string splits to [""]
      assert info.total_lines == 1
      assert info.total_bytes == 0
    end

    test "provides correct info in truncation metadata" do
      content = Enum.map(1..50, &"line #{&1}") |> Enum.join("\n")

      {_truncated, was_truncated, info} = BashExecutor.truncate_tail(content, max_lines: 20)

      assert was_truncated == true
      assert info.total_lines == 50
      assert info.total_bytes == byte_size(content)
      assert info.output_lines == 20
      assert info.output_bytes > 0
    end
  end

  describe "get_shell_config/0" do
    test "returns shell path and args" do
      {shell, args} = BashExecutor.get_shell_config()
      assert is_binary(shell)
      assert is_list(args)
      # Should have -c for Unix or /C for Windows
      assert "-c" in args or "/C" in args
    end

    test "returns valid shell path" do
      {shell, _args} = BashExecutor.get_shell_config()
      # Shell should be an absolute path or findable
      assert shell != nil
      assert is_binary(shell)
    end
  end

  describe "kill_process_tree/1" do
    test "handles killing non-existent process gracefully" do
      # Use a PID that's very likely not to exist
      result = BashExecutor.kill_process_tree(999_999_999)
      assert result == :ok
    end

    test "can kill actual process" do
      # Start a sleep process
      port =
        Port.open(
          {:spawn_executable, "/bin/sleep"},
          [:binary, :exit_status, {:args, ["10"]}]
        )

      {:os_pid, os_pid} = Port.info(port, :os_pid)

      # Kill it
      assert BashExecutor.kill_process_tree(os_pid) == :ok

      # Process should terminate - wait for exit status
      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        1000 ->
          Port.close(port)
      end
    end
  end

  describe "Result struct" do
    test "has expected fields" do
      result = %Result{
        output: "test output",
        exit_code: 0,
        cancelled: false,
        truncated: false,
        full_output_path: nil
      }

      assert result.output == "test output"
      assert result.exit_code == 0
      assert result.cancelled == false
      assert result.truncated == false
      assert result.full_output_path == nil
    end

    test "default values" do
      result = %Result{}
      assert result.output == nil
      assert result.exit_code == nil
      assert result.cancelled == nil
      assert result.truncated == nil
      assert result.full_output_path == nil
    end
  end
end
