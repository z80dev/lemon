defmodule CodingAgent.ProcessOutputOwnerTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ProcessManager, ProcessSession, ProcessStore}

  test "chunks never call the durable store and live reads preserve bounded metadata" do
    id = "owner-tail-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      ProcessSession.start_link(
        process_id: id,
        command: "read value",
        max_log_lines: 2,
        max_retained_bytes: 8,
        max_artifact_bytes: 4
      )

    on_exit(fn -> ProcessSession.stop(id) end)
    {:ok, state} = ProcessSession.get_state(id)
    # Hold the debounce clock explicitly; no timing assumption about chunk delivery.
    timer = Process.send_after(pid, :flush_output, 60_000)
    :sys.replace_state(pid, &%{&1 | output_flush_ref: timer})
    store = Process.whereis(CodingAgent.ProcessStoreServer)
    :erlang.trace(store, true, [:receive])

    try do
      for chunk <- ["aa\n", "bb\n", "cc\n", "dd\n"] do
        send(pid, {state.port, {:data, chunk}})
      end

      {:ok, current} = ProcessSession.get_state(id)
      assert current.total_lines == 4
      ref = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^ref}
      assert drain_calls(store, pid) == 0

      # Reads also work while the owner cannot service calls.
      :sys.suspend(pid)

      try do
        assert {:ok, poll} = ProcessManager.poll(id)
        assert poll.logs == ["dd", "cc"]
        assert poll.output.received_bytes == 12
        assert poll.output.retained_bytes == 6
        assert poll.output.discarded_bytes == 6
        assert poll.output.artifact_bytes == 4
        assert poll.output.artifact_discarded_bytes == 8
        assert poll.output.artifact_truncated
        assert {:ok, read} = ProcessManager.read_output(id)
        assert read.lines == ["cc", "dd"]
        assert read.dropped_lines == 2
        assert read.output == poll.output
        assert {:ok, %{lines: [], dropped_lines: 0}} = ProcessManager.read_output(id)

        assert {:ok, %{lines: ["cc", "dd"], dropped_lines: 2}} =
                 ProcessManager.read_output(id, peek: true)
      after
        :sys.resume(pid)
      end

      send(pid, :flush_output)
      ProcessSession.get_state(id)
      ref = :erlang.trace_delivered(store)
      assert_receive {:trace_delivered, ^store, ^ref}
      assert drain_calls(store, pid) == 1
      assert {:ok, record, ["cc", "dd"]} = ProcessStore.get(id)
      assert record.total_lines == 4
      assert record.read_cursor == 4
      assert record.output.artifact_truncated
      assert is_binary(record.full_output_path)
    after
      :erlang.trace(store, false, [:receive])
      Process.cancel_timer(timer)
    end
  end

  defp drain_calls(store, owner, count \\ 0) do
    receive do
      {:trace, ^store, :receive, {:"$gen_call", {^owner, _tag}, _request}} ->
        drain_calls(store, owner, count + 1)

      {:trace, ^store, :receive, _message} ->
        drain_calls(store, owner, count)
    after
      0 -> count
    end
  end
end
