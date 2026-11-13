defmodule CodingAgent.Tools.Task.Speculation do
  @moduledoc """
  Speculative launch of `task` batch items while the call is still streaming.

  The task tool's `AgentTool.on_stream` callback runs in the agent loop process.
  For a `run` call with `tasks[]`, it reads items with `StreamItems` as their
  objects close and launches each one through dispatch's own path: the same
  child parameters (`CodingAgent.Tools.Task.batch_child/2` over the top-level
  members already complete, after the loop's argument preparation), validation,
  depth, parent restriction, budget/policy check and `Execution.run/6`.

  Only read-only launches start early: a read-only persona, or an effective
  tool policy (after parent restriction) allowing nothing beyond the read-only
  persona tools. Items inherit top-level options, and one written after `tasks`
  could otherwise isolate or narrow a child (`worktree`, `tool_policy`, `cwd`)
  that already started editing. A read-only child cannot write, so a later
  option at most changes what it reads, and the mismatch below cancels it.
  Every other item, including `worktree` items, launches at dispatch. Launches
  are recorded here, keyed by the caller's task owner and tool call id, and
  monitored through the loop process.

  When the call executes, `adopt/3` returns the receipts of launches whose child
  parameters equal the finished call's at the same index, and dispatch starts the
  rest. Any difference cancels every launch of the call. A call that never
  adopts — invalid, blocked, discarded by a retry or redirect, or an aborted turn
  — is cancelled when the loop settles it, when `execute` returns, or when the
  loop process exits; an aborted parent signal also cancels the children
  directly. Cancelled launches are terminalized as cancelled, their followups
  are suppressed and their parent budget reservations are released.

  Speculation runs only with `[runtime.task].speculative_launch` and only for a
  `task` tool that dispatch would run without review: approval wrappers,
  extension tool hooks and plan mode remove the callback. Before adoption a
  child's progress reaches the parent session directly, not the call's
  `on_update`.
  """
  use GenServer

  require Logger

  alias CodingAgent.{BudgetEnforcer, Subagents, TaskStore}
  alias CodingAgent.Tools.Task, as: TaskTool
  alias CodingAgent.Tools.Task.{Control, Execution, Params, StreamItems}
  alias LemonAgent.AbortSignal
  alias LemonAgent.Types.AgentToolResult

  @max_items 32

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The task tool's stream callback; runs in the agent loop process."
  @spec on_stream(LemonAgent.Types.AgentTool.stream_event(), String.t(), keyword()) :: :ok
  def on_stream({:args, %{id: id, json: json} = args}, cwd, opts)
      when is_binary(id) and is_binary(json) do
    key = key(id, opts)
    call = Process.get({__MODULE__, key}) || begin(cwd, opts)
    Process.put({__MODULE__, key}, advance(call, key, json, args, cwd))
    :ok
  end

  def on_stream({:settle, id}, _cwd, opts) when is_binary(id) do
    key = key(id, opts)
    Process.delete({__MODULE__, key})
    key |> take() |> cancel_all()
  end

  def on_stream(_event, _cwd, _opts), do: :ok

  @doc """
  Hands dispatch the receipts of `call_id`'s speculative launches, by item index,
  when each launch's child parameters equal `children` at that index; otherwise
  cancels them all and returns an empty map.
  """
  @spec adopt(String.t(), keyword(), [map()]) :: %{non_neg_integer() => AgentToolResult.t()}
  def adopt(call_id, opts, children) when is_binary(call_id) do
    launches = take(key(call_id, opts))

    if Enum.all?(launches, fn {index, launch} -> Enum.at(children, index) == launch.child end) do
      Map.new(launches, fn {index, launch} -> {index, launch.result} end)
    else
      cancel_all(launches)
      %{}
    end
  end

  def adopt(_call_id, _opts, _children), do: %{}

  @doc "Cancels every speculative launch of `call_id` that dispatch did not adopt."
  @spec discard(String.t() | nil, keyword()) :: :ok
  def discard(call_id, opts) when is_binary(call_id),
    do: call_id |> key(opts) |> take() |> cancel_all()

  def discard(_call_id, _opts), do: :ok

  # ── Loop process ─────────────────────────────────────────────────────────

  defp begin(cwd, opts) do
    opts = Params.with_settings(cwd, opts)

    active =
      Params.task_settings(cwd, opts).speculative_launch == true and
        Params.check_spawn_depth(cwd, opts) == :ok and is_pid(Process.whereis(__MODULE__))

    %{reader: StreamItems.new(), opts: opts, names: MapSet.new(), active: active}
  end

  defp advance(%{active: false} = call, _key, _json, _args, _cwd), do: call

  defp advance(call, key, json, args, cwd) do
    {reader, items} = StreamItems.feed(call.reader, json)
    call = %{call | reader: reader, active: not StreamItems.invalid?(reader)}
    Enum.reduce(items, call, &launch(&1, &2, key, args, cwd))
  end

  # Anything that would fail the whole finished call stops speculation; its
  # launches are then cancelled by dispatch or settlement.
  defp launch(_item, %{active: false} = call, _key, _args, _cwd), do: call

  defp launch({index, item, fields}, call, key, args, cwd) do
    with :ok <- launchable(index, item, fields, args.signal),
         {:ok, %{"tasks" => [task]} = prepared} when is_map(task) <-
           args.prepare.(Map.put(fields, "tasks", [item])),
         child = TaskTool.batch_child(Map.drop(prepared, ["tasks", "action"]), task),
         {:ok, validated} <- Params.validate_run_params(child, cwd, call.opts),
         {:ok, names} <- claim_name(call.names, validated.name) do
      unless validated.worktree, do: start(index, child, validated, key, args, cwd, call.opts)
      %{call | names: names}
    else
      _ -> %{call | active: false}
    end
  end

  defp launchable(index, item, fields, signal) do
    if index < @max_items and Params.normalize_action(fields["action"]) == "run" and
         not Map.has_key?(item, "context") and not AbortSignal.aborted?(signal),
       do: :ok,
       else: :stop
  end

  defp claim_name(names, nil), do: {:ok, names}

  defp claim_name(names, name),
    do: if(MapSet.member?(names, name), do: :duplicate, else: {:ok, MapSet.put(names, name)})

  # Per-item refusals (policy, budget, launch failure) and write-capable
  # children are left for dispatch; the item simply is not adopted.
  defp start(index, child, validated, key, %{id: id, signal: signal}, cwd, opts) do
    with {:ok, validated} <- Params.restrict_to_parent(validated, cwd, opts),
         true <- read_only?(validated),
         :ok <- Params.check_budget_and_policy(validated, opts),
         %AgentToolResult{details: %{task_id: task_id} = details} = result <-
           Execution.run(id, %{validated | async: true}, signal, nil, cwd, opts) do
      launch = %{
        child: child,
        result: result,
        task_id: task_id,
        run_id: details[:run_id],
        opts: opts
      }

      if register(key, index, launch) != :ok, do: cancel(launch)
    end

    :ok
  end

  defp read_only?(validated),
    do:
      Subagents.read_only?(validated.persona) or
        Subagents.read_only_policy?(validated.tool_policy)

  # ── Registry ─────────────────────────────────────────────────────────────

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:register, key, index, launch}, {owner, _tag}, calls) do
    call =
      Map.get_lazy(calls, key, fn -> %{monitor: Process.monitor(owner), launches: %{}} end)

    {:reply, :ok, Map.put(calls, key, %{call | launches: Map.put(call.launches, index, launch)})}
  end

  def handle_call({:take, key}, _from, calls) do
    case Map.pop(calls, key) do
      {nil, calls} ->
        {:reply, %{}, calls}

      {call, calls} ->
        Process.demonitor(call.monitor, [:flush])
        {:reply, call.launches, calls}
    end
  end

  # The loop process died before settling its calls.
  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, calls) do
    {orphaned, calls} = Map.split_with(calls, fn {_key, call} -> call.monitor == monitor end)
    Enum.each(orphaned, fn {_key, call} -> cancel_all(call.launches) end)
    {:noreply, calls}
  end

  defp register(key, index, launch) do
    GenServer.call(__MODULE__, {:register, key, index, launch})
  catch
    :exit, _reason -> :error
  end

  defp take(key) do
    GenServer.call(__MODULE__, {:take, key})
  catch
    :exit, _reason -> %{}
  end

  defp key(call_id, opts), do: {Control.owner(opts), call_id}

  defp cancel_all(launches), do: Enum.each(launches, fn {_index, launch} -> cancel(launch) end)

  # The child never became part of a dispatched call: stop it without a
  # followup and release its parent budget reservation now; its worker records
  # the cancelled terminal state.
  defp cancel(%{task_id: task_id, run_id: run_id, opts: opts}) do
    TaskStore.suppress_auto_followup(task_id)
    _ = Control.command(task_id, "cancel", nil, opts)
    if is_binary(run_id), do: BudgetEnforcer.on_run_complete(run_id, %{error: "Task aborted"})
    :ok
  catch
    kind, _reason ->
      Logger.warning("Speculative task cancellation failed: #{inspect(kind)}")
      :ok
  end
end
