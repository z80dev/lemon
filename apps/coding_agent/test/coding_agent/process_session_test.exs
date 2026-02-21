defmodule CodingAgent.ProcessSessionTest do
  @moduledoc """
  Tests for CodingAgent.ProcessSession GenServer.

  Tests basic lifecycle of background process management via Port:
  - Starting a process
  - Polling for output
  - Killing a process
  - Process exit handling
  """
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessSession

  # ============================================================================
  # Setup
  # ============================================================================

  setup do
    process_id = "test-proc-#{:erlang.unique_integer([:positive])}"
    {:ok, process_id: process_id}
  end

  # ============================================================================
  # start_link/1 and basic lifecycle
  # ============================================================================

  describe "start_link/1" do
    test "starts a process session with echo command", %{process_id: process_id} do
      assert {:ok, pid} = ProcessSession.start_link(
        command: "echo hello",
        process_id: process_id
      )
      assert Process.alive?(pid)

      # Wait for command to complete
      Process.sleep(200)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.process_id == process_id
      assert result.command == "echo hello"
    end

    test "generates process_id when not provided" do
      assert {:ok, pid} = ProcessSession.start_link(command: "echo test")
      assert Process.alive?(pid)

      # Clean up
      Process.sleep(200)
    end
  end

  # ============================================================================
  # get_process_id/1
  # ============================================================================

  describe "get_process_id/1" do
    test "returns process_id for a string" do
      assert ProcessSession.get_process_id("my-id") == "my-id"
    end

    test "returns process_id for a running session pid", %{process_id: process_id} do
      {:ok, pid} = ProcessSession.start_link(
        command: "sleep 5",
        process_id: process_id
      )

      assert ProcessSession.get_process_id(pid) == process_id

      # Clean up
      ProcessSession.kill(process_id)
      Process.sleep(100)
    end
  end

  # ============================================================================
  # poll/2
  # ============================================================================

  describe "poll/2" do
    test "returns output from completed process", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "echo hello_world",
        process_id: process_id
      )

      # Wait for process to complete
      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.process_id == process_id
      # Output should contain our echo
      assert Enum.any?(result.logs, fn line -> String.contains?(line, "hello_world") end)
    end

    test "returns status information", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "echo done",
        process_id: process_id
      )

      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status in [:completed, :running]
      assert is_list(result.logs)
    end
  end

  # ============================================================================
  # kill/2
  # ============================================================================

  describe "kill/2" do
    test "kills a running process", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "sleep 60",
        process_id: process_id
      )

      # Give it time to start
      Process.sleep(100)

      assert :ok = ProcessSession.kill(process_id)

      Process.sleep(200)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :killed
    end

    test "returns error when process is not running", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "echo fast",
        process_id: process_id
      )

      # Wait for it to finish
      Process.sleep(300)

      assert {:error, :process_not_running} = ProcessSession.kill(process_id)
    end
  end

  # ============================================================================
  # alive?/1
  # ============================================================================

  describe "alive?/1" do
    test "returns true for running session", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "sleep 60",
        process_id: process_id
      )

      Process.sleep(50)
      assert ProcessSession.alive?(process_id) == true

      # Clean up
      ProcessSession.kill(process_id)
      Process.sleep(100)
    end

    test "returns false for non-existent session" do
      refute ProcessSession.alive?("nonexistent-process-id")
    end
  end

  # ============================================================================
  # write_stdin/2
  # ============================================================================

  describe "write_stdin/2" do
    test "returns error when process is not running", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "echo done",
        process_id: process_id
      )

      # Wait for process to finish
      Process.sleep(300)

      assert {:error, :process_not_running} = ProcessSession.write_stdin(process_id, "input\n")
    end
  end

  # ============================================================================
  # get_state/1
  # ============================================================================

  describe "get_state/1" do
    test "returns the full state map", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "sleep 60",
        process_id: process_id
      )

      Process.sleep(50)

      assert {:ok, state} = ProcessSession.get_state(process_id)
      assert state.process_id == process_id
      assert state.status == :running
      assert state.command == "sleep 60"
      assert is_integer(state.started_at)

      # Clean up
      ProcessSession.kill(process_id)
      Process.sleep(100)
    end
  end

  # ============================================================================
  # Process exit handling
  # ============================================================================

  describe "process exit" do
    test "process with exit code 0 is marked completed", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "true",
        process_id: process_id
      )

      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :completed
      assert result.exit_code == 0
    end

    test "process with non-zero exit code is marked error", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "false",
        process_id: process_id
      )

      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :error
      assert result.exit_code != 0
    end

    test "on_exit callback is invoked", %{process_id: process_id} do
      test_pid = self()

      {:ok, _pid} = ProcessSession.start_link(
        command: "echo callback_test",
        process_id: process_id,
        on_exit: fn exit_info ->
          send(test_pid, {:exit_callback, exit_info})
        end
      )

      assert_receive {:exit_callback, exit_info}, 2000
      assert exit_info.process_id == process_id
      assert exit_info.status == :completed
    end
  end

  # ============================================================================
  # Log buffer
  # ============================================================================

  describe "log buffer" do
    test "captures multi-line output", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "echo line1 && echo line2 && echo line3",
        process_id: process_id
      )

      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      output = Enum.join(result.logs, "\n")
      assert String.contains?(output, "line1")
      assert String.contains?(output, "line2")
      assert String.contains?(output, "line3")
    end

    test "respects max_log_lines", %{process_id: process_id} do
      # Generate more than max_log_lines output
      cmd = "for i in $(seq 1 100); do echo \"line $i\"; done"

      {:ok, _pid} = ProcessSession.start_link(
        command: cmd,
        process_id: process_id,
        max_log_lines: 10
      )

      Process.sleep(500)

      assert {:ok, state} = ProcessSession.get_state(process_id)
      # log_count should be capped at max_log_lines
      assert state.log_count <= 10
      # Buffer may exceed max_log_lines slightly due to per-batch trimming,
      # but should be significantly less than total output (100 lines)
      buf_size = :queue.len(state.log_buffer)
      assert buf_size < 100
    end
  end

  # ============================================================================
  # Timeout
  # ============================================================================

  describe "timeout" do
    test "kills process after timeout_ms", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "sleep 60",
        process_id: process_id,
        timeout_ms: 200
      )

      # Wait for timeout to trigger
      Process.sleep(500)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :error
    end
  end

  # ============================================================================
  # Working directory
  # ============================================================================

  describe "working directory" do
    test "respects cwd option", %{process_id: process_id} do
      {:ok, _pid} = ProcessSession.start_link(
        command: "pwd",
        process_id: process_id,
        cwd: "/tmp"
      )

      Process.sleep(300)

      assert {:ok, result} = ProcessSession.poll(process_id)
      # On macOS, /tmp is a symlink to /private/tmp
      output = Enum.join(result.logs, "\n")
      assert String.contains?(output, "tmp")
    end
  end
end
