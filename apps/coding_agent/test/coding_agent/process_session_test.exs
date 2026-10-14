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

  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}

  import CodingAgent.AsyncHelpers

  defp await_status(process_id, statuses) do
    assert_eventually(
      fn ->
        case ProcessSession.poll(process_id) do
          {:ok, %{status: status}} -> status in statuses
          _ -> false
        end
      end,
      timeout: 5_000,
      message: "process #{process_id} never reached #{inspect(statuses)}"
    )
  end

  defp await_finished(process_id), do: await_status(process_id, [:completed, :error, :killed])

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
      assert {:ok, pid} =
               ProcessSession.start_link(
                 command: "echo hello",
                 process_id: process_id
               )

      assert Process.alive?(pid)

      await_finished(process_id)

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
      {:ok, pid} =
        ProcessSession.start_link(
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
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "echo hello_world",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.process_id == process_id
      # Output should contain our echo
      assert Enum.any?(result.logs, fn line -> String.contains?(line, "hello_world") end)
    end

    test "returns status information", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "echo done",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status in [:completed, :running]
      assert is_list(result.logs)
      assert is_integer(result.log_line_count)
      assert result.max_log_lines == 1000
    end
  end

  # ============================================================================
  # kill/2
  # ============================================================================

  describe "kill/2" do
    test "kills a running process", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "sleep 60",
          process_id: process_id
        )

      assert :ok = ProcessSession.kill(process_id)

      await_status(process_id, [:killed])

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :killed
    end

    test "returns error when process is not running", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "echo fast",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:error, :process_not_running} = ProcessSession.kill(process_id)
    end
  end

  # ============================================================================
  # alive?/1
  # ============================================================================

  describe "alive?/1" do
    test "returns true for running session", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "sleep 60",
          process_id: process_id
        )

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
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "echo done",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:error, :process_not_running} = ProcessSession.write_stdin(process_id, "input\n")
    end
  end

  # ============================================================================
  # get_state/1
  # ============================================================================

  describe "get_state/1" do
    test "returns the full state map", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "sleep 60",
          process_id: process_id
        )

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
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "true",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :completed
      assert result.exit_code == 0
    end

    test "process with non-zero exit code is marked error", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "false",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :error
      assert result.exit_code != 0
    end

    test "on_exit callback is invoked", %{process_id: process_id} do
      test_pid = self()

      {:ok, _pid} =
        ProcessSession.start_link(
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
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "echo line1 && echo line2 && echo line3",
          process_id: process_id
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      output = Enum.join(result.logs, "\n")
      assert String.contains?(output, "line1")
      assert String.contains?(output, "line2")
      assert String.contains?(output, "line3")
    end

    test "respects max_log_lines", %{process_id: process_id} do
      # Generate more than max_log_lines output
      cmd = "for i in $(seq 1 100); do echo \"line $i\"; done"

      {:ok, _pid} =
        ProcessSession.start_link(
          command: cmd,
          process_id: process_id,
          max_log_lines: 10,
          restarted_from: "previous-process",
          restart_generation: 1
        )

      await_finished(process_id)

      assert {:ok, state} = ProcessSession.get_state(process_id)
      # log_count should be capped at max_log_lines
      assert state.log_count <= 10
      assert state.restarted_from == "previous-process"
      assert state.restart_generation == 1
      # Buffer may exceed max_log_lines slightly due to per-batch trimming,
      # but should be significantly less than total output (100 lines)
      buf_size = :queue.len(state.log_buffer)
      assert buf_size < 100
    end
  end

  # ============================================================================
  # Output capture limits
  # ============================================================================

  describe "output capture limits" do
    test "byte quotas bound the tail, its store mirror and the artifact for floods, long lines and one oversized chunk",
         %{process_id: process_id} do
      {:ok, pid} =
        ProcessSession.start_link(
          command: "read line",
          process_id: process_id,
          max_retained_bytes: 256,
          max_artifact_bytes: 1_000
        )

      {:ok, %{port: port, full_output_path: path}} = ProcessSession.get_state(process_id)

      on_exit(fn ->
        if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
        ProcessStore.delete(process_id)
      end)

      # Port data is injected directly so chunk boundaries are exact.
      inject = fn chunk -> send(pid, {port, {:data, chunk}}) end

      inject.(String.duplicate("\n", 5_000))
      assert_capture_bounds(process_id, path, 5_000)

      for _ <- 1..50, do: inject.(String.duplicate("a", 100))
      assert_capture_bounds(process_id, path, 10_000)

      inject.(String.duplicate("b", 4_999) <> "\n")
      {output, store_logs} = assert_capture_bounds(process_id, path, 15_000)

      # The newest line remains as a bounded diagnostic tail; the artifact holds the head.
      assert List.last(store_logs) =~ ~r/\Ab+\z/
      assert File.read!(path) == String.duplicate("\n", 1_000)

      assert %{artifact_bytes: 1_000, artifact_discarded_bytes: 14_000, artifact_truncated: true} =
               output

      # Cancelling after the capture limit reports a kill, never completion.
      assert :ok = ProcessSession.kill(process_id)
      await_status(process_id, [:killed])
      assert {:ok, %{status: :killed}, _logs} = ProcessStore.get(process_id)

      ProcessSession.stop(process_id)
      ProcessStore.delete(process_id)
      refute File.exists?(path)
    end

    test "a write failure keeps the tail and the real exit status, and cleanup removes the file",
         %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "read line; echo got-$line; read again",
          process_id: process_id
        )

      {:ok, %{output_file: file, full_output_path: path}} = ProcessSession.get_state(process_id)

      on_exit(fn ->
        if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
        ProcessStore.delete(process_id)
      end)

      # Closing the device makes the next write fail, as a lost file descriptor would.
      :ok = File.close(file)
      :ok = ProcessSession.write_stdin(process_id, "go\n")

      assert_eventually(fn ->
        {:ok, state} = ProcessSession.get_state(process_id)
        state.received_bytes == 7
      end)

      {:ok, %{port: port, output_file: nil}} = ProcessSession.get_state(process_id)
      [{pid, _}] = Registry.lookup(CodingAgent.ProcessRegistry, process_id)
      send(pid, {port, {:data, "diagnostic\n"}})
      assert {:ok, %{output: stats}} = ProcessSession.poll(process_id)
      assert stats.received_bytes == 18
      assert stats.artifact_bytes == 0
      assert stats.artifact_discarded_bytes == 18
      assert stats.artifact_size_unknown == false
      assert File.stat!(path).size == 0
      :ok = ProcessSession.write_stdin(process_id, "done\n")

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.read_output(process_id)
      assert %{status: :completed, exit_code: 0, lines: ["got-go", "diagnostic"]} = result
      assert %{artifact_error: :terminated, artifact_truncated: true} = result.output

      assert {:ok, %{output: %{artifact_error: :terminated}}, ["got-go", "diagnostic"]} =
               ProcessStore.get(process_id)

      ProcessSession.stop(process_id)
      ProcessStore.delete(process_id)
      refute File.exists?(path)
    end

    test "uncheckable failed capture keeps its reservation and unknown discarded count",
         %{process_id: process_id} do
      {pid, port, path} = start_capture(process_id, max_artifact_bytes: 50)
      {:ok, %{output_file: file}} = ProcessSession.get_state(process_id)
      :ok = File.close(file)
      File.rm!(path)
      File.ln_s!(path, path)

      send(pid, {port, {:data, "diagnostic\n"}})
      assert {:ok, %{output: stats}} = ProcessSession.poll(process_id)
      assert stats.received_bytes == 11
      assert stats.artifact_bytes == 0
      assert stats.artifact_size_unknown
      assert stats.artifact_discarded_bytes == nil
      assert stats.artifact_truncated
      assert stats.artifact_error == :terminated

      send(pid, {port, {:data, "tail\n"}})

      assert {:ok, %{output: %{received_bytes: 16, artifact_discarded_bytes: nil}}} =
               ProcessSession.poll(process_id)

      :ok = ProcessSession.write_stdin(process_id, "\n")
      await_finished(process_id)

      assert {:ok, result} = ProcessSession.read_output(process_id)
      assert result.status == :completed
      assert result.exit_code == 0
      assert result.lines == ["diagnostic", "tail"]
      assert result.output.finalized
      assert result.output.artifact_capacity == 50
      assert result.output.artifact_discarded_bytes == nil

      assert {:ok, %{output: %{artifact_capacity: 50, artifact_size_unknown: true}}, _} =
               ProcessStore.get(process_id)
    end

    test "partial-only updates evict the store mirror and preserve exact byte accounting",
         %{process_id: process_id} do
      {pid, port, path} = start_capture(process_id, max_retained_bytes: 8, max_artifact_bytes: 5)
      send(pid, {port, {:data, "one\nxy"}})

      assert {:ok, %{output: %{received_bytes: 6, retained_bytes: 6, discarded_bytes: 0}}} =
               ProcessSession.poll(process_id)

      assert {:ok, %{output: %{retained_bytes: 6}}, ["one"]} = ProcessStore.get(process_id)

      send(pid, {port, {:data, "123456"}})
      assert {:ok, %{partial_line: "6", log_bytes: 7}} = ProcessSession.get_state(process_id)
      assert {:ok, %{output: %{retained_bytes: 8}}, ["xy12345"]} = ProcessStore.get(process_id)

      # Partial growth alone must also evict the mirrored segment.
      send(pid, {port, {:data, "7890"}})
      assert {:ok, %{partial_line: "67890", log_bytes: 0}} = ProcessSession.get_state(process_id)

      assert {:ok, %{output: %{received_bytes: 16, retained_bytes: 5, discarded_bytes: 11}}, []} =
               ProcessStore.get(process_id)

      send(pid, {port, {:data, "\n"}})

      assert {:ok, %{lines: ["67890"], dropped_lines: 2, output: stats}} =
               ProcessSession.read_output(process_id)

      assert stats.retained_bytes == 6
      assert stats.discarded_bytes == 11
      assert stats.artifact_bytes == 5
      assert stats.artifact_discarded_bytes == 12
      assert File.read!(path) == "one\nx"

      ProcessSession.stop(process_id)

      assert {:ok, %{lines: [], output: %{finalized: true}}} =
               ProcessManager.read_output(process_id)
    end

    test "a one-byte budget handles empty lines and split newline boundaries",
         %{process_id: process_id} do
      {pid, port, path} = start_capture(process_id, max_retained_bytes: 1, max_artifact_bytes: 1)
      send(pid, {port, {:data, "a"}})

      assert {:ok, %{output: %{retained_bytes: 1, discarded_bytes: 0}}} =
               ProcessSession.poll(process_id)

      send(pid, {port, {:data, "\nb\n"}})

      assert {:ok, %{lines: [""], dropped_lines: 3, output: stats}} =
               ProcessSession.read_output(process_id)

      assert stats.received_bytes == 4
      assert stats.retained_bytes == 1
      assert stats.discarded_bytes == 3
      assert stats.artifact_discarded_bytes == 3
      assert File.read!(path) == "a"
    end

    test "normal output and exit partials remain compatible at the exact artifact boundary",
         %{process_id: process_id} do
      {pid, port, path} =
        start_capture(process_id, max_retained_bytes: 32, max_artifact_bytes: 10)

      send(pid, {port, {:data, "ok\npar"}})
      send(pid, {port, {:data, "tial"}})

      assert {:ok, %{lines: ["ok"], output: %{artifact_truncated: false}}} =
               ProcessSession.read_output(process_id)

      :ok = ProcessSession.write_stdin(process_id, "\n")
      await_finished(process_id)

      assert {:ok, %{status: :completed, exit_code: 0, lines: ["partial"], output: stats}} =
               ProcessSession.read_output(process_id)

      assert stats.received_bytes == 10
      assert stats.retained_bytes == 10
      assert stats.discarded_bytes == 0
      assert stats.artifact_bytes == 10
      assert stats.artifact_discarded_bytes == 0
      refute stats.artifact_truncated
      assert File.read!(path) == "ok\npartial"
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "pre-port startup failure removes its file and releases its artifact reservation" do
      pattern = Path.join(System.tmp_dir!(), "lemon-process-*.log")
      before = MapSet.new(Path.wildcard(pattern))
      marker = Path.join(System.tmp_dir!(), "quota-start-#{System.unique_integer([:positive])}")
      secret = "startup-quota-secret"

      # Invalid launch env fails while preparing Port.open, after opening the
      # artifact, but before any external command can run.
      assert {:error, reason} =
               ProcessManager.exec(
                 command: "touch #{marker}",
                 use_lane_queue: false,
                 env: %{"BROKEN" => {:invalid, secret}},
                 max_artifact_bytes: 5
               )

      refute inspect(reason) =~ secret
      refute File.exists?(marker)
      assert MapSet.new(Path.wildcard(pattern)) == before
    end

    test "an invalid configured limit refuses to launch the command" do
      previous = Application.fetch_env(:coding_agent, :process_output)
      Application.put_env(:coding_agent, :process_output, max_artifact_bytes: 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:coding_agent, :process_output, value)
          :error -> Application.delete_env(:coding_agent, :process_output)
        end
      end)

      marker =
        Path.join(System.tmp_dir!(), "lemon-limit-probe-#{System.unique_integer([:positive])}")

      assert {:error, {:invalid_process_output_limit, :max_artifact_bytes}} =
               ProcessManager.exec(command: "touch #{marker}", use_lane_queue: false)

      refute File.exists?(marker)
      Application.put_env(:coding_agent, :process_output, [])

      for key <- [
            :max_retained_bytes,
            :max_artifact_bytes,
            :max_owner_artifact_bytes,
            :max_runtime_artifact_bytes
          ],
          invalid <- [nil, 0, -1, 1.5, :infinity] do
        assert {:error, {:invalid_process_output_limit, ^key}} =
                 ProcessManager.exec(
                   [command: "touch #{marker}", use_lane_queue: false] ++ [{key, invalid}]
                 )

        refute File.exists?(marker)
      end

      # Explicit limits override application defaults.
      Application.put_env(:coding_agent, :process_output, max_artifact_bytes: 0)

      {:ok, id} =
        ProcessManager.exec(command: "true", use_lane_queue: false, max_artifact_bytes: 1)

      on_exit(fn -> ProcessManager.clear(id) end)
    end
  end

  defp start_capture(process_id, opts) do
    {:ok, pid} = ProcessSession.start_link([command: "read line", process_id: process_id] ++ opts)
    {:ok, %{port: port, full_output_path: path}} = ProcessSession.get_state(process_id)

    on_exit(fn ->
      if ProcessSession.alive?(process_id), do: ProcessSession.stop(process_id)
      ProcessStore.delete(process_id)
    end)

    {pid, port, path}
  end

  # Port messages and calls are handled in order, so these reads observe every
  # chunk injected before them.
  defp assert_capture_bounds(process_id, path, received) do
    assert {:ok, %{logs: logs, output: output}} = ProcessSession.poll(process_id, 10_000)

    {:ok, %{partial_line: partial, max_line_bytes: 255, log_bytes: log_bytes}} =
      ProcessSession.get_state(process_id)

    held = [partial | logs]

    assert output.retained_bytes <= 256
    assert Enum.sum(Enum.map(held, &byte_size/1)) <= 256
    assert log_bytes + byte_size(partial) == output.retained_bytes
    # Retained lines are copies, not views pinning a whole received chunk.
    assert Enum.all?(held, &(:binary.referenced_byte_size(&1) == byte_size(&1)))
    assert output.received_bytes == received
    assert output.received_bytes == output.retained_bytes + output.discarded_bytes

    # The store holds exactly the session's retained lines, not a second budget.
    assert {:ok, record, store_logs} = ProcessStore.get(process_id)
    assert store_logs == Enum.reverse(logs)
    assert record.output == output

    assert Enum.sum(Enum.map(store_logs, &byte_size/1)) +
             Enum.sum(Enum.map(held, &byte_size/1)) <= 512

    assert File.stat!(path).size <= 1_000
    {output, store_logs}
  end

  # ============================================================================
  # Timeout
  # ============================================================================

  describe "timeout" do
    test "kills process after timeout_ms", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "sleep 60",
          process_id: process_id,
          timeout_ms: 200
        )

      # Wait for timeout to trigger
      await_status(process_id, [:error])

      assert {:ok, result} = ProcessSession.poll(process_id)
      assert result.status == :error
    end
  end

  # ============================================================================
  # Working directory
  # ============================================================================

  describe "working directory" do
    test "respects cwd option", %{process_id: process_id} do
      {:ok, _pid} =
        ProcessSession.start_link(
          command: "pwd",
          process_id: process_id,
          cwd: "/tmp"
        )

      await_finished(process_id)

      assert {:ok, result} = ProcessSession.poll(process_id)
      # On macOS, /tmp is a symlink to /private/tmp
      output = Enum.join(result.logs, "\n")
      assert String.contains?(output, "tmp")
    end
  end
end
