defmodule LemonAi.OneshotRetryTest do
  use ExUnit.Case, async: true

  alias LemonAi.OneshotRetry
  alias LemonAi.Types.AssistantMessage

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

    Keyword.merge(
      [
        base_delay_ms: 2,
        sleep_fun: fn ms ->
          send(parent, {:sleep, ms})
          :ok
        end
      ],
      extra
    )
  end

  test "invalid numeric policy never starts an unbounded request loop" do
    parent = self()

    for key <- [:max_attempts, :base_delay_ms, :max_delay_ms],
        value <- [:infinity, "3"] do
      assert_raise ArgumentError, fn ->
        OneshotRetry.run(
          fn _ ->
            send(parent, :unexpected_attempt)
            {:error, :timeout}
          end,
          [{key, value}]
        )
      end
    end

    refute_received :unexpected_attempt
  end

  test "resolved and tuple outcomes recover transient server and overloaded failures" do
    success = %AssistantMessage{stop_reason: :stop}

    for result <- [
          failure({:http_error, 529, %{"error" => %{"type" => "overloaded_error"}}}),
          {:ok, failure("overloaded_error")},
          {:error, {:http_error, 500, "Internal server error"}}
        ] do
      assert OneshotRetry.run(scripted([result, {:ok, success}]), options()) == {:ok, success}
      assert_receive {:attempt, 1}
      assert_receive {:sleep, delay}
      assert delay == 2
      assert_receive {:attempt, 2}
      refute_received {:attempt, _}
    end
  end

  test "client, authentication, overflow and quota errors surface unchanged" do
    for result <- [
          {:error, {:http_error, 400, "Bad request"}},
          failure({:http_error, 401, "Unauthorized"}),
          {:error, {:http_error, 429, %{"error" => %{"code" => "insufficient_quota"}}}},
          {:ok, failure({:http_error, 503, %{"error" => %{"code" => "context_length_exceeded"}}})}
        ] do
      assert OneshotRetry.run(scripted([result]), options()) == result
      assert_receive {:attempt, 1}
      refute_received {:attempt, _}
      refute_received {:sleep, _}
    end
  end

  test "backoff is capped but an allowed server hint is never shortened" do
    success = %AssistantMessage{stop_reason: :stop}

    assert OneshotRetry.run(
             scripted([{:error, :timeout}, success]),
             options(base_delay_ms: 10_000, max_delay_ms: 1)
           ) == success

    assert_receive {:attempt, 1}
    assert_receive {:sleep, 1}
    assert_receive {:attempt, 2}

    failed = %{failure("Rate limit exceeded") | retry_after_ms: 17}

    assert OneshotRetry.run(
             scripted([failed, success]),
             options(base_delay_ms: 1, max_delay_ms: 17)
           ) == success

    assert_receive {:attempt, 1}
    assert_receive {:sleep, 17}
    assert_receive {:attempt, 2}
    refute_received {:attempt, _}
  end

  test "attempts are bounded per invocation including the first" do
    for max_attempts <- [0, 1] do
      assert OneshotRetry.run(scripted([{:error, :timeout}]), options(max_attempts: max_attempts)) ==
               {:error, :timeout}

      assert_receive {:attempt, 1}
      refute_received {:attempt, _}
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

    assert OneshotRetry.run(run, options(cancelled?: fn -> Agent.get(state, & &1) end)) ==
             original

    refute_received {:sleep, _}
  end

  test "aborted and redirected messages never replay despite transient error metadata" do
    for reason <- [:aborted, :redirected] do
      message = %{failure(:timeout) | stop_reason: reason}

      for result <- [message, {:error, message}] do
        assert OneshotRetry.run(scripted([result]), options()) == result
        assert_receive {:attempt, 1}
        refute_received {:attempt, _}
        refute_received {:sleep, _}
      end
    end
  end
end
