defmodule LemonAutomation.CronManagerPersistenceTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronJob, CronManager, CronRun, CronStore}
  alias LemonCore.Bus

  # Delegates to the real backend unless `refuse` names an error for the
  # operation, so a test can fail exactly the writes it is about.
  defmodule FaultBackend do
    @moduledoc false
    @behaviour LemonCore.Store.Backend

    @impl true
    def init(_opts), do: {:ok, %{}}
    @impl true
    def put(s, table, key, value),
      do: guard(s, {:put, table, key, value}, &s.inner.put(&1, table, key, value))

    @impl true
    def put_new(s, table, key, value),
      do: guard(s, {:put_new, table, key, value}, &s.inner.put_new(&1, table, key, value))

    @impl true
    def get(s, table, key), do: guard(s, {:get, table, key}, &s.inner.get(&1, table, key))
    @impl true
    def delete(s, table, key),
      do: guard(s, {:delete, table, key}, &s.inner.delete(&1, table, key))

    @impl true
    def list(s, table), do: guard(s, {:list, table}, &s.inner.list(&1, table))

    defp guard(s, op, fun) do
      case s.refuse.(op) do
        nil ->
          case fun.(s.inner_state) do
            {:ok, inner} -> {:ok, %{s | inner_state: inner}}
            {:ok, value, inner} -> {:ok, value, %{s | inner_state: inner}}
            other -> other
          end

        reason ->
          {:error, reason}
      end
    end
  end

  setup do
    token = System.unique_integer([:positive, :monotonic])

    {:ok, job} =
      CronManager.add(%{
        name: "persist-#{token}",
        schedule: "0 9 * * *",
        agent_id: "persist_#{token}",
        session_key: "agent:persist_#{token}:main",
        prompt: "run",
        enabled: false
      })

    Bus.subscribe("cron")

    on_exit(fn ->
      Bus.unsubscribe("cron")
      for run <- CronStore.list_runs(job.id), do: CronStore.delete_run(run.id)
      _ = CronManager.remove(job.id)
    end)

    {:ok, job: job, token: token}
  end

  test "a failed store write is neither announced nor applied in memory", %{
    job: job,
    token: token
  } do
    with_store_faults(fn _op -> :sqlite_busy end, fn ->
      assert {:error, :store_unavailable} =
               CronManager.add(%{
                 name: "refused-#{token}",
                 schedule: "0 9 * * *",
                 agent_id: "persist_#{token}",
                 session_key: "agent:persist_#{token}:main",
                 prompt: "run"
               })

      assert {:error, :store_unavailable} = CronManager.update(job.id, %{name: "renamed"})
      assert {:error, :store_unavailable} = CronManager.refresh_captured_model(job.id)
    end)

    refute_receive %LemonCore.Event{type: :cron_job_created}, 100
    refute_receive %LemonCore.Event{type: :cron_job_updated}, 0

    jobs = CronManager.list()
    refute Enum.any?(jobs, &(&1.name == "refused-#{token}"))
    assert %CronJob{name: name} = Enum.find(jobs, &(&1.id == job.id))
    assert name == job.name
  end

  test "a write that may have landed is reported as outcome-unknown, not as failed", %{job: job} do
    with_store_faults(
      fn
        {:put, :cron_jobs, _key, _value} -> :outcome_unknown
        _ -> nil
      end,
      fn -> assert {:error, :outcome_unknown} = CronManager.update(job.id, %{name: "renamed"}) end
    )

    refute_receive %LemonCore.Event{type: :cron_job_updated}, 100
    assert Enum.find(CronManager.list(), &(&1.id == job.id)).name == job.name
  end

  test "a failed delete keeps the job and announces no deletion", %{job: job} do
    with_store_faults(
      fn
        {:delete, :cron_jobs, _key} -> :sqlite_busy
        _ -> nil
      end,
      fn -> assert {:error, :store_unavailable} = CronManager.remove(job.id) end
    )

    refute_receive %LemonCore.Event{type: :cron_job_deleted}, 100
    assert Enum.any?(CronManager.list(), &(&1.id == job.id))
    assert %CronJob{} = CronStore.get_job(job.id)
  end

  test "a run whose start write fails is never announced or submitted", %{job: job} do
    with_store_faults(
      fn
        {:put, :cron_runs, _key, _value} -> :sqlite_busy
        _ -> nil
      end,
      fn -> assert {:error, :store_unavailable} = CronManager.run_now(job.id) end
    )

    refute_receive %LemonCore.Event{type: :cron_run_started}, 100
    assert CronStore.list_runs(job.id) == []
  end

  test "an unpersisted terminal is not announced and is left for recovery", %{job: job} do
    completed = start_run(job)
    aborted = start_run(job)

    with_store_faults(
      fn
        {:put, :cron_runs, _key, %{status: status}} when status != :running -> :sqlite_busy
        _ -> nil
      end,
      fn ->
        send(CronManager, {:run_complete, completed.id, {:ok, "done"}})
        _ = :sys.get_state(CronManager)

        # The operator abort reached the run, but its terminal row did not.
        assert {:error, :outcome_unknown} = CronManager.abort_run(aborted.id)
      end
    )

    refute_receive %LemonCore.Event{type: :cron_run_completed}, 100

    assert %CronRun{status: :running} = CronStore.get_run(completed.id)
    assert %CronRun{status: :running, meta: meta} = CronStore.get_run(aborted.id)
    assert meta[:abort_requested] == true

    # Once the store accepts the write, the same terminal completes and is
    # announced exactly as it would have been.
    send(CronManager, {:run_complete, completed.id, {:ok, "done"}})

    completed_id = completed.id

    assert_receive %LemonCore.Event{
                     type: :cron_run_completed,
                     payload: %{cron_run_id: ^completed_id, status: :completed}
                   },
                   1_000

    assert %CronRun{status: :completed} = CronStore.get_run(completed.id)
  end

  defp start_run(job) do
    run = job.id |> CronRun.new(:manual) |> CronRun.start(nil)
    :ok = CronStore.put_run(run)
    run
  end

  defp with_store_faults(refuse, fun) do
    :sys.replace_state(LemonCore.Store, fn state ->
      %{
        state
        | backend: FaultBackend,
          backend_state: %{inner: state.backend, inner_state: state.backend_state, refuse: refuse}
      }
    end)

    try do
      fun.()
    after
      :sys.replace_state(LemonCore.Store, fn %{backend_state: faulted} = state ->
        %{state | backend: faulted.inner, backend_state: faulted.inner_state}
      end)
    end
  end
end
