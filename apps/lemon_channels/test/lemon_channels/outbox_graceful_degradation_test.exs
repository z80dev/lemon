defmodule LemonChannels.OutboxGracefulDegradationTest do
  @moduledoc """
  Tests that the outbox delivery chain degrades gracefully when backing
  GenServers are unavailable (stopped, crashed, or timing out).

  The catch :exit wrappers in RateLimiter, Dedupe, and Outbox must return
  safe default values instead of propagating the exit to callers.

  Strategy: temporarily unregister each GenServer's name so that
  GenServer.call raises :exit (noproc), then re-register the name
  back to the original pid. This avoids disrupting the application
  supervision tree.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Outbox
  alias LemonChannels.Outbox.{Dedupe, RateLimiter}
  alias LemonChannels.OutboundPayload

  # Temporarily unregister a named process, run the given function,
  # then re-register the name to the same pid.
  defp with_process_unavailable(name, fun) do
    pid = Process.whereis(name)
    assert is_pid(pid), "#{inspect(name)} must be running"
    Process.unregister(name)

    try do
      fun.()
    after
      # Re-register the name to the same (still alive) process
      Process.register(pid, name)
    end
  end

  describe "RateLimiter graceful degradation" do
    test "check returns :ok when process is unavailable" do
      with_process_unavailable(RateLimiter, fn ->
        # GenServer.call will exit with :noproc because the name is unregistered.
        # The catch :exit clause must return :ok (fail-open).
        assert RateLimiter.check("ch1", "acc1") == :ok
      end)

      # Verify the process is still functional after re-registration
      assert RateLimiter.check("ch1", "acc1") == :ok
    end

    test "consume returns :ok when process is unavailable" do
      with_process_unavailable(RateLimiter, fn ->
        assert RateLimiter.consume("ch1", "acc1") == :ok
      end)

      assert RateLimiter.consume("ch1-after", "acc1") == :ok
    end
  end

  describe "Dedupe graceful degradation" do
    test "check returns :new when process is unavailable" do
      with_process_unavailable(Dedupe, fn ->
        # The catch :exit clause must return :new (fail-open).
        assert Dedupe.check("ch1", "test_key") == :new
      end)

      assert Dedupe.check("ch1", "verify_alive") == :new
    end
  end

  describe "Outbox graceful degradation" do
    test "enqueue returns {:error, :timeout} when process is unavailable" do
      payload = %OutboundPayload{
        channel_id: "test-channel",
        kind: :text,
        content: "should not crash",
        account_id: "account-1",
        peer: %{kind: :dm, id: "user-1", thread_id: nil}
      }

      with_process_unavailable(Outbox, fn ->
        # The catch :exit clause must return {:error, :timeout}.
        assert Outbox.enqueue(payload) == {:error, :timeout}
      end)
    end
  end
end
