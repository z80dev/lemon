defmodule LemonRouter.TestExecutor do
  @moduledoc """
  A test-controlled native executor for `LemonRouter.RunProcess`.

  `start_run/3` starts a runner process and reports
  `{:test_executor_started, run_id, runner, sink}` to the owner: the command's
  `meta[:test_pid]` when it is a pid, else the pid in
  `Application.get_env(:lemon_router, :test_executor_owner)`. The test then
  drives the run through the runner with `started/2`, `delta/2`, `action/2`,
  `complete/2` and `crash/2`; each sends the matching executor message to the
  run's sink in order. `cancel/1`, `steer/2` and `redirect/2` report
  `{:test_executor_cancel, run_id, caller}`, `{:test_executor_steer, run_id,
  text, caller}` and `{:test_executor_redirect, run_id, text, caller}` to the
  owner, `caller` being the process that invoked the callback. A cancelled runner completes with
  `ok: false` and exits unless the command's `meta[:test_executor_hold_cancel]`
  is true; steer returns `meta[:test_executor_steer_result]` (default `:ok`)
  and redirect `meta[:test_executor_redirect_result]` (default `:ok`).
  """

  @behaviour CodingAgent.Executor.Behaviour

  alias CodingAgent.Executor.Event

  @impl true
  def start_run(%LemonCore.ExecutionCommand{} = command, opts, sink) do
    owner = owner(command)
    ref = make_ref()
    runner = spawn(fn -> runner(command, opts, sink, ref, owner) end)
    if is_pid(owner), do: send(owner, {:test_executor_started, command.run_id, runner, sink})
    {:ok, ref, %{runner_pid: runner, run_id: command.run_id, owner: owner, command: command}}
  end

  @impl true
  def cancel(%{runner_pid: runner, run_id: run_id, owner: owner}) do
    if is_pid(owner), do: send(owner, {:test_executor_cancel, run_id, self()})
    send(runner, :cancel)
    :ok
  end

  @impl true
  def steer(%{run_id: run_id, owner: owner, command: command}, text) do
    if is_pid(owner), do: send(owner, {:test_executor_steer, run_id, text, self()})
    Map.get(command.meta, :test_executor_steer_result, :ok)
  end

  @impl true
  def redirect(%{run_id: run_id, owner: owner, command: command}, text) do
    if is_pid(owner), do: send(owner, {:test_executor_redirect, run_id, text, self()})
    Map.get(command.meta, :test_executor_redirect_result, :ok)
  end

  @doc "Send the executor's `:started` event."
  def started(runner, resume \\ nil),
    do: send(runner, {:event, Event.started(%{engine: "lemon", resume: resume})})

  @doc "Stream answer text."
  def delta(runner, text), do: send(runner, {:delta, text})

  @doc "Send an action event; `fields` needs `:id`, `:kind`, `:title`, `:phase`."
  def action(runner, fields) do
    action = Event.action(Map.take(fields, [:id, :kind, :title, :detail]))

    send(
      runner,
      {:event,
       Event.action_event(%{
         engine: "lemon",
         action: action,
         phase: Map.fetch!(fields, :phase),
         ok: Map.get(fields, :ok),
         message: Map.get(fields, :message),
         level: Map.get(fields, :level)
       })}
    )
  end

  @doc "Complete the run (default `ok: true`) and exit the runner."
  def complete(runner, fields \\ %{}) do
    send(runner, {:complete, Event.completed(Map.merge(%{engine: "lemon", ok: true}, fields))})
  end

  @doc "Exit the runner without a completion."
  def crash(runner, reason \\ :boom), do: send(runner, {:crash, reason})

  defp owner(%LemonCore.ExecutionCommand{meta: meta}) do
    case Map.get(meta || %{}, :test_pid) do
      pid when is_pid(pid) -> pid
      _ -> Application.get_env(:lemon_router, :test_executor_owner)
    end
  end

  defp runner(command, opts, sink, ref, owner) do
    receive do
      {:event, event} ->
        send(sink, {:engine_event, ref, event})
        runner(command, opts, sink, ref, owner)

      {:delta, text} ->
        send(sink, {:engine_delta, ref, text})
        runner(command, opts, sink, ref, owner)

      {:complete, event} ->
        send(sink, {:engine_event, ref, event})

      {:crash, reason} ->
        exit(reason)

      :cancel ->
        if Map.get(command.meta, :test_executor_hold_cancel) == true do
          runner(command, opts, sink, ref, owner)
        else
          completed = Event.completed(%{engine: "lemon", ok: false, error: :user_requested})
          send(sink, {:engine_event, ref, completed})
        end

      {:opts, from} ->
        send(from, {:test_executor_opts, opts})
        runner(command, opts, sink, ref, owner)
    end
  end
end
