defmodule LemonRouter.SessionCoordinator do
  @moduledoc """
  Router-owned owner of per-conversation queue semantics.

  Queue mode behavior is implemented here so gateway remains execution-only.
  """

  use GenServer

  require Logger

  alias LemonGateway.ExecutionRequest

  @followup_debounce_ms 500

  @type submission :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          required(:queue_mode) => atom(),
          required(:execution_request) => ExecutionRequest.t(),
          optional(:run_supervisor) => module() | pid() | atom(),
          optional(:run_process_module) => module(),
          optional(:run_process_opts) => map(),
          optional(:meta) => map()
        }

  @spec submit(term(), submission(), keyword()) :: :ok | {:error, term()}
  def submit(conversation_key, submission, opts \\ []) when is_map(submission) do
    with {:ok, pid} <- ensure_coordinator(conversation_key, opts) do
      GenServer.call(pid, {:submit, submission}, 15_000)
    end
  end

  @spec cancel(binary() | term(), term()) :: :ok
  def cancel(conversation_or_session, reason \\ :user_requested)
  def cancel({_, _} = conversation_key, reason), do: cancel_conversation(conversation_key, reason)

  def cancel({_, _, _} = conversation_key, reason),
    do: cancel_conversation(conversation_key, reason)

  def cancel(session_key, reason) when is_binary(session_key) do
    case active_run_for_session(session_key) do
      {:ok, run_id} -> LemonRouter.RunProcess.abort(run_id, reason)
      :none -> :ok
    end

    :ok
  end

  @spec active_run(term()) :: {:ok, binary()} | :none
  def active_run(conversation_key) do
    with {:ok, pid} <- whereis(conversation_key) do
      GenServer.call(pid, :active_run)
    else
      _ -> :none
    end
  end

  def start_link(opts) do
    key = Keyword.fetch!(opts, :conversation_key)
    name = {:via, Registry, {LemonRouter.ConversationRegistry, key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       conversation_key: Keyword.fetch!(opts, :conversation_key),
       active: nil,
       queue: [],
       last_followup_at_ms: nil,
       pending_steers: %{}
     }}
  end

  @impl true
  def handle_call(:active_run, _from, state) do
    reply =
      case state.active do
        %{run_id: run_id} when is_binary(run_id) -> {:ok, run_id}
        _ -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:submit, submission}, _from, state) do
    submission = normalize_submission(submission)
    mode = normalize_queue_mode(submission.queue_mode)

    state =
      submission
      |> maybe_promote_auto_followup(mode, state)
      |> enqueue_by_mode(state)

    {state, start_result} = maybe_start_next(state, return_result?: true)

    case start_result do
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    state = maybe_cancel_active(state, reason)
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, mon_ref, :process, pid, _reason},
        %{active: %{pid: pid, mon_ref: mon_ref}} = state
      ) do
    state =
      state
      |> clear_active_session_registry()
      |> flush_pending_steers_for_active()
      |> Map.put(:active, nil)

    send(self(), :maybe_start_next)
    {:noreply, state}
  end

  def handle_info({:steer_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, clear_pending_steer(state, request.run_id)}
  end

  def handle_info({:steer_backlog_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, clear_pending_steer(state, request.run_id)}
  end

  def handle_info({:steer_rejected, %ExecutionRequest{} = request}, state) do
    state = fallback_pending_steer(state, request.run_id)
    send(self(), :maybe_start_next)
    {:noreply, state}
  end

  def handle_info({:steer_backlog_rejected, %ExecutionRequest{} = request}, state) do
    state = fallback_pending_steer(state, request.run_id)
    send(self(), :maybe_start_next)
    {:noreply, state}
  end

  def handle_info(:maybe_start_next, state) do
    {:noreply, maybe_start_next(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_coordinator(conversation_key, opts) do
    case whereis(conversation_key) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        LemonRouter.SessionCoordinatorSupervisor.ensure_started(conversation_key, opts)
    end
  end

  defp whereis(conversation_key) do
    case Registry.lookup(LemonRouter.ConversationRegistry, conversation_key) do
      [{pid, _}] when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp cancel_conversation(conversation_key, reason) do
    with {:ok, pid} <- whereis(conversation_key) do
      GenServer.cast(pid, {:cancel, reason})
    end

    :ok
  end

  defp active_run_for_session(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, %{run_id: run_id}} | _] when is_binary(run_id) -> {:ok, run_id}
      _ -> :none
    end
  rescue
    _ -> :none
  end

  defp normalize_submission(submission) do
    execution_request = fetch(submission, :execution_request)

    execution_request =
      if match?(%ExecutionRequest{}, execution_request) do
        execution_request
      else
        raise ArgumentError, "session coordinator submission missing execution request"
      end

    %{
      run_id: fetch(submission, :run_id) || execution_request.run_id,
      session_key: fetch(submission, :session_key) || execution_request.session_key,
      queue_mode: fetch(submission, :queue_mode) || :collect,
      execution_request: execution_request,
      run_supervisor: fetch(submission, :run_supervisor) || LemonRouter.RunSupervisor,
      run_process_module: fetch(submission, :run_process_module) || LemonRouter.RunProcess,
      run_process_opts: normalize_run_process_opts(fetch(submission, :run_process_opts)),
      meta: fetch(submission, :meta) || %{}
    }
  end

  defp normalize_queue_mode(:collect), do: :collect
  defp normalize_queue_mode(:followup), do: :followup
  defp normalize_queue_mode(:steer), do: :steer
  defp normalize_queue_mode(:steer_backlog), do: :steer_backlog
  defp normalize_queue_mode(:interrupt), do: :interrupt
  defp normalize_queue_mode(_), do: :collect

  defp maybe_promote_auto_followup(submission, :followup, %{active: %{}}) do
    meta = submission.meta || %{}

    if fetch(meta, :task_auto_followup) == true or fetch(meta, :delegated_auto_followup) == true do
      %{submission | queue_mode: :steer_backlog}
    else
      submission
    end
  end

  defp maybe_promote_auto_followup(submission, _mode, _state), do: submission

  defp enqueue_by_mode(%{queue_mode: :collect} = submission, state) do
    %{state | queue: state.queue ++ [submission]}
  end

  defp enqueue_by_mode(%{queue_mode: :followup} = submission, state) do
    now = System.monotonic_time(:millisecond)

    case maybe_merge_followup(state.queue, submission, state.last_followup_at_ms, now) do
      {:merged, queue} -> %{state | queue: queue, last_followup_at_ms: now}
      :no_merge -> %{state | queue: state.queue ++ [submission], last_followup_at_ms: now}
    end
  end

  defp enqueue_by_mode(%{queue_mode: :steer} = submission, state) do
    steer_or_fallback(submission, :followup, :steer, state)
  end

  defp enqueue_by_mode(%{queue_mode: :steer_backlog} = submission, state) do
    steer_or_fallback(submission, :collect, :steer_backlog, state)
  end

  defp enqueue_by_mode(%{queue_mode: :interrupt} = submission, state) do
    state = maybe_cancel_active(state, :interrupted)
    %{state | queue: [submission | state.queue]}
  end

  defp enqueue_by_mode(submission, state) do
    %{state | queue: state.queue ++ [submission]}
  end

  defp steer_or_fallback(
         submission,
         fallback_mode,
         steer_mode,
         %{active: %{run_id: active_run_id}} = state
       )
       when is_binary(active_run_id) do
    case gateway_run_pid(active_run_id) do
      nil ->
        enqueue_by_mode(%{submission | queue_mode: fallback_mode}, state)

      run_pid ->
        GenServer.cast(run_pid, {steer_mode, submission.execution_request, self()})

        pending = Map.get(state.pending_steers, active_run_id, [])

        %{
          state
          | pending_steers:
              Map.put(state.pending_steers, active_run_id, [{submission, fallback_mode} | pending])
        }
    end
  rescue
    _ -> enqueue_by_mode(%{submission | queue_mode: fallback_mode}, state)
  end

  defp steer_or_fallback(submission, fallback_mode, _steer_mode, state) do
    enqueue_by_mode(%{submission | queue_mode: fallback_mode}, state)
  end

  defp maybe_merge_followup(queue, submission, last_followup_at_ms, now_ms) do
    cond do
      is_nil(last_followup_at_ms) ->
        :no_merge

      now_ms - last_followup_at_ms > @followup_debounce_ms ->
        :no_merge

      queue == [] ->
        :no_merge

      true ->
        case List.pop_at(queue, -1) do
          {nil, _rest} ->
            :no_merge

          {%{queue_mode: :followup} = previous, rest} ->
            {:merged, rest ++ [merge_followup_submission(previous, submission)]}

          {_other, _rest} ->
            :no_merge
        end
    end
  end

  defp merge_followup_submission(previous, current) do
    merged_prompt =
      merge_prompt(previous.execution_request.prompt, current.execution_request.prompt)

    previous_request = previous.execution_request

    meta = merge_user_message_meta(previous.meta || %{}, current.meta || %{})

    %{
      previous
      | run_id: current.run_id,
        session_key: current.session_key,
        meta: meta,
        execution_request: %{
          previous_request
          | run_id: current.run_id,
            prompt: merged_prompt,
            meta:
              merge_user_message_meta(
                previous_request.meta || %{},
                current.execution_request.meta || %{}
              )
        }
    }
  end

  defp maybe_start_next(state, opts \\ [])

  defp maybe_start_next(%{active: nil, queue: [next | rest]} = state, opts) do
    case start_run_process(next, self(), state.conversation_key) do
      {:ok, pid} when is_pid(pid) ->
        mon_ref = Process.monitor(pid)
        put_active_session_registry(next)

        next_state = %{
          state
          | active: %{
              pid: pid,
              mon_ref: mon_ref,
              run_id: next.run_id,
              session_key: next.session_key
            },
            queue: rest
        }

        if opts[:return_result?], do: {next_state, :started}, else: next_state

      {:error, reason} ->
        Logger.warning(
          "SessionCoordinator failed to start run run_id=#{inspect(next.run_id)} key=#{inspect(state.conversation_key)} reason=#{inspect(reason)}"
        )

        next_state = %{state | queue: rest}

        if opts[:return_result?], do: {next_state, {:error, reason}}, else: next_state
    end
  end

  defp maybe_start_next(state, opts) do
    if opts[:return_result?], do: {state, :noop}, else: state
  end

  defp maybe_cancel_active(%{active: %{pid: pid}} = state, reason) when is_pid(pid) do
    LemonRouter.RunProcess.abort(pid, reason)
    state
  rescue
    _ -> state
  end

  defp maybe_cancel_active(state, _reason), do: state

  defp put_active_session_registry(%{session_key: session_key, run_id: run_id}) do
    if is_binary(session_key) do
      _ = Registry.unregister(LemonRouter.SessionRegistry, session_key)
      _ = Registry.register(LemonRouter.SessionRegistry, session_key, %{run_id: run_id})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp clear_active_session_registry(
         %{active: %{session_key: session_key, run_id: run_id}} = state
       )
       when is_binary(session_key) do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, %{run_id: ^run_id}}] ->
        Registry.unregister(LemonRouter.SessionRegistry, session_key)

      _ ->
        :ok
    end

    state
  rescue
    _ -> state
  end

  defp clear_active_session_registry(state), do: state

  defp clear_pending_steer(state, submission_run_id) do
    update_pending_steers(state, submission_run_id, :clear)
  end

  defp fallback_pending_steer(state, submission_run_id) do
    case take_pending_steer(state.pending_steers, submission_run_id) do
      {nil, pending_steers} ->
        %{state | pending_steers: pending_steers}

      {{submission, fallback_mode, _active_run_id}, pending_steers} ->
        enqueue_by_mode(%{submission | queue_mode: fallback_mode}, %{
          state
          | pending_steers: pending_steers
        })
    end
  end

  defp flush_pending_steers_for_active(%{active: %{run_id: active_run_id}} = state)
       when is_binary(active_run_id) do
    pending = Map.get(state.pending_steers, active_run_id, [])
    pending_steers = Map.delete(state.pending_steers, active_run_id)

    Enum.reduce(pending, %{state | pending_steers: pending_steers}, fn {submission, fallback_mode},
                                                                       acc ->
      enqueue_by_mode(%{submission | queue_mode: fallback_mode}, acc)
    end)
  end

  defp flush_pending_steers_for_active(state), do: state

  defp update_pending_steers(state, submission_run_id, op) do
    {found, updated} =
      Enum.reduce(state.pending_steers, {nil, %{}}, fn {active_run_id, entries},
                                                       {found_acc, acc} ->
        {matched, rest} =
          Enum.split_with(entries, fn {submission, _mode} ->
            submission.run_id == submission_run_id
          end)

        found_acc =
          case {found_acc, matched} do
            {nil, [{submission, fallback_mode} | _]} -> {submission, fallback_mode, active_run_id}
            _ -> found_acc
          end

        if rest == [] do
          {found_acc, acc}
        else
          {found_acc, Map.put(acc, active_run_id, rest)}
        end
      end)

    state = %{state | pending_steers: updated}

    case {op, found} do
      {:clear, _} ->
        state

      {:fallback, nil} ->
        state

      {:fallback, {submission, fallback_mode, _}} ->
        enqueue_by_mode(%{submission | queue_mode: fallback_mode}, state)
    end
  end

  defp take_pending_steer(pending_steers, submission_run_id) do
    Enum.reduce_while(pending_steers, {nil, %{}}, fn {active_run_id, entries}, {found, acc} ->
      {matched, rest} =
        Enum.split_with(entries, fn {submission, _mode} ->
          submission.run_id == submission_run_id
        end)

      acc = if rest == [], do: acc, else: Map.put(acc, active_run_id, rest)

      case {found, matched} do
        {nil, [{submission, fallback_mode} | _]} ->
          {:cont, {{submission, fallback_mode, active_run_id}, acc}}

        _ ->
          {:cont, {found, acc}}
      end
    end)
  end

  defp gateway_run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp gateway_run_pid(_), do: nil

  defp merge_prompt(nil, right), do: right || ""
  defp merge_prompt(left, nil), do: left
  defp merge_prompt(left, right), do: left <> "\n" <> right

  defp merge_user_message_meta(left, right) when is_map(left) and is_map(right) do
    right_user_msg_id = fetch(right, :user_msg_id)

    if is_nil(right_user_msg_id) do
      Map.merge(left, right)
    else
      left
      |> Map.merge(right)
      |> Map.put(:user_msg_id, right_user_msg_id)
      |> Map.delete("user_msg_id")
    end
  end

  defp merge_user_message_meta(left, _right) when is_map(left), do: left
  defp merge_user_message_meta(_left, right) when is_map(right), do: right
  defp merge_user_message_meta(_left, _right), do: %{}

  defp start_run_process(submission, coordinator_pid, conversation_key) do
    run_id = submission.run_id
    session_key = submission.session_key
    execution_request = submission.execution_request

    run_opts =
      submission.run_process_opts
      |> Map.merge(%{
        run_id: run_id,
        session_key: session_key,
        queue_mode: submission.queue_mode,
        execution_request: execution_request,
        coordinator_pid: coordinator_pid,
        conversation_key: conversation_key,
        manage_session_registry?: false
      })

    spec = {submission.run_process_module, run_opts}

    case DynamicSupervisor.start_child(submission.run_supervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, :max_children} ->
        {:error, :run_capacity_reached}

      {:error, {:noproc, _}} ->
        {:error, :router_not_ready}

      {:error, :noproc} ->
        {:error, :router_not_ready}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
