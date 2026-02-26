defmodule LemonAutomation.CronManagerForwardingTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}
  alias LemonCore.{Bus, Event, Store}

  setup do
    ensure_store_started()
    ensure_cron_manager_started()

    {:ok, token: System.unique_integer([:positive, :monotonic])}
  end

  test "forwards completed cron summary into originating main session", %{token: token} do
    base_session_key = "agent:cron_forward_#{token}:main"
    run = build_running_run(token, "main", base_session_key)
    :ok = CronStore.put_run(run)

    topic = Bus.session_topic(base_session_key)
    Bus.subscribe(topic)
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe(topic)
    end)

    send(CronManager, {:run_complete, run.id, {:ok, "RUN SUMMARY\n- shipped one artifact"}})

    assert_receive %Event{
                     type: :run_completed,
                     payload: %{completed: %{ok: true, answer: answer}},
                     meta: meta
                   },
                   2_000

    assert is_binary(answer)
    assert answer =~ "RUN SUMMARY"
    assert answer =~ "cron_run_id: #{run.id}"
    assert meta[:session_key] == base_session_key
    assert meta[:cron_forwarded_summary] == true
    assert meta[:cron_run_id] == run.id

    assert await(fn ->
             match?(%CronRun{status: :completed}, CronStore.get_run(run.id))
           end)

    {forwarded_run_id, forwarded_data} =
      await_value(fn ->
        Store.get_run_history(base_session_key, limit: 20)
        |> Enum.find(fn {run_id, data} ->
          summary = data[:summary] || %{}
          summary_meta = summary[:meta] || %{}

          String.starts_with?(to_string(run_id), "cron_notify_") and
            summary_meta[:cron_forwarded_summary] == true
        end)
      end)

    assert forwarded_run_id == "cron_notify_" <> run.id
    forwarded_summary = forwarded_data[:summary] || %{}
    forwarded_completed = forwarded_summary[:completed] || %{}
    assert forwarded_summary[:session_key] == base_session_key
    assert forwarded_completed[:ok] == true
    assert is_binary(forwarded_completed[:answer])
    assert forwarded_completed[:answer] =~ "RUN SUMMARY"
  end

  test "does not forward into non-main sessions", %{token: token} do
    channel_session_key =
      "agent:cron_forward_#{token}:telegram:default:group:-100#{abs(token)}:thread:#{abs(token)}"

    run = build_running_run(token, "channel", channel_session_key)
    :ok = CronStore.put_run(run)

    topic = Bus.session_topic(channel_session_key)
    Bus.subscribe(topic)
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe(topic)
    end)

    send(CronManager, {:run_complete, run.id, {:ok, "RUN SUMMARY\n- should not forward"}})

    refute_receive %Event{
                     type: :run_completed,
                     meta: %{cron_forwarded_summary: true}
                   },
                   500

    assert await(fn ->
             match?(%CronRun{status: :completed}, CronStore.get_run(run.id))
           end)

    assert Store.get_run_history(channel_session_key, limit: 5) == []
  end

  defp build_running_run(token, suffix, session_key) do
    %CronRun{
      id: "run_forward_#{token}_#{suffix}",
      job_id: "cron_forward_job_#{token}_#{suffix}",
      run_id: "router_forward_#{token}_#{suffix}",
      status: :running,
      started_at_ms: LemonCore.Clock.now_ms() - 1_000,
      completed_at_ms: nil,
      duration_ms: nil,
      triggered_by: :schedule,
      error: nil,
      output: nil,
      suppressed: false,
      meta: %{
        session_key: session_key,
        job_name: "forwarding-test-#{suffix}",
        agent_id: "cron_forward_#{token}"
      }
    }
  end

  defp await(fun, attempts \\ 100)

  defp await(_fun, 0), do: false

  defp await(fun, attempts) when is_function(fun, 0) do
    if fun.() do
      true
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  defp await_value(fun, attempts \\ 100)

  defp await_value(_fun, 0), do: flunk("timed out waiting for expected value")

  defp await_value(fun, attempts) when is_function(fun, 0) do
    case fun.() do
      nil ->
        Process.sleep(10)
        await_value(fun, attempts - 1)

      value ->
        value
    end
  end

  defp flush_events do
    receive do
      %Event{} -> flush_events()
    after
      0 -> :ok
    end
  end

  defp ensure_store_started do
    if is_nil(Process.whereis(Store)) do
      case start_supervised(Store) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp ensure_cron_manager_started do
    if is_nil(Process.whereis(CronManager)) do
      case start_supervised(CronManager) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end
end
