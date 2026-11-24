defmodule LemonAutomation.CronManagerRetryTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}

  defmodule RetrySubmitter do
    def submit(job, run, _opts) do
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:cron_submit, self(), job.id, run.id, run.triggered_by, run.meta})

      case run.triggered_by do
        :schedule ->
          run_id = run.id

          receive do
            {:release_cron_submit, ^run_id} -> {:error, "scheduled failure"}
          after
            5_000 -> {:error, "scheduled failure"}
          end

        :manual ->
          {:error, "manual failure"}

        :retry ->
          {:ok, "retry success"}
      end
    end
  end

  setup do
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)
    Application.put_env(:lemon_automation, :cron_run_submitter, RetrySubmitter)
    :persistent_term.put({RetrySubmitter, :test_pid}, self())
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "retry-test-#{token}",
        schedule: "* * * * *",
        agent_id: "cron_retry_#{token}",
        session_key: "agent:cron_retry_#{token}:main",
        prompt: "retry me",
        timezone: "UTC",
        max_retries: 1,
        retry_backoff_ms: 0
      })

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      else
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      end

      :persistent_term.erase({RetrySubmitter, :test_pid})

      for run <- CronStore.list_runs(job.id, limit: 100) do
        CronStore.delete_run(run.id)
      end

      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job}
  end

  test "cron policy keeps a fixed delay and counts retries after the initial run" do
    for retries <- [0, 1, 3] do
      policy =
        LemonCore.Retry.policy(
          max_attempts: retries + 1,
          base_delay_ms: 30_000,
          max_delay_ms: 30_000,
          jitter: :none
        )

      for attempt <- 0..3 do
        assert LemonCore.Retry.retry_allowed?(attempt, policy) == attempt < retries
        expected = if attempt < retries, do: 30_000, else: :give_up
        assert LemonCore.Retry.delay(policy, attempt) == expected
      end
    end
  end

  test "failed scheduled runs retry after the configured backoff", %{job: job} do
    %CronJob{} = job
    replace_job_state(%{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000})

    CronManager.tick()

    assert_receive {:cron_submit, submitter_pid, job_id, first_run_id, :schedule, first_meta},
                   5_000

    assert job_id == job.id
    assert first_meta.retry_attempt == 0
    assert first_meta.retry_root_id == first_run_id

    send(submitter_pid, {:release_cron_submit, first_run_id})

    assert await(fn ->
             Enum.any?(CronStore.list_audit_events(job_id: job.id, action: :retry_scheduled), fn
               event -> event.run_id == first_run_id
             end)
           end)

    assert_receive {:cron_submit, _submitter_pid, ^job_id, retry_run_id, :retry, retry_meta},
                   5_000

    assert retry_run_id != first_run_id
    assert retry_meta.retry_attempt == 1
    assert retry_meta.retry_of == first_run_id
    assert retry_meta.retry_root_id == first_run_id
    assert retry_meta.source_triggered_by == :schedule

    assert await(fn ->
             runs = CronStore.list_runs(job.id, limit: 10)

             Enum.any?(runs, &match?(%CronRun{id: ^first_run_id, status: :failed}, &1)) and
               Enum.any?(runs, &match?(%CronRun{id: ^retry_run_id, status: :completed}, &1))
           end)
  end

  test "numeric fields are bounded and type-checked on add and update", %{job: job} do
    base = %{
      name: "bounds",
      schedule: "* * * * *",
      agent_id: "cron_bounds",
      session_key: "agent:cron_bounds:main",
      prompt: "bounded"
    }

    assert {:error, {:invalid_target, reason}} =
             CronManager.add(Map.merge(base, %{max_retries: 1, retry_backoff_ms: 5_000_000_000}))

    assert reason =~ "retry_backoff_ms"

    for {field, value} <- [
          jitter_sec: "3",
          jitter_sec: 1.5,
          jitter_sec: 86_401,
          timeout_ms: 0,
          max_retries: 11,
          retry_backoff_ms: -1
        ] do
      assert {:error, {:invalid_target, _}} = CronManager.add(Map.put(base, field, value))
      assert {:error, {:invalid_target, _}} = CronManager.update(job.id, %{field => value})
    end

    assert {:ok, %CronJob{jitter_sec: 86_400, retry_backoff_ms: 86_400_000}} =
             CronManager.update(job.id, %{jitter_sec: 86_400, retry_backoff_ms: 86_400_000})

    refute Enum.any?(CronManager.list(), &(&1.name == "bounds"))
  end

  test "a failed run with the maximum backoff arms a bounded retry timer", %{job: job} do
    {:ok, job} = CronManager.update(job.id, %{retry_backoff_ms: 86_400_000})
    replace_job_state(%{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000})
    CronManager.tick()

    assert_receive {:cron_submit, submitter_pid, _job_id, first_run_id, :schedule, _meta}, 5_000
    send(submitter_pid, {:release_cron_submit, first_run_id})

    assert await(fn ->
             match?(%CronRun{status: :failed}, CronStore.get_run(first_run_id))
           end)

    timer = :sys.get_state(CronManager).retry_timer
    assert is_reference(timer)
    remaining = Process.read_timer(timer)
    assert is_integer(remaining) and remaining <= 300_000

    assert CronStore.get_run(first_run_id).meta.retry_due_at_ms >
             LemonCore.Clock.now_ms() + 300_000
  end

  test "manual runs do not retry by default", %{job: job} do
    assert {:ok, %CronRun{id: run_id, triggered_by: :manual}} = CronManager.run_now(job.id)

    assert_receive {:cron_submit, _submitter_pid, job_id, ^run_id, :manual, _meta}, 5_000
    assert job_id == job.id
    refute_receive {:cron_submit, _submitter_pid, ^job_id, _retry_run_id, :retry, _meta}, 150

    assert await(fn ->
             match?(%CronRun{id: ^run_id, status: :failed}, CronStore.get_run(run_id))
           end)
  end

  test "pending retry survives manager restart and keeps one deterministic attempt", %{job: job} do
    manager = private_manager_name()
    start_supervised!({CronManager, name: manager})

    job = %{job | retry_backoff_ms: 250}
    replace_job_state(%{job | next_run_at_ms: LemonCore.Clock.now_ms() - 1_000}, manager)

    GenServer.cast(manager, :tick)

    assert_receive {:cron_submit, submitter_pid, _job_id, first_run_id, :schedule, _meta}, 5_000
    send(submitter_pid, {:release_cron_submit, first_run_id})

    assert await(fn ->
             run = CronStore.get_run(first_run_id)
             is_integer(run && meta(run, :retry_due_at_ms))
           end)

    old_pid = Process.whereis(manager)
    Process.exit(old_pid, :kill)

    assert await(fn ->
             pid = Process.whereis(manager)
             is_pid(pid) and pid != old_pid
           end)

    assert_receive {:cron_submit, _pid, _job_id, retry_run_id, :retry, retry_meta}, 5_000

    assert retry_run_id == CronStore.retry_run_id(first_run_id, 1)
    assert retry_meta.retry_attempt == 1
    refute_receive {:cron_submit, _pid, _job_id, ^retry_run_id, :retry, _meta}, 500

    attempts =
      CronStore.list_runs(job.id, limit: 20)
      |> Enum.filter(&(meta(&1, :retry_root_id) == first_run_id))
      |> Enum.map(&meta(&1, :retry_attempt))

    assert Enum.sort(attempts) == [0, 1]
  end

  test "stale recovery retains ownership and retries only after durable failure", %{job: job} do
    manager = private_manager_name()
    start_supervised!({CronManager, name: manager})

    job = %{job | timeout_ms: 1, retry_backoff_ms: 0, max_retries: 1}
    replace_job_state(job, manager)

    root_id = "cron_stale_retry_#{System.unique_integer([:positive])}"

    stale =
      job.id
      |> CronRun.new(:schedule)
      |> Map.put(:id, root_id)
      |> Map.put(:meta, %{
        agent_id: job.agent_id,
        session_key: job.session_key,
        job_name: job.name,
        retry_attempt: 0,
        retry_root_id: root_id,
        submission_started: true
      })
      |> CronRun.start("router_#{root_id}")
      |> Map.put(:started_at_ms, LemonCore.Clock.now_ms() - 1_000)

    CronStore.put_run(stale)
    LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(job.session_key))

    old_pid = Process.whereis(manager)
    Process.exit(old_pid, :kill)

    assert await(fn ->
             pid = Process.whereis(manager)
             is_pid(pid) and pid != old_pid
           end)

    assert await(fn ->
             match?(
               %CronRun{status: :running, meta: %{outcome_unknown: true}},
               CronStore.get_run(root_id)
             )
           end)

    refute_receive {:cron_submit, _, _, _, :retry, _}, 100
    assert CronStore.pending_retries() |> Enum.all?(&(&1.id != root_id))

    :ok =
      LemonCore.RunStore.finalize(stale.run_id, %{
        session_key: job.session_key,
        completed: %{ok: false, error: "confirmed coding failure"}
      })

    GenServer.cast(manager, :tick)
    assert_receive %LemonCore.Event{type: :run_completed, meta: %{cron_run_id: ^root_id}}, 5_000

    assert_receive {:cron_submit, _pid, _job_id, retry_run_id, :retry, retry_meta}, 5_000
    assert retry_run_id == CronStore.retry_run_id(root_id, 1)
    assert retry_meta.retry_root_id == root_id

    send(manager, {:run_complete, root_id, {:ok, "late"}})
    # A synchronous call returns only after the manager handled the late completion message.
    _ = :sys.get_state(manager)

    assert CronStore.get_run(root_id).status == :failed
    assert length(CronStore.list_audit_events(run_id: root_id, action: :run_reconciled)) == 1
    refute_receive {:cron_submit, _pid, _job_id, ^retry_run_id, :retry, _meta}, 300

    LemonCore.Bus.unsubscribe(LemonCore.Bus.session_topic(job.session_key))
    LemonCore.Store.delete(:runs, stale.run_id)
  end

  defp replace_job_state(job, manager \\ CronManager) do
    CronStore.put_job(job)

    :sys.replace_state(manager, fn state ->
      put_in(state.jobs[job.id], job)
    end)
  end

  defp private_manager_name do
    String.to_atom("cron_retry_manager_#{System.unique_integer([:positive, :monotonic])}")
  end

  defp meta(run, key) do
    Map.get(run.meta || %{}, key) || Map.get(run.meta || %{}, Atom.to_string(key))
  end

  defp await(fun, attempts \\ 500)
  defp await(_fun, 0), do: false

  defp await(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      await(fun, attempts - 1)
    end
  end
end
