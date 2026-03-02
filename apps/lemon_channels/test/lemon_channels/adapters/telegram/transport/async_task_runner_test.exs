defmodule LemonChannels.Adapters.Telegram.Transport.AsyncTaskRunnerTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.AsyncTaskRunner

  # ---------------------------------------------------------------------------
  # start_async_task/2
  # ---------------------------------------------------------------------------

  describe "start_async_task/2" do
    test "executes the given function" do
      test_pid = self()
      state = %{token: "test"}

      result = AsyncTaskRunner.start_async_task(state, fn ->
        send(test_pid, :task_executed)
      end)

      # The function runs asynchronously, so give it a moment
      assert_receive :task_executed, 500
      assert result == :ok or match?({:ok, _}, result)
    end

    test "returns :ok for non-function argument" do
      state = %{token: "test"}
      assert AsyncTaskRunner.start_async_task(state, :not_a_function) == :ok
    end

    test "catches errors in the wrapped function" do
      state = %{token: "test"}

      result = AsyncTaskRunner.start_async_task(state, fn ->
        raise "intentional test error"
      end)

      # Should not raise; the error is caught inside the wrapper
      assert result == :ok or match?({:ok, _}, result)
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_subscribe_exec_approvals/0
  # ---------------------------------------------------------------------------

  describe "maybe_subscribe_exec_approvals/0" do
    test "returns :ok" do
      assert AsyncTaskRunner.maybe_subscribe_exec_approvals() == :ok
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_send_approval_request/2
  # ---------------------------------------------------------------------------

  describe "maybe_send_approval_request/2" do
    test "returns :ok for non-map payload" do
      state = %{token: "test", api_mod: nil, account_id: "test"}
      assert AsyncTaskRunner.maybe_send_approval_request(state, nil) == :ok
      assert AsyncTaskRunner.maybe_send_approval_request(state, "string") == :ok
    end

    test "returns :ok for empty payload" do
      state = %{token: "test", api_mod: nil, account_id: "test"}
      assert AsyncTaskRunner.maybe_send_approval_request(state, %{}) == :ok
    end

    test "returns :ok when approval_id is missing" do
      state = %{token: "test", api_mod: nil, account_id: "test"}
      payload = %{pending: %{session_key: "telegram:test:123"}}
      assert AsyncTaskRunner.maybe_send_approval_request(state, payload) == :ok
    end

    test "returns :ok when session_key is missing" do
      state = %{token: "test", api_mod: nil, account_id: "test"}
      payload = %{approval_id: "abc-123", pending: %{}}
      assert AsyncTaskRunner.maybe_send_approval_request(state, payload) == :ok
    end
  end
end
