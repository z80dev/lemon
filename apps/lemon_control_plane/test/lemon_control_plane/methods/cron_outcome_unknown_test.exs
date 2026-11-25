defmodule LemonControlPlane.Methods.CronOutcomeUnknownTest do
  # Temporarily replaces the registered cron manager with a proxy process.
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{CronAbort, CronRun}

  # #620: an unknown trigger or abort outcome is never folded into a retryable
  # internal error; it names the affected ID and says a retry is unsafe.
  test "cron.run and cron.abort report retrySafe: false on an unknown outcome" do
    test_pid = self()

    with_cron_manager(
      fn request ->
        send(test_pid, {:cron_request, request})
        {:error, :outcome_unknown}
      end,
      fn ->
        assert {:error,
                {:unavailable, _message,
                 %{
                   "code" => "RUN_OUTCOME_UNKNOWN",
                   "jobId" => "job-1",
                   "runId" => run_id,
                   "retrySafe" => false
                 }}} = CronRun.handle(%{"id" => "job-1"}, %{})

        # The ID was fixed before the call and is the one the scheduler claims.
        assert_received {:cron_request, {:run_now_with_id, "job-1", ^run_id}}

        assert {:error,
                {:unavailable, _message,
                 %{"code" => "ABORT_OUTCOME_UNKNOWN", "runId" => "run-1", "retrySafe" => false}}} =
                 CronAbort.handle(%{"runId" => "run-1"}, %{})
      end
    )
  end

  test "a scheduler that dies after receiving the call is an unknown outcome" do
    test_pid = self()

    # The proxy exits while handling the call, as a crashed or timed-out
    # scheduler would after the trigger may already have taken effect.
    with_cron_manager(
      fn request ->
        send(test_pid, {:cron_request, request})
        exit(:lost_reply)
      end,
      fn ->
        assert {:error,
                {:unavailable, _, %{"jobId" => "job-2", "runId" => run_id, "retrySafe" => false}}} =
                 CronRun.handle(%{"id" => "job-2"}, %{})

        assert is_binary(run_id) and run_id != ""
        assert_received {:cron_request, {:run_now_with_id, "job-2", ^run_id}}
      end
    )

    with_cron_manager(fn _request -> exit(:lost_reply) end, fn ->
      assert {:error, {:unavailable, _, %{"runId" => "run-2", "retrySafe" => false}}} =
               CronAbort.handle(%{"runId" => "run-2"}, %{})
    end)
  end

  defp with_cron_manager(reply, fun) do
    name = LemonAutomation.CronManager
    original = Process.whereis(name)
    assert is_pid(original)
    proxy = spawn(fn -> proxy_loop(reply) end)
    Process.unregister(name)
    Process.register(proxy, name)

    try do
      fun.()
    after
      if Process.whereis(name) == proxy, do: Process.unregister(name)
      Process.register(original, name)
      Process.exit(proxy, :kill)
    end
  end

  defp proxy_loop(reply) do
    receive do
      {:"$gen_call", from, request} ->
        GenServer.reply(from, reply.(request))
        proxy_loop(reply)
    end
  end
end
