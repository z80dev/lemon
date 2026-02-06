defmodule CodingAgent.Tools.BashTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Bash
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = Bash.tool("/tmp")

      assert tool.name == "bash"
      assert tool.label == "Run Command"
      assert tool.description =~ "Execute a bash command"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["command"]
      assert "command" in Map.keys(tool.parameters["properties"])
      assert "timeout" in Map.keys(tool.parameters["properties"])
      assert is_function(tool.execute, 4)
    end

    test "accepts optional opts parameter" do
      tool = Bash.tool("/tmp", some_option: true)
      assert tool.name == "bash"
    end
  end

  # ============================================================================
  # Basic Execution Tests
  # ============================================================================

  describe "basic execution" do
    test "executes simple echo command", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo hello"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "hello"
    end

    test "executes pwd command and respects cwd", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "pwd"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ tmp_dir
    end

    test "executes command with arguments", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "echo -n 'no newline'"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "no newline"
    end

    test "returns exit code 0 for successful command", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "true"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.exit_code == 0
    end

    test "returns non-zero exit code for failed command", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "exit 42"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "exited with code 42"
      assert details.exit_code == 42
    end

    test "returns output with non-zero exit code", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo 'error output' && exit 1"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "error output"
      assert text =~ "exited with code 1"
      assert details.exit_code == 1
    end

    test "executes command with multiple outputs", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo line1; echo line2; echo line3"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "line1"
      assert text =~ "line2"
      assert text =~ "line3"
    end

    test "executes piped commands", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute("call_1", %{"command" => "echo 'hello' | tr 'h' 'H'"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Hello"
    end

    test "handles command with special characters", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo 'hello world'"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "hello world"
    end

    test "handles empty output command", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "true"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text == ""
      assert details.exit_code == 0
    end
  end

  # ============================================================================
  # Streaming Behavior Tests
  # ============================================================================

  describe "streaming behavior" do
    test "calls on_update callback with partial results", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      Bash.execute(
        "call_1",
        %{"command" => "echo line1; echo line2"},
        nil,
        on_update,
        tmp_dir,
        []
      )

      # Get collected updates
      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      # Should have received at least one update
      assert length(updates) > 0

      # Each update should be an AgentToolResult
      Enum.each(updates, fn update ->
        assert %AgentToolResult{content: [%TextContent{text: text}]} = update
        assert is_binary(text)
      end)

      # The accumulated output should grow
      if length(updates) > 1 do
        first_text = hd(updates).content |> hd() |> Map.get(:text)
        last_text = List.last(updates).content |> hd() |> Map.get(:text)
        assert byte_size(last_text) >= byte_size(first_text)
      end
    end

    test "incremental output accumulates correctly", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      # Command that produces output over time
      Bash.execute(
        "call_1",
        %{"command" => "for i in 1 2 3; do echo \"line$i\"; sleep 0.01; done"},
        nil,
        on_update,
        tmp_dir,
        []
      )

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      # Should have multiple updates for incremental output
      assert length(updates) >= 1

      # Final update should contain all lines
      final_text = List.last(updates).content |> hd() |> Map.get(:text)
      assert final_text =~ "line1"
      assert final_text =~ "line2"
      assert final_text =~ "line3"
    end

    test "handles stderr output", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      Bash.execute("call_1", %{"command" => "echo error >&2"}, nil, on_update, tmp_dir, [])

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      # stderr should be captured (merged with stdout)
      final_text = List.last(updates).content |> hd() |> Map.get(:text)
      assert final_text =~ "error"
    end

    test "handles mixed stdout and stderr", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      Bash.execute(
        "call_1",
        %{"command" => "echo stdout1; echo stderr1 >&2; echo stdout2"},
        nil,
        on_update,
        tmp_dir,
        []
      )

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      final_text = List.last(updates).content |> hd() |> Map.get(:text)
      assert final_text =~ "stdout1"
      assert final_text =~ "stderr1"
      assert final_text =~ "stdout2"
    end

    test "works correctly without on_update callback", %{tmp_dir: tmp_dir} do
      # Should not raise when on_update is nil
      result = Bash.execute("call_1", %{"command" => "echo test"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "test"
    end
  end

  # ============================================================================
  # Timeout Handling Tests
  # ============================================================================

  describe "timeout handling" do
    test "command that exceeds timeout is killed", %{tmp_dir: tmp_dir} do
      # Set a short timeout of 1 second
      result =
        Bash.execute(
          "call_1",
          %{"command" => "sleep 10", "timeout" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "timed out after 1 second"
      assert details.exit_code == nil
    end

    test "timeout includes partial output", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo 'before sleep'; sleep 10; echo 'after sleep'", "timeout" => 1},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "timed out"
      assert text =~ "before sleep"
      refute text =~ "after sleep"
    end

    test "command that completes before timeout succeeds", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo fast", "timeout" => 10},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "fast"
      refute text =~ "timed out"
      assert details.exit_code == 0
    end

    test "timeout streaming callback receives partial output", %{tmp_dir: tmp_dir} do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      Bash.execute(
        "call_1",
        %{"command" => "echo 'starting'; sleep 10", "timeout" => 1},
        nil,
        on_update,
        tmp_dir,
        []
      )

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      # Should have received at least one update before timeout
      assert length(updates) > 0

      # First update should contain 'starting'
      first_text = hd(updates).content |> hd() |> Map.get(:text)
      assert first_text =~ "starting"
    end
  end

  # ============================================================================
  # Abort Handling Tests
  # ============================================================================

  describe "abort handling" do
    test "abort signal before execution returns cancelled", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result =
        Bash.execute("call_1", %{"command" => "echo should not run"}, signal, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "cancelled"

      AbortSignal.clear(signal)
    end

    test "abort signal during execution stops command", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      task =
        Task.async(fn ->
          Bash.execute(
            "call_1",
            %{"command" => "echo 'started'; sleep 10; echo 'finished'"},
            signal,
            nil,
            tmp_dir,
            []
          )
        end)

      # Give it time to start
      Process.sleep(100)

      # Abort the execution
      AbortSignal.abort(signal)

      # Wait for result
      result = Task.await(task, 5_000)

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "cancelled"
      assert text =~ "started"
      refute text =~ "finished"
      assert details.exit_code == nil

      AbortSignal.clear(signal)
    end

    test "cleanup after abort does not leak resources", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()

      # Run multiple aborted commands to check for resource leaks
      for _ <- 1..5 do
        task =
          Task.async(fn ->
            Bash.execute("call_1", %{"command" => "sleep 5"}, signal, nil, tmp_dir, [])
          end)

        Process.sleep(50)
        AbortSignal.abort(signal)
        Task.await(task, 5_000)

        # Reset signal for next iteration
        AbortSignal.clear(signal)
        signal_new = AbortSignal.new()
        AbortSignal.clear(signal)
        # Use new signal
        AbortSignal.abort(signal_new)
        AbortSignal.clear(signal_new)
      end

      # If we got here without hanging or crashing, resources are being cleaned up
      assert true
    end

    test "abort with streaming callback works correctly", %{tmp_dir: tmp_dir} do
      signal = AbortSignal.new()
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      task =
        Task.async(fn ->
          Bash.execute(
            "call_1",
            %{"command" => "for i in $(seq 1 100); do echo line$i; sleep 0.1; done"},
            signal,
            on_update,
            tmp_dir,
            []
          )
        end)

      # Wait for some output
      Process.sleep(200)

      # Abort
      AbortSignal.abort(signal)

      # Wait for result
      result = Task.await(task, 5_000)

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      # Should have received some streaming updates before abort
      assert length(updates) > 0

      # Result should indicate cancellation
      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "cancelled"

      AbortSignal.clear(signal)
    end
  end

  # ============================================================================
  # Output Truncation Tests
  # ============================================================================

  describe "output truncation" do
    test "very large output is truncated", %{tmp_dir: tmp_dir} do
      # Generate more than 2000 lines
      result =
        Bash.execute(
          "call_1",
          %{"command" => "for i in $(seq 1 3000); do echo line$i; done"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncated == true
      assert text =~ "[Output truncated."
      # Should contain later lines (tail truncation keeps the end)
      assert text =~ "line3000"
    end

    test "truncation includes metadata", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "for i in $(seq 1 5000); do echo line$i; done"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert details.truncated == true
      # The truncation notice should include line count
      assert text =~ ~r/\d+ lines/
    end

    test "small output is not truncated", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo small output"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: details} = result
      assert details.truncated == false
    end

    test "full output path is provided when truncated", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "for i in $(seq 1 5000); do echo line$i; done"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result

      if details.full_output_path do
        assert File.exists?(details.full_output_path)
        assert text =~ details.full_output_path
        # Cleanup
        File.rm(details.full_output_path)
      end
    end
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  describe "error handling" do
    test "command not found returns error in output", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "nonexistent_command_xyz_12345"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      # Should have non-zero exit code
      assert details.exit_code != 0
      # Should contain error message
      assert text =~ "not found" or text =~ "command not found" or details.exit_code == 127
    end

    test "permission denied returns appropriate exit code", %{tmp_dir: tmp_dir} do
      # Create a file without execute permission
      script_path = Path.join(tmp_dir, "no_exec.sh")
      File.write!(script_path, "#!/bin/bash\necho test")
      # No execute permission
      File.chmod!(script_path, 0o644)

      result = Bash.execute("call_1", %{"command" => script_path}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      # Should have non-zero exit code (126 for permission denied, or could vary)
      assert details.exit_code != 0
      assert text =~ "Permission denied" or details.exit_code == 126
    end

    test "invalid command syntax returns error", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "if then fi"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      # Should have non-zero exit code for syntax error
      assert details.exit_code != 0
      assert text =~ "syntax error" or text =~ "unexpected" or details.exit_code == 2
    end

    test "missing command parameter raises", %{tmp_dir: tmp_dir} do
      assert_raise KeyError, fn ->
        Bash.execute("call_1", %{}, nil, nil, tmp_dir, [])
      end
    end
  end

  # ============================================================================
  # Working Directory Tests
  # ============================================================================

  describe "working directory" do
    test "commands run in specified cwd", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "pwd"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.trim(text) == tmp_dir
    end

    test "relative paths work correctly", %{tmp_dir: tmp_dir} do
      # Create a subdirectory
      subdir = Path.join(tmp_dir, "subdir")
      File.mkdir_p!(subdir)
      File.write!(Path.join(subdir, "test.txt"), "hello")

      result =
        Bash.execute("call_1", %{"command" => "cat subdir/test.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "hello"
    end

    test "file operations use correct working directory", %{tmp_dir: tmp_dir} do
      # Create a file in tmp_dir
      File.write!(Path.join(tmp_dir, "existing.txt"), "content")

      result = Bash.execute("call_1", %{"command" => "ls -la"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "existing.txt"
    end

    test "nested directories work", %{tmp_dir: tmp_dir} do
      nested = Path.join([tmp_dir, "a", "b", "c"])
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "deep.txt"), "deep content")

      result = Bash.execute("call_1", %{"command" => "cat a/b/c/deep.txt"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "deep content"
    end
  end

  # ============================================================================
  # Environment Tests
  # ============================================================================

  describe "environment" do
    test "inherits environment variables", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo $HOME"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Should have a value (the home directory)
      assert String.trim(text) != ""
      assert String.trim(text) != "$HOME"
    end

    test "PATH is available", %{tmp_dir: tmp_dir} do
      result = Bash.execute("call_1", %{"command" => "echo $PATH"}, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # PATH should contain standard paths
      assert text =~ "/"
    end

    test "can use standard Unix utilities", %{tmp_dir: tmp_dir} do
      # These should be available in PATH
      commands = ["ls", "cat", "echo", "grep"]

      for cmd <- commands do
        result = Bash.execute("call_1", %{"command" => "which #{cmd}"}, nil, nil, tmp_dir, [])
        assert %AgentToolResult{details: details} = result
        assert details.exit_code == 0, "Expected #{cmd} to be available"
      end
    end

    test "shell environment variables work", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "MY_VAR=test123 && echo $MY_VAR"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "test123"
    end

    test "command substitution works", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo \"Current dir: $(pwd)\""},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Current dir:"
      assert text =~ tmp_dir
    end
  end

  # ============================================================================
  # Tool Integration Tests
  # ============================================================================

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      tool = Bash.tool(tmp_dir)

      result = tool.execute.("call_1", %{"command" => "echo integration"}, nil, nil)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "integration"
    end

    test "tool execute function respects cwd from tool creation" do
      # Create tool with specific cwd
      tool = Bash.tool("/tmp")

      result = tool.execute.("call_1", %{"command" => "pwd"}, nil, nil)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.trim(text) == "/tmp"
    end

    test "tool supports timeout parameter", %{tmp_dir: tmp_dir} do
      tool = Bash.tool(tmp_dir)

      result = tool.execute.("call_1", %{"command" => "sleep 5", "timeout" => 1}, nil, nil)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "timed out"
    end

    test "tool supports streaming callback", %{tmp_dir: tmp_dir} do
      tool = Bash.tool(tmp_dir)
      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_update = fn result ->
        Agent.update(agent, fn updates -> [result | updates] end)
        :ok
      end

      tool.execute.("call_1", %{"command" => "echo streaming"}, nil, on_update)

      updates = Agent.get(agent, fn updates -> Enum.reverse(updates) end)
      Agent.stop(agent)

      assert length(updates) > 0
    end

    test "tool supports abort signal", %{tmp_dir: tmp_dir} do
      tool = Bash.tool(tmp_dir)
      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = tool.execute.("call_1", %{"command" => "echo test"}, signal, nil)

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "cancelled"

      AbortSignal.clear(signal)
    end
  end

  # ============================================================================
  # Edge Case Tests
  # ============================================================================

  describe "edge cases" do
    test "handles unicode output", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "echo '日本語 emoji 🎉'"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Unicode should be preserved
      assert text =~ "日本語"
    end

    test "handles binary output gracefully", %{tmp_dir: tmp_dir} do
      # Generate some binary data
      result =
        Bash.execute(
          "call_1",
          %{"command" => "printf '\\x00\\x01\\x02'"},
          nil,
          nil,
          tmp_dir,
          []
        )

      # Should not crash
      assert %AgentToolResult{} = result
    end

    test "handles very long single line", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "printf '%0.s-' {1..10000}"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert String.contains?(text, "-")
    end

    test "handles rapid succession of commands", %{tmp_dir: tmp_dir} do
      results =
        for i <- 1..10 do
          Bash.execute("call_#{i}", %{"command" => "echo #{i}"}, nil, nil, tmp_dir, [])
        end

      for {result, i} <- Enum.with_index(results, 1) do
        assert %AgentToolResult{content: [%TextContent{text: text}]} = result
        assert text =~ "#{i}"
      end
    end

    test "handles ANSI color codes in output", %{tmp_dir: tmp_dir} do
      # Output with ANSI codes should be sanitized
      result =
        Bash.execute(
          "call_1",
          %{"command" => "printf '\\033[31mred\\033[0m text'"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # ANSI codes should be stripped
      refute text =~ "\033"
      assert text =~ "red"
      assert text =~ "text"
    end

    test "handles carriage returns", %{tmp_dir: tmp_dir} do
      result =
        Bash.execute(
          "call_1",
          %{"command" => "printf 'line1\\r\\nline2'"},
          nil,
          nil,
          tmp_dir,
          []
        )

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      # Carriage returns should be normalized
      assert text =~ "line1"
      assert text =~ "line2"
    end
  end
end
