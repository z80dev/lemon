defmodule CodingAgent.Tools.Task.RunnerTest do
  use ExUnit.Case, async: false

  alias LemonAgent.AbortSignal
  alias LemonAgent.Test.Mocks
  alias CodingAgent.Tools.Task.Runner

  test "times out hung child sessions instead of waiting forever" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "task-runner-timeout-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    stream_fn = fn _model, _context, _options ->
      {:ok, ai_stream} = LemonAi.EventStream.start_link(timeout: :infinity)
      {:ok, ai_stream}
    end

    assert {:error, reason} =
             Runner.start_session_with_prompt(
               [
                 cwd: tmp_dir,
                 model: Mocks.mock_model(),
                 tools: [],
                 stream_fn: stream_fn
               ],
               "Say hello.",
               "Hung session",
               nil,
               nil,
               nil,
               task_session_timeout_ms: 100,
               task_session_poll_ms: 10
             )

    assert reason == "Task session timed out after 100ms waiting for completion"
  end

  test "polls abort signal even when child session timeout is unbounded" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "task-runner-abort-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    signal = AbortSignal.new()

    on_exit(fn ->
      AbortSignal.clear(signal)
      File.rm_rf(tmp_dir)
    end)

    stream_fn = fn _model, _context, _options ->
      {:ok, ai_stream} = LemonAi.EventStream.start_link(timeout: :infinity)
      {:ok, ai_stream}
    end

    task =
      Task.async(fn ->
        Runner.start_session_with_prompt(
          [
            cwd: tmp_dir,
            model: Mocks.mock_model(),
            tools: [],
            stream_fn: stream_fn
          ],
          "Say hello.",
          "Hung session",
          signal,
          nil,
          nil,
          task_session_poll_ms: 10
        )
      end)

    Process.sleep(30)
    AbortSignal.abort(signal)

    assert {:error, "Task aborted"} = Task.await(task, 1_000)
  end

  test "partial assistant text does not turn a provider failure into success" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "task-runner-error-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    response = %LemonAi.Types.AssistantMessage{
      content: [%LemonAi.Types.TextContent{text: "I started but did not finish"}],
      stop_reason: :error,
      error_message: "Invalid request",
      usage: %LemonAi.Types.Usage{}
    }

    assert {:error, _reason} =
             Runner.start_session_with_prompt(
               [
                 cwd: tmp_dir,
                 model: Mocks.mock_model(),
                 tools: [],
                 stream_fn: Mocks.mock_stream_fn_single(response)
               ],
               "Do the work.",
               "Partial failure",
               nil,
               nil,
               nil,
               task_session_timeout_ms: 1_000
             )
  end

  test "a blocked child progress consumer still recovers canonical completion after mailbox overflow" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "task-runner-pressure-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    parent = self()
    response = Mocks.assistant_message("canonical child answer")
    stream_fn = Mocks.blocking_stream_fn(response, parent, chunks: 1)

    on_update = fn result ->
      unless Process.get(:pressure_consumer_blocked) do
        Process.put(:pressure_consumer_blocked, true)
        send(parent, {:consumer_blocked, self(), result.details.session_id})

        receive do
          :release_consumer -> :ok
        end
      end

      :ok
    end

    task =
      Task.async(fn ->
        Runner.start_session_with_prompt(
          [
            cwd: tmp_dir,
            workspace_dir: tmp_dir,
            register: true,
            model: Mocks.mock_model(),
            tools: [],
            stream_fn: stream_fn
          ],
          "Complete the task.",
          "Pressure child",
          nil,
          on_update,
          nil
        )
      end)

    on_exit(fn -> send(task.pid, :release_consumer) end)
    assert_receive {:stream_blocked, producer}, 5_000
    on_exit(fn -> send(producer, :release_stream) end)
    assert_receive {:consumer_blocked, consumer, session_id}, 5_000
    assert consumer == task.pid
    assert {:ok, session} = CodingAgent.lookup_session(session_id)

    progress = %LemonAgent.Types.AgentToolResult{
      content: [%LemonAi.Types.TextContent{text: "small progress"}]
    }

    for _ <- 1..1000, do: send(session, {:task_progress, "noisy-child", progress})
    CodingAgent.Session.get_state(session)
    assert {:message_queue_len, pending} = Process.info(consumer, :message_queue_len)
    assert pending <= 257

    # Owner completion is synchronized independently of the blocked subscriber.
    _unsubscribe = CodingAgent.Session.subscribe(session)
    send(producer, :release_stream)
    assert_receive {:session_event, ^session_id, {:agent_end, _}}, 5_000
    CodingAgent.Session.get_state(session)
    assert {:messages, messages} = Process.info(consumer, :messages)

    assert Enum.any?(
             messages,
             &match?(
               {:lemon_bus_delivery, _, {:session_terminal, ^session_id, :completed}},
               &1
             )
           )

    assert length(messages) <= 258

    assert Enum.reduce(messages, 0, fn message, bytes ->
             bytes + :erlang.external_size(message)
           end) < 256_000

    send(consumer, :release_consumer)

    assert %LemonAgent.Types.AgentToolResult{details: %{status: "completed"}, content: content} =
             Task.await(task, 5_000)

    assert Enum.any?(
             content,
             &match?(%LemonAi.Types.TextContent{text: "canonical child answer"}, &1)
           )
  end

  for final_text <- ["valid", "invalid-final"] do
    @final_text final_text
    test "validator retries replace fenced subscriptions without expanding retries: #{final_text}" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "task-validator-fence-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)
      parent = self()
      responses = ["invalid-first", "invalid-second", @final_text]
      counter = start_supervised!({Agent, fn -> responses end})

      stream_fn = fn model, context, options ->
        text =
          Agent.get_and_update(counter, fn
            [text | rest] -> {text, rest}
            [] -> {"UNEXPECTED EXTRA RETRY", []}
          end)

        send(parent, {:provider_response, text})

        Mocks.blocking_stream_fn(Mocks.assistant_message(text), parent, chunks: 1).(
          model,
          context,
          options
        )
      end

      on_update = fn result ->
        unless Process.get(:validator_consumer_blocked) do
          Process.put(:validator_consumer_blocked, true)
          send(parent, {:validator_consumer_blocked, self(), result.details.session_id})

          receive do
            :release_consumer -> :ok
          end
        end

        :ok
      end

      validator = fn text ->
        Process.delete(:validator_consumer_blocked)
        send(parent, {:validated, text})
        if text == "valid", do: :ok, else: {:error, "expected valid"}
      end

      task =
        Task.async(fn ->
          Runner.start_session_with_prompt(
            [
              cwd: tmp_dir,
              workspace_dir: tmp_dir,
              register: true,
              model: Mocks.mock_model(),
              tools: [],
              stream_fn: stream_fn
            ],
            "Produce valid output.",
            "Validator pressure",
            nil,
            on_update,
            nil,
            validate_output: validator
          )
        end)

      on_exit(fn -> send(task.pid, :release_consumer) end)

      Enum.reduce(responses, nil, fn text, previous_delivery ->
        assert_receive {:provider_response, ^text}, 5_000
        assert_receive {:stream_blocked, producer}, 5_000
        on_exit(fn -> send(producer, :release_stream) end)
        assert_receive {:validator_consumer_blocked, consumer, session_id}, 5_000
        assert consumer == task.pid
        assert {:ok, session} = CodingAgent.lookup_session(session_id)

        {^consumer, _monitor, delivery} =
          Enum.find(CodingAgent.Session.get_state(session).event_listeners, fn {pid, _, _} ->
            pid == consumer
          end)

        if previous_delivery do
          refute delivery == previous_delivery
          assert LemonCore.Bus.Delivery.closed?(previous_delivery)

          # Old tagged and untagged traffic arriving after subscribe cannot end
          # or contaminate the current attempt.
          send(
            consumer,
            {:lemon_bus_delivery, previous_delivery.gate, {:session_terminal, session_id, :error}}
          )

          send(
            consumer,
            {:lemon_bus_delivery, previous_delivery.gate,
             {:session_event, session_id, {:error, "stale generation", nil}}}
          )

          send(consumer, {:session_terminal, session_id, :error})
          send(consumer, {:session_event, session_id, {:error, "untagged old generation", nil}})
        end

        progress = %LemonAgent.Types.AgentToolResult{
          content: [%LemonAi.Types.TextContent{text: "bounded progress"}]
        }

        for _ <- 1..1000, do: send(session, {:task_progress, "noisy-child", progress})
        CodingAgent.Session.get_state(session)
        assert LemonCore.Bus.Delivery.closed?(delivery)

        unsubscribe = CodingAgent.Session.subscribe(session)
        send(producer, :release_stream)
        assert_receive {:session_event, ^session_id, {:agent_end, _}}, 5_000
        CodingAgent.Session.get_state(session)
        unsubscribe.()
        send(consumer, :release_consumer)
        assert_receive {:validated, ^text}, 5_000
        delivery
      end)

      assert %LemonAgent.Types.AgentToolResult{content: content} = Task.await(task, 5_000)
      assert [%LemonAi.Types.TextContent{text: @final_text}] = content
      assert Agent.get(counter, & &1) == []
      refute_received {:provider_response, "UNEXPECTED EXTRA RETRY"}
    end
  end
end
