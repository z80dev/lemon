defmodule LemonAutomation.CronManagerDeadlineTest do
  use ExUnit.Case, async: false

  alias LemonAutomation.{CronManager, CronStore}

  defmodule Clock do
    def now_ms, do: Agent.get(__MODULE__, & &1.now)
  end

  defmodule Submitter do
    def submit(job, _run, _opts) do
      send(Agent.get(Clock, & &1.owner), {:deadline_fired, job.id})
      {:ok, "done"}
    end
  end

  setup do
    now = div(System.system_time(:millisecond), 60_000) * 60_000 + 59_900
    owner = self()
    previous = Application.get_env(:lemon_automation, :cron_run_submitter)

    start_supervised!(%{
      id: Clock,
      start: {Agent, :start_link, [fn -> %{now: now, owner: owner} end, [name: Clock]]}
    })

    Application.put_env(:lemon_automation, :cron_run_submitter, Submitter)
    name = :"cron-deadline-#{System.unique_integer([:positive])}"
    pid = start_supervised!({CronManager, name: name, clock: Clock})

    on_exit(fn ->
      if previous do
        Application.put_env(:lemon_automation, :cron_run_submitter, previous)
      else
        Application.delete_env(:lemon_automation, :cron_run_submitter)
      end
    end)

    %{pid: pid, now: now}
  end

  test "earliest timer fires within one second using the injected clock", %{pid: pid} do
    job = add_job(pid)
    Agent.update(Clock, &%{&1 | now: job.next_run_at_ms})
    assert_receive {:deadline_fired, id}, 1_100
    assert id == job.id
    state = :sys.get_state(pid)
    assert state.jobs[job.id].next_run_at_ms > job.next_run_at_ms
  end

  test "add, disable, reschedule and remove replace the earliest timer", %{pid: pid} do
    job = add_job(pid)
    {first_timer, first_token} = :sys.get_state(pid).schedule_timer
    assert {:ok, _} = GenServer.call(pid, {:update, job.id, %{enabled: false}})
    assert Process.read_timer(first_timer) == false
    # Other persisted jobs may have their own deadline; the disabled job cannot fire.
    send(pid, {:scheduled_tick, first_token})

    assert {:ok, _} =
             GenServer.call(pid, {:update, job.id, %{enabled: true, schedule: "0 * * * *"}})

    {changed_timer, _} = :sys.get_state(pid).schedule_timer
    refute changed_timer == first_timer
    assert :ok = GenServer.call(pid, {:remove, job.id})
    assert Process.read_timer(changed_timer) == false
    refute Map.has_key?(:sys.get_state(pid).jobs, job.id)
    refute_received {:deadline_fired, _}
  end

  defp add_job(pid) do
    {:ok, job} =
      GenServer.call(
        pid,
        {:add,
         %{
           name: "deadline-regression",
           schedule: "* * * * *",
           agent_id: "deadline-regression",
           session_key: "agent:deadline-regression:main",
           prompt: "test",
           deliver_to: "none"
         }}
      )

    on_exit(fn ->
      CronStore.delete_job(job.id)
      for run <- CronStore.list_runs(job.id, limit: 100), do: CronStore.delete_run(run.id)
    end)

    job
  end
end
