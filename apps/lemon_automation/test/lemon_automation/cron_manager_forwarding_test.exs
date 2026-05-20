defmodule LemonAutomation.CronManagerForwardingTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronRun, CronStore}
  alias LemonCore.{Bus, Event, Store}

  defmodule ForwardingTelegramPlugin do
    @behaviour LemonChannels.Plugin

    @impl true
    def id, do: "telegram"

    @impl true
    def meta do
      %{
        label: "Forwarding Telegram Test",
        capabilities: %{chunk_limit: 4096},
        docs: nil
      }
    end

    @impl true
    def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}

    @impl true
    def normalize_inbound(_raw), do: {:error, :not_implemented}

    @impl true
    def deliver(payload) do
      case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:cron_forwarded_channel_payload, payload})
        _ -> :ok
      end

      {:ok, :delivered}
    end

    @impl true
    def gateway_methods, do: []
  end

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

  test "forwards completed cron summary into originating channel_peer session", %{token: token} do
    channel_session_key =
      "agent:cron_forward_#{token}:telegram:default:group:-100#{abs(token)}:thread:#{abs(token)}"

    run = build_running_run(token, "channel", channel_session_key)
    :ok = CronStore.put_run(run)
    register_forwarding_telegram_plugin()

    topic = Bus.session_topic(channel_session_key)
    Bus.subscribe(topic)
    flush_events()

    on_exit(fn ->
      Bus.unsubscribe(topic)
    end)

    send(CronManager, {:run_complete, run.id, {:ok, "RUN SUMMARY\n- shipped from topic"}})

    assert_receive %Event{
                     type: :run_completed,
                     payload: %{completed: %{ok: true, answer: answer}},
                     meta: meta
                   },
                   2_000

    assert is_binary(answer)
    assert answer =~ "RUN SUMMARY"
    assert answer =~ "cron_run_id: #{run.id}"
    assert meta[:session_key] == channel_session_key
    assert meta[:cron_forwarded_summary] == true
    assert meta[:cron_run_id] == run.id

    assert await(fn ->
             match?(%CronRun{status: :completed}, CronStore.get_run(run.id))
           end)

    {forwarded_run_id, forwarded_data} =
      await_value(fn ->
        Store.get_run_history(channel_session_key, limit: 20)
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
    assert forwarded_summary[:session_key] == channel_session_key
    assert forwarded_completed[:ok] == true
    assert is_binary(forwarded_completed[:answer])
    assert forwarded_completed[:answer] =~ "RUN SUMMARY"

    assert_receive {:cron_forwarded_channel_payload,
                    %LemonChannels.OutboundPayload{content: channel_content}},
                   2_000

    assert channel_content =~ "RUN SUMMARY"
  end

  test "enqueues completed cron summary into originating channel outbox", %{token: token} do
    channel_session_key =
      "agent:cron_forward_#{token}:telegram:default:group:-100#{abs(token)}:thread:#{abs(token)}"

    run = build_running_run(token, "channel_delivery", channel_session_key)
    :ok = CronStore.put_run(run)
    register_forwarding_telegram_plugin()

    send(CronManager, {:run_complete, run.id, {:ok, "RUN SUMMARY\n- delivered to topic"}})

    assert_receive {:cron_forwarded_channel_payload,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      account_id: "default",
                      peer: %{kind: :group, id: peer_id, thread_id: thread_id},
                      kind: :text,
                      content: content,
                      idempotency_key: idempotency_key,
                      meta: %{
                        origin: :cron,
                        cron_forwarded_summary: true,
                        cron_run_id: run_id,
                        cron_job_id: job_id
                      }
                    }},
                   2_000

    assert peer_id == "-100#{abs(token)}"
    assert thread_id == "#{abs(token)}"
    assert content =~ "RUN SUMMARY"
    assert content =~ "cron_run_id: #{run.id}"
    assert idempotency_key == "cron_notify_#{run.id}"
    assert run_id == run.id
    assert job_id == run.job_id
  end

  defp register_forwarding_telegram_plugin do
    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")
    :persistent_term.put({ForwardingTelegramPlugin, :notify_pid}, self())
    :ok = LemonChannels.Registry.register(ForwardingTelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({ForwardingTelegramPlugin, :notify_pid})
      _ = LemonChannels.Registry.unregister("telegram")

      if is_atom(existing) and not is_nil(existing) do
        _ = LemonChannels.Registry.register(existing)
      end
    end)
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
