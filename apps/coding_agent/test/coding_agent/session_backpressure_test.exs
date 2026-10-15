defmodule CodingAgent.SessionBackpressureTest do
  use ExUnit.Case, async: true

  import CodingAgent.AsyncHelpers

  alias CodingAgent.Session
  alias LemonAgent.EventStream

  alias LemonAi.Types.{
    AssistantMessage,
    TextContent,
    ToolCall,
    Usage,
    Cost,
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  defp mock_usage(opts \\ []) do
    %Usage{
      input: Keyword.get(opts, :input, 100),
      output: Keyword.get(opts, :output, 50),
      cache_read: Keyword.get(opts, :cache_read, 0),
      cache_write: Keyword.get(opts, :cache_write, 0),
      total_tokens: Keyword.get(opts, :total_tokens, 150),
      cost: Keyword.get(opts, :cost, %Cost{input: 0.001, output: 0.0015, total: 0.0025})
    }
  end

  defp assistant_message(text, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      model: Keyword.get(opts, :model, "mock-model-1"),
      usage: Keyword.get(opts, :usage, mock_usage()),
      stop_reason: Keyword.get(opts, :stop_reason, :stop),
      error_message: Keyword.get(opts, :error_message, nil),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    }
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      # Emit start event
      LemonAi.EventStream.push(stream, {:start, response})

      # Emit text deltas for each text content
      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            LemonAi.EventStream.push(stream, {:text_start, idx, response})
            LemonAi.EventStream.push(stream, {:text_delta, idx, text, response})
            LemonAi.EventStream.push(stream, {:text_end, idx, text, response})

          %ToolCall{} = tool_call ->
            LemonAi.EventStream.push(stream, {:tool_call_start, idx, response})
            LemonAi.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

          _ ->
            :ok
        end
      end)

      # Emit done event
      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, response_to_event_stream(response)}
    end
  end

  defp default_opts(overrides) do
    Keyword.merge(
      [
        cwd: System.tmp_dir!(),
        model: mock_model(),
        stream_fn: mock_stream_fn_single(assistant_message("Hello!"))
      ],
      overrides
    )
  end

  defp start_session(opts) do
    opts = default_opts(opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  defp wait_for_streaming_complete(session) do
    state = Session.get_state(session)

    if state.is_streaming do
      Process.sleep(10)
      wait_for_streaming_complete(session)
    else
      :ok
    end
  end

  defp collect_events_until_end(stream) do
    EventStream.events(stream) |> Enum.to_list()
  end

  # ============================================================================
  # Stream Mode Subscribe Tests
  # ============================================================================

  describe "subscribe with mode: :stream" do
    @tag :tmp_dir
    test "returns EventStream pid", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      {:ok, stream} = Session.subscribe(session, mode: :stream)

      assert is_pid(stream)
      # Verify it's an EventStream by checking stats
      assert %{queue_size: _, max_queue: _, dropped: _} = EventStream.stats(stream)
    end

    @tag :tmp_dir
    test "stream subscriber receives events via EventStream", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)
      {:ok, stream} = Session.subscribe(session, mode: :stream)

      # Trigger some events by prompting
      :ok = Session.prompt(session, "Hello")
      wait_for_streaming_complete(session)

      # Collect events from stream
      events = collect_events_until_end(stream)

      # Should have received session events
      assert events != []

      # Session events should be in session_event format (last event is terminal {:agent_end, []})
      session_events =
        Enum.filter(events, fn
          {:session_event, _session_id, _event} -> true
          _ -> false
        end)

      # We should have at least some session events
      assert session_events != []
    end

    @tag :tmp_dir
    test "stream subscriber receives agent_end event", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)
      {:ok, stream} = Session.subscribe(session, mode: :stream)

      :ok = Session.prompt(session, "Hello")
      wait_for_streaming_complete(session)

      events = collect_events_until_end(stream)

      # Should have an agent_end event
      assert Enum.any?(events, fn
               {:session_event, _, {:agent_end, _}} -> true
               _ -> false
             end)
    end

    @tag :tmp_dir
    test "respects custom max_queue option", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      {:ok, stream} =
        Session.subscribe(session, mode: :stream, max_queue: 50)

      stats = EventStream.stats(stream)
      assert stats.max_queue == 50
    end

    @tag :tmp_dir
    test "overflow signals resynchronization instead of silently dropping events", %{
      tmp_dir: tmp_dir
    } do
      session = start_session(cwd: tmp_dir)

      {:ok, stream} =
        Session.subscribe(session, mode: :stream, max_queue: 5)

      for n <- 1..5, do: assert(:ok == EventStream.push(stream, {:progress, n}))
      assert {:error, :overflow} = EventStream.push(stream, {:progress, 6})
      assert %{queue_size: 6, max_queue: 5, dropped: 1} = EventStream.stats(stream)

      assert List.last(Enum.to_list(EventStream.events(stream))) ==
               {:session_event, Session.get_stats(session).session_id,
                {:stream_resync, %{reason: :overflow}}}
    end
  end

  # ============================================================================
  # Direct Mode Subscribe Tests (Bounded Mailbox Admission)
  # ============================================================================

  describe "subscribe with mode: :direct" do
    @tag :tmp_dir
    test "returns unsubscribe function", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      unsub = Session.subscribe(session, mode: :direct)

      assert is_function(unsub, 0)
    end

    @tag :tmp_dir
    test "direct subscriber receives events via send/2", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)
      _unsub = Session.subscribe(session, mode: :direct)

      :ok = Session.prompt(session, "Hello")

      # Should receive events directly
      assert_receive {:session_event, _session_id, _event}, 5000
    end

    @tag :tmp_dir
    test "default mode is bounded direct delivery", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Call subscribe without options
      unsub = Session.subscribe(session)

      # Should return an unsubscribe function (direct mode behavior)
      assert is_function(unsub, 0)

      :ok = Session.prompt(session, "Hello")
      assert_receive {:session_event, _session_id, _event}, 5000
    end
  end

  # ============================================================================
  # Backpressure Tests
  # ============================================================================

  describe "backpressure behavior" do
    @tag :tmp_dir
    test "slow stream subscriber has bounded queue", %{tmp_dir: tmp_dir} do
      # Create a slow stream function that generates many events
      slow_stream_fn = fn _model, _context, _options ->
        response = assistant_message("A" |> String.duplicate(100))
        {:ok, response_to_event_stream(response)}
      end

      session = start_session(cwd: tmp_dir, stream_fn: slow_stream_fn)

      {:ok, stream} =
        Session.subscribe(session, mode: :stream, max_queue: 10)

      _unsubscribe = Session.subscribe(session)

      # Start prompt but don't consume events immediately
      :ok = Session.prompt(session, "Hello")

      # The direct terminal is the barrier for owner completion, not a sleep.
      assert_receive {:session_event, _session_id, {:agent_end, _}}, 5_000

      stats = EventStream.stats(stream)
      # Queue should be bounded
      assert stats.queue_size <= 11
    end

    @tag :tmp_dir
    test "full queue retains one explicit resync indication", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      {:ok, stream} =
        Session.subscribe(session, mode: :stream, max_queue: 3)

      _unsubscribe = Session.subscribe(session)

      :ok = Session.prompt(session, "Hello")
      assert_receive {:session_event, _session_id, {:agent_end, _}}, 5_000

      stats = EventStream.stats(stream)
      assert stats.queue_size <= 4
      assert stats.dropped > 0
      assert {:error, :overflow} = EventStream.result(stream)

      assert Enum.any?(EventStream.events(stream), fn
               {:session_event, _, {:stream_resync, %{reason: :overflow}}} -> true
               _ -> false
             end)
    end
  end

  # ============================================================================
  # Subscriber Cleanup Tests
  # ============================================================================

  describe "subscriber cleanup" do
    @tag :tmp_dir
    test "stream is canceled when subscriber dies", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)
      parent = self()

      # Spawn a subscriber that will die
      pid =
        spawn(fn ->
          {:ok, stream} = Session.subscribe(session, mode: :stream)
          send(parent, {:stream, stream})

          receive do
            :die -> :ok
          end
        end)

      stream =
        receive do
          {:stream, s} -> s
        after
          1000 -> flunk("Did not receive stream")
        end

      # Verify stream is alive
      assert Process.alive?(stream)

      # Kill the subscriber
      send(pid, :die)

      # Stream should be canceled (not alive)
      assert_process_dead(stream)
    end

    @tag :tmp_dir
    test "session removes dead stream subscribers from state", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)
      parent = self()

      # Spawn a subscriber that will die
      pid =
        spawn(fn ->
          {:ok, _stream} = Session.subscribe(session, mode: :stream)
          send(parent, :subscribed)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :subscribed, 1000

      # Verify session has stream subscriber
      state_before = Session.get_state(session)
      assert map_size(state_before.event_streams) == 1

      # Kill the subscriber
      send(pid, :die)

      # Session should have removed the stream subscriber
      assert_eventually(fn -> map_size(Session.get_state(session).event_streams) == 0 end)
    end
  end

  # ============================================================================
  # Multiple Subscribers Tests
  # ============================================================================

  describe "multiple subscribers" do
    @tag :tmp_dir
    test "direct and stream subscribers can coexist", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      # Subscribe with direct mode
      _unsub_direct = Session.subscribe(session, mode: :direct)

      # Subscribe with stream mode
      {:ok, stream} = Session.subscribe(session, mode: :stream)

      :ok = Session.prompt(session, "Hello")

      # Direct subscriber should receive events
      assert_receive {:session_event, _session_id, _event}, 5000

      # Stream subscriber should also receive events
      wait_for_streaming_complete(session)
      events = collect_events_until_end(stream)
      assert events != []
    end

    @tag :tmp_dir
    test "multiple stream subscribers each get their own EventStream", %{tmp_dir: tmp_dir} do
      session = start_session(cwd: tmp_dir)

      {:ok, stream1} = Session.subscribe(session, mode: :stream)
      {:ok, stream2} = Session.subscribe(session, mode: :stream)

      # Each stream should be a different pid
      assert stream1 != stream2

      :ok = Session.prompt(session, "Hello")
      wait_for_streaming_complete(session)

      # Both streams should receive events
      events1 = collect_events_until_end(stream1)
      events2 = collect_events_until_end(stream2)

      assert events1 != []
      assert events2 != []
    end
  end
end
