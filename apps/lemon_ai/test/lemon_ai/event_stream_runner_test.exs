defmodule LemonAi.EventStreamRunnerTest do
  use ExUnit.Case, async: true

  alias LemonAi.EventStream
  alias LemonAi.Types.AssistantMessage

  describe "runner lifecycle" do
    for reason <- [:normal, :shutdown, {:provider_failed, :disconnect}] do
      test "runner exit #{inspect(reason)} resolves blocked readers and result waiters" do
        owner = worker()
        runner = worker()
        stream = start_stream(owner: owner, runner: runner)

        readers =
          for _ <- 1..2, do: Task.async(fn -> Enum.to_list(EventStream.events(stream)) end)

        waiters = for _ <- 1..2, do: Task.async(fn -> EventStream.result(stream) end)

        await(fn ->
          state = :sys.get_state(stream)
          :queue.len(state.take_waiters) == 2 and :queue.len(state.result_waiters) == 2
        end)

        reason = unquote(Macro.escape(reason))
        send(runner, {:exit, reason})
        terminal = {:error, {:runner_crashed, reason}, nil}
        assert Task.await_many(waiters, 1_000) == [terminal, terminal]
        assert Task.await_many(readers, 1_000) |> List.flatten() == [terminal]
        assert EventStream.result(stream, 1_000) == terminal
        assert Process.alive?(owner)
      end
    end

    test "runner failure preserves earlier output for readers arriving afterward" do
      owner = self()

      runner =
        spawn(fn ->
          receive do
            {:run, stream} ->
              :ok = EventStream.push(stream, :partial_chunk)
              exit(:producer_failed)
          end
        end)

      on_exit(fn -> Process.exit(runner, :kill) end)
      stream = start_stream(runner: runner, owner: owner)
      send(runner, {:run, stream})
      terminal = {:error, {:runner_crashed, :producer_failed}, nil}
      assert EventStream.result(stream, 1_000) == terminal
      assert Process.alive?(stream)
      assert Enum.to_list(EventStream.events(stream)) == [:partial_chunk, terminal]
    end

    test "an already-dead runner emits a retained error on startup" do
      runner = dead_worker()
      stream = start_stream(runner: runner)
      terminal = {:error, {:runner_crashed, :noproc}, nil}
      assert EventStream.result(stream, 1_000) == terminal
      assert Enum.to_list(EventStream.events(stream)) == [terminal]
    end

    test "a live runner can produce normally and its late death cannot replace a terminal" do
      for {finish, result, terminal} <- [
            {fn stream -> EventStream.complete(stream, [:response]) end, {:ok, [:response]},
             {:agent_end, [:response]}},
            {fn stream -> EventStream.error(stream, :already_failed, nil) end,
             {:error, :already_failed, nil}, {:error, :already_failed, nil}}
          ] do
        runner = worker()
        stream = start_stream(runner: runner)
        assert :ok = EventStream.push(stream, :chunk)
        assert :ok = finish.(stream)
        assert EventStream.result(stream, 1_000) == result
        send(runner, {:exit, :late_crash})
        await(fn -> :sys.get_state(stream).runner_ref == nil end)
        assert EventStream.result(stream, 1_000) == result
        assert Enum.to_list(EventStream.events(stream)) == [:chunk, terminal]
      end
    end

    test "runner failure cannot change a retained agent cancellation" do
      runner = worker()
      stream = start_stream(runner: runner, event_format: :agent)
      monitor = Process.monitor(stream)
      assert :ok = EventStream.push(stream, :accepted)
      assert :ok = EventStream.cancel(stream, :user_requested)
      assert EventStream.result(stream, 1_000) == {:error, {:canceled, :user_requested}}
      send(runner, {:exit, :late_crash})
      await(fn -> :sys.get_state(stream).runner_ref == nil end)
      assert EventStream.result(stream, 1_000) == {:error, {:canceled, :user_requested}}
      assert Enum.to_list(EventStream.events(stream)) == [:accepted, {:canceled, :user_requested}]
      assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, 1_000
    end

    test "owner death cancels the stream even while its runner is alive" do
      owner = worker()
      runner = worker()
      stream = start_stream(owner: owner, runner: runner)
      monitor = Process.monitor(stream)
      {:ok, subscription} = EventStream.subscribe_result(stream)
      send(owner, {:exit, :owner_crashed})

      assert_receive {:event_stream_result, ^subscription, {:error, {:canceled, :owner_down}}},
                     1_000

      assert_receive {:DOWN, ^monitor, :process, ^stream, :normal}, 1_000
      assert Process.alive?(runner)
    end
  end

  describe "attached task lifecycle" do
    for {source, crash, text} <- [
          {:running, :worker_failed, "Streaming task crashed: :worker_failed"},
          {:already_dead, :noproc, "Streaming task crashed: :noproc"}
        ] do
      test "#{source} attached worker failure retains a provider error event and result" do
        stream = start_stream()
        worker = if unquote(source) == :running, do: worker(), else: dead_worker()
        assert :ok = EventStream.push(stream, :before_crash)
        assert :ok = EventStream.attach_task(stream, worker)
        _ = EventStream.stats(stream)
        if unquote(source) == :running, do: send(worker, {:exit, unquote(crash)})

        assert {:error,
                %AssistantMessage{stop_reason: :error, error_message: unquote(text)} = error} =
                 EventStream.result(stream, 1_000)

        assert :ok = EventStream.complete(stream, [])
        assert EventStream.result(stream, 1_000) == {:error, error}

        assert Enum.to_list(EventStream.events(stream)) == [
                 :before_crash,
                 {:error, :error, error}
               ]

        assert %{task_pid: nil, task_ref: nil} = :sys.get_state(stream)
      end
    end

    test "an attached worker exiting after completion cannot replace the result" do
      stream = start_stream()
      worker = worker()
      assert :ok = EventStream.attach_task(stream, worker)
      message = %AssistantMessage{stop_reason: :stop}
      assert :ok = EventStream.complete(stream, message)
      assert EventStream.result(stream, 1_000) == {:ok, message}
      send(worker, {:exit, :normal})
      await(fn -> :sys.get_state(stream).task_ref == nil end)
      assert EventStream.result(stream, 1_000) == {:ok, message}
      assert Enum.to_list(EventStream.events(stream)) == [{:done, :stop, message}]
    end
  end

  defp start_stream(opts \\ []) do
    {:ok, stream} =
      EventStream.start_link(Keyword.merge([timeout: :infinity, idle_timeout: :infinity], opts))

    stream
  end

  defp worker do
    pid = spawn(fn -> receive do: ({:exit, reason} -> exit(reason)) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp dead_worker do
    {pid, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
    pid
  end

  defp await(predicate), do: await(predicate, System.monotonic_time(:millisecond) + 1_000)

  defp await(predicate, deadline) do
    unless predicate.() do
      assert System.monotonic_time(:millisecond) < deadline,
             "stream did not reach the expected state"

      Process.sleep(1)
      await(predicate, deadline)
    end
  end
end
