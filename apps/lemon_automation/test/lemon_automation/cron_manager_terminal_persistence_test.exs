defmodule LemonAutomation.CronManagerTerminalPersistenceTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronMonitor, CronRun, CronStore}
  alias LemonCore.{Bus, ChannelSupervision, Event, Store}

  # ETS represents the backend's durable state independently of the reply. This
  # lets a write land while its caller receives an ambiguous failure, without
  # waiting for real Store timeouts or changing the production Store contract.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def put(state, :cron_runs, key, value) do
      terminal? = value.status in [:completed, :failed, :timeout, :aborted]

      if terminal? do
        :ets.update_counter(state.data, {:terminal_writes, key}, {2, 1}, {{:terminal_writes, key}, 0})
        send(state.owner, {:terminal_write, key})
      end

      case state.failure do
        :reject_terminal when terminal? ->
          {:error, :injected_terminal_failure}

        :commit_terminal_unknown when terminal? ->
          :ets.insert(state.data, {{:cron_runs, key}, value})
          {:error, :store_unavailable}

        :reject_run ->
          {:error, :injected_run_failure}

        _ ->
          :ets.insert(state.data, {{:cron_runs, key}, value})
          {:ok, state}
      end
    end

    def put(state, table, key, value) do
      :ets.insert(state.data, {{table, key}, value})
      {:ok, state}
    end

    @impl true
    def put_new(state, table, key, value) do
      if :ets.insert_new(state.data, {{table, key}, value}),
        do: {:ok, state},
        else: {:exists, state}
    end

    @impl true
    def get(%{failure: {:read_run, key}}, :cron_runs, key),
      do: {:error, :injected_read_failure}

    def get(state, table, key) do
      value = case :ets.lookup(state.data, {table, key}) do
        [{_, value}] -> value
        [] -> nil
      end

      {:ok, value, state}
    end

    @impl true
    def delete(state, table, key) do
      :ets.delete(state.data, {table, key})
      {:ok, state}
    end

    @impl true
    def list(state, table) do
      rows = for {{^table, key}, value} <- :ets.tab2list(state.data), do: {key, value}
      {:ok, rows, state}
    end
  end

  defmodule Preflight do
    def check(_job), do: :ok
    def current_default_model, do: {:ok, "test:model"}
  end

  defmodule Submitter do
    def submit(job, run, opts) do
      :ok = Keyword.fetch!(opts, :on_submitting).(run.run_id, job.session_key)
      send(Application.fetch_env!(:lemon_automation, :terminal_persistence_test_pid),
        {:submitted, job.id, run.id, self()})

      receive do
        {:finish, result} -> result
      end
    end
  end

  defmodule Notices do
    @behaviour ChannelSupervision
    def bind_run(_id, _session, _target), do: :ok
    def target_for_run(_id, _session), do: :none

    def notify(_target, notice) do
      send(Application.fetch_env!(:lemon_automation, :terminal_persistence_test_pid),
        {:delivered, notice})
      :ok
    end
  end

  setup do
    application_manager = Process.whereis(CronManager)
    if application_manager, do: :sys.suspend(application_manager)
    original_store = :sys.get_state(Store)
    data = :ets.new(__MODULE__, [:set, :public])
    owner = self()

    :sys.replace_state(Store, fn state ->
      %{state | backend: FaultBackend,
        backend_state: %{data: data, failure: nil, owner: owner}}
    end)

    previous_provider = ChannelSupervision.provider()
    keys = [:cron_run_submitter, :cron_preflight_mod, :terminal_persistence_test_pid]
    previous_env = Map.new(keys, &{&1, Application.get_env(:lemon_automation, &1)})
    Application.put_env(:lemon_automation, :cron_run_submitter, Submitter)
    Application.put_env(:lemon_automation, :cron_preflight_mod, Preflight)
    Application.put_env(:lemon_automation, :terminal_persistence_test_pid, self())
    :ok = ChannelSupervision.register(Notices)
    :ok = Bus.subscribe("cron")

    directory = Path.join(System.tmp_dir!(), "cron_terminal_#{System.unique_integer([:positive])}")
    tasks = start_supervised!(Task.Supervisor)
    manager = start_supervised!({CronManager, name: nil, task_supervisor: tasks})

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
      :sys.replace_state(Store, fn _ -> original_store end)
      restore_env(:lemon_core, :channel_supervision_provider, previous_provider)
      for {key, value} <- previous_env, do: restore_env(:lemon_automation, key, value)
      if application_manager && Process.alive?(application_manager),
        do: :sys.resume(application_manager)
      File.rm_rf!(directory)
    end)

    %{manager: manager, directory: directory, data: data}
  end

  for fault <- [:reject_terminal, :commit_terminal_unknown] do
    @fault fault
    test "#{fault} retains the completed worker's result and gates every retry", context do
      job = add_job(context, max_retries: 1, retry_backoff_ms: 0)
      {run, worker} = start_run(context.manager, job)
      worker_ref = Process.monitor(worker)
      inject(@fault)
      send(worker, {:finish, {:error, "confirmed execution failure"}})
      assert_receive {:terminal_write, run_id}, 1_000
      assert run_id == run.id
      state = :sys.get_state(context.manager)
      pending = state.pending_run_results[run.id]
      assert pending.updated.status == :failed
      refute pending.updated.meta.outcome_unknown
      refute Map.has_key?(state.tasks, run.id)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :normal}, 1_000
      assert_no_effects(context, job, run)
      assert {:error, :outcome_unknown} = GenServer.call(context.manager, {:run_now, job.id})
      assert {:error, :already_running} = GenServer.call(context.manager, {:wake, job.id, []})
      assert {:error, :outcome_unknown} = GenServer.call(context.manager, {:abort_run, run.id})

      # A committed-but-unacknowledged row already exposes retry intent. Local
      # ownership must still gate the retry timer and jittered submit messages.
      send(context.manager, :retry_tick)
      send(context.manager, {:submit_claimed_run, job.id, run.id})
      state = :sys.get_state(context.manager)
      assert state.pending_run_results[run.id] == pending
      assert_no_effects(context, job, run)
      refute_received {:submitted, _, _, _}

      # An unreadable reconciliation is not permission to rewrite or execute.
      writes = terminal_writes(context.data, run.id)
      inject({:read_run, run.id})
      tick(context.manager)
      assert terminal_writes(context.data, run.id) == writes
      assert_no_effects(context, job, run)

      inject(nil)
      state = tick(context.manager)
      assert state.pending_run_results == %{}
      persisted = CronStore.get_run(run.id)
      assert persisted.status == :failed
      assert persisted.completed_at_ms == pending.updated.completed_at_ms
      assert persisted.meta.retry_due_at_ms == pending.updated.meta.retry_due_at_ms
      assert terminal_writes(context.data, run.id) == if(@fault == :reject_terminal, do: 2, else: 1)
      assert CronJob.failure_streak(CronStore.get_job(job.id)) == 1
      assert_receive %Event{type: :cron_run_completed, payload: %{cron_run_id: ^run_id}}, 1_000
      assert_receive {:delivered, %{status: :failed}}, 1_000
      retry_id = CronStore.retry_run_id(run.id, 1)
      assert_receive {:submitted, _, ^retry_id, retry_worker}, 1_000
      refute_received {:submitted, _, ^run_id, _}

      send(context.manager, {:run_complete, run.id, {:ok, "late duplicate"}})
      :sys.get_state(context.manager)
      assert CronStore.get_run(run.id).status == :failed
      assert CronJob.failure_streak(CronStore.get_job(job.id)) == 1
      refute_received %Event{type: :cron_run_completed}
      refute_received {:delivered, _}
      refute_received {:submitted, _, _, _}

      send(retry_worker, {:finish, {:ok, "recovered"}})
      assert_receive {:terminal_write, ^retry_id}, 1_000
      :sys.get_state(context.manager)
      assert CronStore.get_run(retry_id).status == :completed
      assert CronJob.failure_streak(CronStore.get_job(job.id)) == 0
    end
  end

  test "successful terminal write gates monitor, preflight, heartbeat and memory effects", context do
    job = add_job(context, monitor: true, meta: %{heartbeat: true})
    notice = %{class: :model_drift, detail_hash: "old", occurrences: 1, notifications: 1,
      first_seen_at_ms: 1, last_notified_at_ms: 1}
    :ok = CronStore.put_preflight_notice_state(job.id, notice)
    {run, worker} = start_run(context.manager, job)
    inject(:reject_terminal)
    send(worker, {:finish, {:ok, "changed result"}})
    assert_receive {:terminal_write, run_id}, 1_000
    assert run_id == run.id
    :sys.get_state(context.manager)
    assert_no_effects(context, job, run)
    assert CronStore.get_monitor_state(job.id) == nil
    assert CronStore.get_preflight_notice_state(job.id) == notice
    assert CronStore.list_audit_events(run_id: run.id) == []

    # Even a due slot must not advance while the previous result is unconfirmed.
    due_job = %{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1}
    :ok = CronStore.put_job(due_job)
    :sys.replace_state(context.manager, &put_in(&1.jobs[job.id], due_job))
    tick(context.manager)
    assert CronStore.get_job(job.id).next_run_at_ms == due_job.next_run_at_ms
    assert CronStore.get_monitor_state(job.id) == nil
    refute_received {:submitted, _, _, _}
    :ok = CronStore.put_job(job)
    :sys.replace_state(context.manager, &put_in(&1.jobs[job.id], job))

    inject(nil)
    tick(context.manager)
    assert CronStore.get_run(run.id).status == :completed
    assert CronStore.get_monitor_state(job.id).last_hash == CronMonitor.hash("changed result")
    assert CronStore.get_preflight_notice_state(job.id) == nil
    memory = File.read!(job.memory_file)
    assert memory =~ run.id
    assert_receive %Event{type: :heartbeat_alert}, 1_000
    assert_receive %Event{type: :cron_run_completed}, 1_000
    assert_receive {:delivered, %{status: :completed}}, 1_000

    send(context.manager, {:run_complete, run.id, {:ok, "late replacement"}})
    :sys.get_state(context.manager)
    assert CronStore.get_run(run.id).output == "changed result"
    assert File.read!(job.memory_file) == memory
    refute_received %Event{type: :heartbeat_alert}
    refute_received %Event{type: :cron_run_completed}
    refute_received {:delivered, _}
  end

  test "unknown execution remains active after its persistence recovers", context do
    job = add_job(context, max_retries: 2, retry_backoff_ms: 0)
    {run, worker} = start_run(context.manager, job)
    inject(:reject_run)
    # This external completion path also verifies owned waiter shutdown without
    # relying on process scheduling or a polling sleep.
    send(context.manager, {:run_complete, run.id, {:error, {:outcome_unknown, run.run_id}}})
    state = :sys.get_state(context.manager)
    assert state.pending_run_results[run.id].updated.meta.outcome_unknown
    refute Process.alive?(worker)
    assert_no_effects(context, job, run)

    inject(nil)
    state = tick(context.manager)
    assert state.pending_run_results == %{}
    persisted = CronStore.get_run(run.id)
    assert persisted.status == :running
    assert persisted.meta.outcome_unknown
    assert persisted.meta[:retry_due_at_ms] == nil
    assert_no_effects(context, job, run)
    assert {:error, :outcome_unknown} = GenServer.call(context.manager, {:run_now, job.id})

    :ok = LemonCore.RunStore.finalize(run.run_id, %{
      completed: %{ok: true, answer: "durably reconciled"}, session_key: job.session_key
    })
    tick(context.manager)
    assert CronStore.get_run(run.id).status == :completed
    assert CronStore.get_run(run.id).output == "durably reconciled"
    refute_received {:submitted, _, _, _}
    assert_receive %Event{type: :cron_run_completed}, 1_000
  end

  test "an unreadable completion row retains the original result until the read recovers", context do
    job = add_job(context)
    {run, worker} = start_run(context.manager, job)
    inject({:read_run, run.id})
    send(context.manager, {:run_complete, run.id, {:ok, "first completion"}})
    state = :sys.get_state(context.manager)
    assert state.pending_run_results[run.id].result == {:ok, "first completion"}
    assert {:error, :store_unavailable} = CronStore.fetch_run(run.id)
    refute Process.alive?(worker)
    assert_no_effects(context, job, run)
    send(context.manager, {:run_complete, run.id, {:error, "duplicate"}})
    :sys.get_state(context.manager)
    inject(nil)
    tick(context.manager)
    assert CronStore.get_run(run.id).output == "first completion"
    assert_receive %Event{type: :cron_run_completed}, 1_000
    assert_receive {:delivered, %{status: :completed}}, 1_000
    refute_received {:submitted, _, _, _}
  end

  test "confirmed completion replaces a pending unknown outcome without executing again", context do
    job = add_job(context)
    {run, _worker} = start_run(context.manager, job)
    inject(:reject_run)
    send(context.manager, {:run_complete, run.id, {:error, {:outcome_unknown, run.run_id}}})
    state = :sys.get_state(context.manager)
    assert state.pending_run_results[run.id].updated.meta.outcome_unknown

    send(context.manager, {:run_complete, run.id, {:ok, "confirmed later"}})
    state = :sys.get_state(context.manager)
    assert state.pending_run_results[run.id].updated.status == :completed
    refute state.pending_run_results[run.id].updated.meta.outcome_unknown
    assert_no_effects(context, job, run)

    inject(nil)
    tick(context.manager)
    assert CronStore.get_run(run.id).output == "confirmed later"
    assert_receive %Event{type: :cron_run_completed}, 1_000
    refute_received {:submitted, _, _, _}
  end

  test "preflight fingerprints are deferred until the failed run is durable", context do
    job = add_job(context)
    {run, _worker} = start_run(context.manager, job)
    failure = %{class: :model_drift, detail: "configured model changed"}
    inject(:reject_terminal)
    send(context.manager, {:run_complete, run.id, {:preflight_skip, failure}})
    :sys.get_state(context.manager)
    assert CronStore.get_preflight_notice_state(job.id) == nil
    assert_no_effects(context, job, run)

    inject(nil)
    tick(context.manager)
    assert CronStore.get_run(run.id).status == :failed
    assert CronStore.get_preflight_notice_state(job.id).occurrences == 1
    assert_receive %Event{type: :cron_run_completed}, 1_000
    assert_receive {:delivered, %{status: :failed}}, 1_000
    refute_received {:submitted, _, _, _}
  end

  test "normal success confirms persistence before terminal effects", context do
    job = add_job(context)
    {run, worker} = start_run(context.manager, job)
    send(worker, {:finish, {:ok, "done"}})
    assert_receive {:terminal_write, run_id}, 1_000
    assert run_id == run.id
    assert :sys.get_state(context.manager).pending_run_results == %{}
    assert CronStore.get_run(run.id).status == :completed
    assert CronJob.last_status(CronStore.get_job(job.id)) == :completed
    assert_receive %Event{type: :cron_run_completed}, 1_000
    assert_receive {:delivered, %{status: :completed}}, 1_000
    assert File.read!(job.memory_file) =~ run.id
    refute_received {:submitted, _, _, _}
  end

  defp add_job(context, attrs \\ []) do
    params = Map.merge(%{
      name: "Terminal persistence", schedule: "0 0 1 1 *", agent_id: "terminal_test",
      session_key: "agent:terminal_test:main", prompt: "controlled work",
      memory_file: Path.join(context.directory, "memory.md"), deliver_to: "telegram:42"
    }, Map.new(attrs))
    {:ok, job} = GenServer.call(context.manager, {:add, params})
    job
  end

  defp start_run(manager, job) do
    {:ok, run} = CronStore.claim_scheduled_run(job, job.next_run_at_ms, "router_#{job.id}")
    send(manager, {:submit_claimed_run, job.id, run.id})
    job_id = job.id
    run_id = run.id
    assert_receive {:submitted, ^job_id, ^run_id, worker}, 1_000
    :sys.get_state(manager)
    {run, worker}
  end

  defp assert_no_effects(context, job, run) do
    assert CronStore.get_job(job.id) == job
    assert :sys.get_state(context.manager).jobs[job.id] == job
    assert CronStore.get_run(CronStore.retry_run_id(run.id, 1)) == nil
    refute File.exists?(job.memory_file)
    refute_received %Event{type: :cron_run_completed}
    refute_received %Event{type: :heartbeat_alert}
    refute_received %Event{type: :heartbeat_suppressed}
    refute_received {:delivered, _}
  end

  defp inject(failure), do: :sys.replace_state(Store, &put_in(&1.backend_state.failure, failure))

  defp tick(manager) do
    GenServer.cast(manager, :tick)
    :sys.get_state(manager)
  end

  defp terminal_writes(data, run_id) do
    [{_, count}] = :ets.lookup(data, {:terminal_writes, run_id})
    count
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
