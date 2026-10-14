defmodule LemonAi.OneshotRetryTest do
  use ExUnit.Case, async: true

  alias LemonAi.OneshotRetry
  alias LemonAi.Types.{AssistantMessage, TextContent}

  defp failure(reason) do
    %AssistantMessage{
      stop_reason: :error,
      error_message: LemonAi.Error.format_error(reason),
      error_details: LemonAi.Error.to_error_details(reason)
    }
  end

  defp scripted(results) do
    parent = self()
    {:ok, queue} = Agent.start_link(fn -> results end)

    fn number ->
      send(parent, {:attempt, number})
      Agent.get_and_update(queue, fn
        [result] -> {result, [result]}
        [result | rest] -> {result, rest}
      end)
    end
  end

  defp options(extra \\ []) do
    parent = self()
    Keyword.merge([base_delay_ms: 2, sleep_fun: fn ms -> send(parent, {:sleep, ms}); :ok end], extra)
  end

  test "invalid numeric policy never starts an unbounded request loop" do
    parent = self()

    for key <- [:max_attempts, :base_delay_ms, :max_delay_ms],
        value <- [:infinity, "3", nil, 1.5] do
      assert_raise ArgumentError, "#{key} must be an integer", fn ->
        OneshotRetry.run(fn _ -> send(parent, :unexpected_attempt); {:error, :timeout} end,
          [{key, value}]
        )
      end
    end

    refute_received :unexpected_attempt
  end

  test "429 response hints determine the wait before retrying a resolved error" do
    failed = failure({:http_error, 429, "Rate limited", [{"retry-after-ms", "1234"}]})
    success = %AssistantMessage{stop_reason: :stop, content: [%TextContent{text: "ok"}]}

    assert OneshotRetry.run(scripted([failed, success]), options()) == success
    assert_receive {:attempt, 1}
    assert_receive {:sleep, 1234}
    assert_receive {:attempt, 2}
    refute_received {:attempt, _}
  end

  test "resolved and tuple outcomes recover transient server and overloaded failures" do
    success = %AssistantMessage{stop_reason: :stop}

    for reason <- [
          {:http_error, 500, "Internal server error"},
          {:http_error, 503, "Service unavailable"},
          {:http_error, 529, %{"error" => %{"type" => "overloaded_error"}}},
          :timeout,
          "overloaded_error"
        ],
        wrap <- [:resolved, :ok, :error] do
      failed = failure(reason)
      result = case wrap do
        :resolved -> failed
        :ok -> {:ok, failed}
        :error -> {:error, reason}
      end

      assert OneshotRetry.run(scripted([result, {:ok, success}]), options()) == {:ok, success}
      assert_receive {:attempt, 1}
      assert_receive {:sleep, delay}
      assert delay == 2
      assert_receive {:attempt, 2}
      refute_received {:attempt, _}
    end
  end

  test "client, authentication, overflow and quota errors surface unchanged" do
    for reason <- [
          {:http_error, 400, "Bad request"},
          {:http_error, 401, "Unauthorized"},
          {:http_error, 403, "Forbidden"},
          {:http_error, 429, %{"error" => %{"code" => "insufficient_quota"}}},
          {:http_error, 503, %{"error" => %{"code" => "context_length_exceeded"}}},
          "maximum context length exceeded; temporarily unavailable"
        ],
        result <- [{:error, reason}, failure(reason), {:ok, failure(reason)}] do
      assert OneshotRetry.run(scripted([result]), options()) == result
      assert_receive {:attempt, 1}
      refute_received {:attempt, _}
      refute_received {:sleep, _}
    end
  end

  test "long hints surface unchanged instead of being capped below server requirements" do
    failed = %{failure("Rate limit exceeded") | retry_after_ms: 30_001}
    assert OneshotRetry.run(scripted([{:ok, failed}]), options()) == {:ok, failed}
    assert_receive {:attempt, 1}
    refute_received {:attempt, _}
    refute_received {:sleep, _}
  end

  test "backoff is capped but an allowed server hint is never shortened" do
    success = %AssistantMessage{stop_reason: :stop}
    assert OneshotRetry.run(scripted([{:error, :timeout}, success]),
             options(base_delay_ms: 10_000, max_delay_ms: 1)
           ) == success
    assert_receive {:attempt, 1}
    assert_receive {:sleep, 1}
    assert_receive {:attempt, 2}

    failed = %{failure("Rate limit exceeded") | retry_after_ms: 17}
    assert OneshotRetry.run(scripted([failed, success]),
             options(base_delay_ms: 1, max_delay_ms: 17)
           ) == success
    assert_receive {:attempt, 1}
    assert_receive {:sleep, 17}
    assert_receive {:attempt, 2}
    refute_received {:attempt, _}
  end

  test "attempts are bounded per invocation including the first" do
    for max_attempts <- [0, 1, 3] do
      assert OneshotRetry.run(scripted([{:error, :timeout}]), options(max_attempts: max_attempts)) ==
               {:error, :timeout}

      total = max(1, max_attempts)
      for number <- 1..total, do: assert_receive({:attempt, ^number})
      refute_received {:attempt, _}
      if total > 1, do: for(_ <- 2..total, do: assert_receive({:sleep, _}))
      refute_received {:sleep, _}
    end
  end

  test "cancellation before a call never invokes it" do
    assert OneshotRetry.run(scripted([{:error, :timeout}]), options(cancelled?: fn -> true end)) ==
             {:error, :aborted}
    refute_received {:attempt, _}
  end

  test "cancellation already visible when an attempt settles preserves its result" do
    {:ok, state} = Agent.start_link(fn -> false end)
    original = {:error, :timeout}

    run = fn _ ->
      Agent.update(state, fn _ -> true end)
      original
    end

    assert OneshotRetry.run(run, options(cancelled?: fn -> Agent.get(state, & &1) end)) == original
    refute_received {:sleep, _}
  end

  test "cancellation during an injected wait is returned rather than relabeled as provider error" do
    assert OneshotRetry.run(scripted([{:error, :timeout}]),
             options(sleep_fun: fn _ -> {:error, :user_cancel} end)
           ) == {:error, :user_cancel}
    assert_receive {:attempt, 1}
    refute_received {:attempt, _}
  end

  test "default backoff wait polls cancellation promptly" do
    parent = self()
    {:ok, canceled} = Agent.start_link(fn -> false end)

    runner = Task.async(fn ->
      OneshotRetry.run(fn _ -> send(parent, :failed_attempt); {:error, :timeout} end,
        base_delay_ms: 5_000,
        cancelled?: fn -> Agent.get(canceled, & &1) end
      )
    end)

    assert_receive :failed_attempt
    # Let the result settle and enter its wait before canceling.
    Process.sleep(100)
    Agent.update(canceled, fn _ -> true end)
    assert Task.await(runner, 1_000) == {:error, :aborted}
    refute_received :failed_attempt
  end

  test "aborted and redirected messages never replay despite transient error metadata" do
    for reason <- [:aborted, :redirected] do
      message = %{failure(:timeout) | stop_reason: reason}
      for result <- [message, {:ok, message}, {:error, message}] do
        assert OneshotRetry.run(scripted([result]), options()) == result
        assert_receive {:attempt, 1}
        refute_received {:attempt, _}
        refute_received {:sleep, _}
      end
    end
  end
end
