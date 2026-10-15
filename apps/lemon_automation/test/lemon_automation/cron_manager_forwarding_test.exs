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
    ensure_channel_registry_started()
    ensure_channel_outbox_started()

    if is_nil(Process.whereis(LemonChannels.Supervision)),
      do: start_supervised!(LemonChannels.Supervision)

    {:ok, token: System.unique_integer([:positive, :monotonic])}
  end

  test "goal and isolated kanban supervision keep their exact bound topic", %{token: token} do
    register_forwarding_telegram_plugin()
    session = "agent:remote_#{token}:main"
    params = %{run_id: "run_goal_remote_#{token}", session_key: session <> ":goal_judge"}

    {:ok, goal} =
      LemonAgent.Workspace.GoalStore.set(session, "Check result",
        meta: %{"deliverTo" => "telegram:-100777:12"}
      )

    on_exit(fn -> LemonAgent.Workspace.GoalStore.clear(session) end)
    assert :ok = LemonAutomation.RunNotifications.bind_goal(goal, params)

    {:ok, _} =
      LemonAgent.Workspace.GoalStore.record_loop_status(session, :running,
        run_id: params.run_id,
        run_kind: :judge
      )

    {:ok, _} = LemonAgent.Workspace.GoalStore.complete(session)
    assert :ok = LemonAutomation.RunNotifications.goal_finished(session, :finished)

    assert_receive {:cron_forwarded_channel_payload,
                    %{peer: %{id: "-100777", thread_id: "12"}, content: content}},
                   2_000

    assert content =~ goal.id
    assert content =~ params.run_id
    assert :ok = LemonAutomation.RunNotifications.goal_finished(session, :finished)
    refute_receive {:cron_forwarded_channel_payload, _}, 100

    {:ok, board} =
      LemonAgent.Workspace.KanbanStore.create_board("Remote",
        meta: %{
          "notificationSessionKey" => "agent:operator:telegram:default:group:-100777:thread:12"
        }
      )

    on_exit(fn -> LemonAgent.Workspace.KanbanStore.clear_board(board.id) end)

    {:ok, task} =
      LemonAgent.Workspace.KanbanStore.create_task(board.id, "Remote card",
        session_key: session,
        run_id: "run_card_remote_#{token}"
      )

    assert :ok =
             LemonAutomation.RunNotifications.bind_kanban(task, %{
               run_id: task.run_id,
               session_key: session
             })

    {:ok, leased} = LemonAgent.Workspace.KanbanStore.lease_task(board.id, "worker")
    lease = leased.meta["kanbanLease"]["id"]

    {:ok, failed} =
      LemonAgent.Workspace.KanbanStore.fail_leased_task(task.id, lease, "run_failed")

    assert :ok = LemonAutomation.RunNotifications.kanban_finished(failed, lease)

    assert_receive {:cron_forwarded_channel_payload,
                    %{peer: %{id: "-100777", thread_id: "12"}, content: content}},
                   2_000

    assert content =~ task.id
    assert content =~ task.run_id
  end

  test "exact SILENT output is recorded but never forwarded or delivered", %{token: token} do
    register_forwarding_telegram_plugin()
    session = "agent:cron_silent_#{token}:main"
    job = add_job!(token, "silent", session, deliver_to: "telegram:424242")
    topic = Bus.session_topic(session)
    Bus.subscribe(topic)
    on_exit(fn -> Bus.unsubscribe(topic) end)
    run = complete_run!(job, "  [SILENT]\n")

    assert await(fn ->
             match?(%CronRun{status: :completed, suppressed: true}, CronStore.get_run(run.id))
           end)

    refute_receive %Event{type: :run_completed}, 100
    refute_receive {:cron_forwarded_channel_payload, _}, 100
  end

  test "output containing SILENT is still delivered", %{token: token} do
    register_forwarding_telegram_plugin()

    job =
      add_job!(token, "silent-containing", "agent:cron_silent_#{token}:main",
        deliver_to: "telegram:424242"
      )

    run = complete_run!(job, "The marker [SILENT] is not a whole reply")
    assert_receive {:cron_forwarded_channel_payload, _}, 2_000
    assert %CronRun{status: :completed, suppressed: false} = CronStore.get_run(run.id)
  end

  test "failed SILENT output is never suppressed", %{token: token} do
    register_forwarding_telegram_plugin()
    session = "agent:cron_silent_failure_#{token}:main"
    job = add_job!(token, "silent-failure", session, deliver_to: "telegram:424242")

    run = %{
      build_running_run(token, "silent-failure", session)
      | job_id: job.id,
        output: "[SILENT]"
    }

    CronStore.put_run(run)
    send(CronManager, {:run_complete, run.id, {:error, "[SILENT]"}})
    assert_receive {:cron_forwarded_channel_payload, _}, 2_000
    assert %CronRun{status: :failed, suppressed: false} = CronStore.get_run(run.id)
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
                      content: content
                    }},
                   2_000

    assert peer_id == "-100#{abs(token)}"
    assert thread_id == "#{abs(token)}"
    assert content =~ "delivered to topic"
    assert content =~ run.run_id

    assert await(fn ->
             match?(
               {:ok, %{delivery_state: :delivered}},
               LemonChannels.Supervision.status({:cron, run.job_id, run.run_id, :completed})
             )
           end)
  end

  describe "default delivery to the paired owner chat" do
    setup do
      register_forwarding_telegram_plugin()
      pair_owner_chat(424_242)
      :ok
    end

    test "a job created from a non-channel session delivers to the owner chat", %{token: token} do
      job = add_job!(token, "tui", LemonCore.SessionKey.main("cron_forward_#{token}"))
      run = complete_run!(job, "Morning: 2 reminders today")

      assert_receive {:cron_forwarded_channel_payload,
                      %LemonChannels.OutboundPayload{
                        channel_id: "telegram",
                        account_id: "default",
                        peer: %{kind: :dm, id: "424242", thread_id: nil},
                        content: content
                      }},
                     2_000

      assert content =~ "Morning: 2 reminders today"
      assert content =~ run.run_id
    end

    test "a non-Lemon session id (web/CLI client) also falls back to the owner chat", %{
      token: token
    } do
      web_session =
        "agent:cron_forward_#{token}:web:browser:unknown:tab-#{token}"

      job = add_job!(token, "web", web_session)
      complete_run!(job, "done")

      assert_receive {:cron_forwarded_channel_payload,
                      %LemonChannels.OutboundPayload{peer: %{id: "424242"}}},
                     2_000
    end

    test "an explicit deliver_to overrides the owner chat", %{token: token} do
      job =
        add_job!(token, "explicit", LemonCore.SessionKey.main("cron_forward_#{token}"),
          deliver_to: "telegram:-100777:12"
        )

      complete_run!(job, "sent to the team topic")

      assert_receive {:cron_forwarded_channel_payload,
                      %LemonChannels.OutboundPayload{
                        peer: %{kind: :group, id: "-100777", thread_id: "12"},
                        content: content
                      }},
                     2_000

      assert content =~ "sent to the team topic"
    end

    test "deliver_to none opts out of channel delivery", %{token: token} do
      job =
        add_job!(token, "quiet", LemonCore.SessionKey.main("cron_forward_#{token}"),
          deliver_to: "none"
        )

      run = complete_run!(job, "nobody should see this")

      refute_receive {:cron_forwarded_channel_payload, _payload}, 300
      assert %CronRun{status: :completed} = CronStore.get_run(run.id)
    end

    test "a healthy heartbeat is suppressed; any other heartbeat reply is delivered", %{
      token: token
    } do
      job =
        add_job!(token, "heartbeat", LemonCore.SessionKey.main("cron_forward_#{token}"),
          meta: %{heartbeat: true}
        )

      ok_run = complete_run!(job, "  HEARTBEAT_OK\n", "ok")

      refute_receive {:cron_forwarded_channel_payload, _payload}, 300
      assert await(fn -> match?(%CronRun{suppressed: true}, CronStore.get_run(ok_run.id)) end)

      complete_run!(job, "CI is red on main", "alert")

      assert_receive {:cron_forwarded_channel_payload,
                      %LemonChannels.OutboundPayload{content: content}},
                     2_000

      assert content =~ "CI is red on main"
    end

    test "a one-shot job is delivered and then removed", %{token: token} do
      job =
        add_job!(token, "once", LemonCore.SessionKey.main("cron_forward_#{token}"), once: true)

      complete_run!(job, "check the oven")

      assert_receive {:cron_forwarded_channel_payload,
                      %LemonChannels.OutboundPayload{content: content}},
                     2_000

      assert content =~ "check the oven"
      assert await(fn -> not Enum.any?(CronManager.list(), &(&1.id == job.id)) end)
    end
  end

  defp pair_owner_chat(chat_id) do
    previous = Application.get_env(:lemon_gateway, LemonGateway.Config)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      enable_telegram: true,
      telegram: %{allowed_chat_ids: [chat_id]},
      max_concurrent_runs: 1
    })

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_gateway, LemonGateway.Config, previous)
      else
        Application.delete_env(:lemon_gateway, LemonGateway.Config)
      end
    end)
  end

  defp add_job!(token, suffix, session_key, opts \\ []) do
    params =
      %{
        name: "forward-#{token}-#{suffix}",
        schedule: "0 9 * * *",
        agent_id: "cron_forward_#{token}",
        session_key: session_key,
        prompt: "report",
        enabled: false
      }
      |> Map.merge(Map.new(opts))

    {:ok, job} = CronManager.add(params)
    on_exit(fn -> CronManager.remove(job.id) end)
    job
  end

  # Simulates the scheduled run of `job` finishing with `output`.
  defp complete_run!(job, output, suffix \\ "run") do
    run = %CronRun{
      id: "run_#{job.id}_#{suffix}",
      job_id: job.id,
      run_id: "router_#{job.id}_#{suffix}",
      status: :running,
      started_at_ms: LemonCore.Clock.now_ms() - 1_000,
      triggered_by: :schedule,
      suppressed: false,
      meta: %{session_key: job.session_key, job_name: job.name, agent_id: job.agent_id}
    }

    :ok = CronStore.put_run(run)
    send(CronManager, {:run_complete, run.id, {:ok, output}})
    run
  end

  defp register_forwarding_telegram_plugin do
    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")
    :persistent_term.put({ForwardingTelegramPlugin, :notify_pid}, self())
    :ok = LemonChannels.Registry.register(ForwardingTelegramPlugin)

    on_exit(fn ->
      :persistent_term.erase({ForwardingTelegramPlugin, :notify_pid})
      _ = unregister_channel_plugin("telegram")

      if is_atom(existing) and not is_nil(existing) do
        _ = register_channel_plugin(existing)
      end
    end)
  end

  defp unregister_channel_plugin(plugin_id) do
    if is_pid(Process.whereis(LemonChannels.Registry)) do
      LemonChannels.Registry.unregister(plugin_id)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp register_channel_plugin(plugin) do
    if is_pid(Process.whereis(LemonChannels.Registry)) do
      LemonChannels.Registry.register(plugin)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
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

  defp await(fun, attempts \\ 500)

  defp await(_fun, 0), do: false

  defp await(fun, attempts) when is_function(fun, 0) do
    if fun.() do
      true
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end

  defp await_value(fun, attempts \\ 500)

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

  defp ensure_channel_registry_started do
    if is_nil(Process.whereis(LemonChannels.Registry)) do
      case start_supervised(LemonChannels.Registry) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp ensure_channel_outbox_started do
    ensure_channel_dedupe_started()
    ensure_channel_rate_limiter_started()

    if is_nil(Process.whereis(LemonChannels.Outbox.WorkerSupervisor)) do
      case start_supervised({Task.Supervisor, name: LemonChannels.Outbox.WorkerSupervisor}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    if is_nil(Process.whereis(LemonChannels.Outbox)) do
      case start_supervised(LemonChannels.Outbox) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp ensure_channel_dedupe_started do
    if is_nil(Process.whereis(LemonChannels.Outbox.Dedupe)) do
      case start_supervised(LemonChannels.Outbox.Dedupe) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp ensure_channel_rate_limiter_started do
    if is_nil(Process.whereis(LemonChannels.Outbox.RateLimiter)) do
      case start_supervised(LemonChannels.Outbox.RateLimiter) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end
end
