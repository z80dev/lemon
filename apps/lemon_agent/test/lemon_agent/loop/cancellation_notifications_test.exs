defmodule LemonAgent.Loop.CancellationNotificationsTest do
  use ExUnit.Case, async: true

  alias LemonAgent.{AbortSignal, EventStream}
  alias LemonAgent.Loop.{Streaming, ToolCalls}
  alias LemonAgent.Test.Mocks
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentToolResult}
  alias LemonAi.Types.{StreamOptions, TextContent}

  @registry LemonAgent.AbortSignal.Registry

  for {kind, stop_reason} <- [abort: :aborted, redirect: :redirected] do
    test "#{kind} wakes an idle provider receive without a polling tick" do
      parent = self()
      signal = AbortSignal.new()
      {:ok, stream} = EventStream.start_link(timeout: :infinity, idle_timeout: :infinity)

      stream_fn = fn _, _, _ ->
        {:ok, provider} = LemonAi.EventStream.start_link(timeout: :infinity)
        send(parent, {:provider, provider})
        {:ok, provider}
      end

      config = config(stream_fn: stream_fn)

      runner =
        start_waiter(fn ->
          Streaming.stream_assistant_response(context(), config, signal, nil, stream)
        end)

      assert_receive {:provider, provider}, 1_000
      monitor = Process.monitor(provider)
      assert_waiting(runner, Streaming, :await_ai_event, 3)
      assert_subscribed(runner.pid, signal)
      notify(signal, unquote(kind))
      assert_notification_without_tick(runner.pid, signal, unquote(kind))

      pid = runner.pid
      stop_reason = unquote(stop_reason)

      assert_receive {:waiter_result, ^pid, {:ok, %{stop_reason: ^stop_reason}, _}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^provider, _}, 1_000
      finish_waiter(runner, signal)
      EventStream.complete(stream, [])
    end

    test "#{kind} interrupts the retry deadline without another provider request" do
      parent = self()
      signal = AbortSignal.new()
      {:ok, stream} = EventStream.start_link(timeout: :infinity, idle_timeout: :infinity)

      stream_fn = fn _, _, _ ->
        send(parent, :provider_request)
        {:error, :timeout}
      end

      config =
        config(
          stream_fn: stream_fn,
          retry_base_delay_ms: 60_000,
          retry_max_delay_ms: 60_000
        )

      runner =
        start_waiter(fn ->
          Streaming.stream_assistant_response(context(), config, signal, nil, stream)
        end)

      assert_receive :provider_request, 1_000
      assert_waiting(runner, Streaming, :wait_for_retry, 2)
      assert_subscribed(runner.pid, signal)
      notify(signal, unquote(kind))
      assert_notification_without_tick(runner.pid, signal, unquote(kind))

      pid = runner.pid
      stop_reason = unquote(stop_reason)

      assert_receive {:waiter_result, ^pid, {:ok, %{stop_reason: ^stop_reason}, _}}, 1_000
      refute_received :provider_request
      finish_waiter(runner, signal)
      EventStream.complete(stream, [])

      assert {:provider_retry_end, %{attempt: 1, success: false, canceled: true}} in Enum.to_list(
               EventStream.events(stream)
             )
    end
  end

  test "a subscribed tool finishes cooperatively during the abort grace period" do
    parent = self()
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity, idle_timeout: :infinity)

    tool =
      LemonAgent.new_tool(
        name: "cooperative",
        description: "Waits for an abort notification",
        parameters: %{"type" => "object", "properties" => %{}},
        execute: fn _, _, signal, _ ->
          AbortSignal.subscribe(signal)

          try do
            send(parent, {:tool_started, self()})

            receive do
              {:lemon_abort, ^signal, :abort} ->
                %AgentToolResult{
                  content: [%TextContent{text: "cleanup completed"}],
                  details: %{cleanup: :complete},
                  trust: :untrusted
                }
            end
          after
            AbortSignal.unsubscribe(signal)
          end
        end
      )

    call = Mocks.tool_call(tool.name, %{}, id: "cooperative")

    runner =
      start_waiter(fn ->
        ToolCalls.execute_and_collect_tools(
          context([tool]),
          [],
          [call],
          config(tool_timeout_ms: :infinity),
          signal,
          stream
        )
      end)

    assert_receive {:tool_started, _}, 1_000
    assert_waiting(runner, ToolCalls, :collect_parallel_tool_results, 16)
    assert_subscribed(runner.pid, signal)
    AbortSignal.abort(signal)
    pid = runner.pid

    assert_receive {:waiter_result, ^pid, {[result], _, _}}, 1_000
    refute result.is_error
    assert result.content == [%TextContent{text: "cleanup completed"}]
    assert result.details == %{cleanup: :complete}
    assert result.trust == :untrusted
    finish_waiter(runner, signal)
    EventStream.complete(stream, [])
  end

  test "abort terminates an uncooperative tool after grace and never starts queued calls" do
    parent = self()
    signal = AbortSignal.new()
    {:ok, stream} = EventStream.start_link(timeout: :infinity, idle_timeout: :infinity)

    tool =
      LemonAgent.new_tool(
        name: "blocking",
        description: "Does not cooperate with cancellation",
        parameters: %{"type" => "object", "properties" => %{}},
        execute: fn id, _, _, _ ->
          send(parent, {:tool_started, id, self()})

          receive do
            :finish -> %AgentToolResult{content: [%TextContent{text: "finished"}]}
          end
        end
      )

    calls = [
      Mocks.tool_call(tool.name, %{}, id: "running"),
      Mocks.tool_call(tool.name, %{}, id: "queued")
    ]

    runner =
      start_waiter(fn ->
        ToolCalls.execute_and_collect_tools(
          context([tool]),
          [],
          calls,
          config(tool_timeout_ms: :infinity),
          signal,
          stream
        )
      end)

    assert_receive {:tool_started, "running", worker}, 1_000
    monitor = Process.monitor(worker)
    assert_waiting(runner, ToolCalls, :collect_parallel_tool_results, 16)
    assert_subscribed(runner.pid, signal)
    AbortSignal.abort(signal)
    pid = runner.pid

    assert_receive {:waiter_result, ^pid, {[running, queued], _, _}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
    assert running.details.outcome == :unknown
    assert queued.details.outcome == :not_started
    refute_received {:tool_started, "queued", _}
    finish_waiter(runner, signal)
    EventStream.complete(stream, [])
  end

  defp context(tools \\ []) do
    AgentContext.new(messages: [Mocks.user_message("run")], tools: tools)
  end

  defp config(opts) do
    struct!(
      AgentLoopConfig,
      Keyword.merge(
        [
          model: Mocks.mock_model(),
          convert_to_llm: Mocks.simple_convert_to_llm(),
          stream_options: %StreamOptions{}
        ],
        opts
      )
    )
  end

  defp start_waiter(fun) do
    parent = self()

    runner =
      Task.async(fn ->
        receive do
          :run -> :ok
        end

        result = fun.()
        send(parent, {:waiter_result, self(), result})

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      if Process.alive?(runner.pid), do: Process.exit(runner.pid, :kill)
    end)

    :erlang.trace(runner.pid, true, [:running, :arity, :receive])
    send(runner.pid, :run)
    runner
  end

  defp assert_waiting(runner, module, function, arity) do
    pid = runner.pid
    assert_receive {:trace, ^pid, :out, {^module, ^function, ^arity}}, 1_000
  end

  defp assert_subscribed(pid, signal) do
    assert Enum.any?(Registry.lookup(@registry, signal), fn {subscriber, _} ->
             subscriber == pid
           end)
  end

  defp assert_notification_without_tick(pid, signal, kind) do
    # Trace only the waiting phase, through arrival of the wakeup message.
    # Cancellation cleanup legitimately uses receive_response(request, 0) to
    # abandon an outstanding provider request, which can trace a timeout.
    receive do
      {:trace, ^pid, :receive, :timeout} ->
        flunk("waiter timed out before receiving its cancellation notification")

      {:trace, ^pid, :receive, {:lemon_abort, ^signal, ^kind}} ->
        :ok
    after
      1_000 -> flunk("waiter did not receive its cancellation notification")
    end
  end

  defp finish_waiter(runner, signal) do
    # Keep the waiter alive so Registry's process monitoring cannot hide a
    # missing unsubscribe in the streaming/tool execution boundary.
    refute Enum.any?(Registry.lookup(@registry, signal), fn {pid, _} -> pid == runner.pid end)
    send(runner.pid, :finish)
    assert Task.await(runner, 1_000) == :ok
  end

  defp notify(signal, :abort), do: AbortSignal.abort(signal)
  defp notify(signal, :redirect), do: AbortSignal.request_redirect(signal)
end
