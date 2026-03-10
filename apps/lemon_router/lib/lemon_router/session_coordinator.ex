defmodule LemonRouter.SessionCoordinator do
  @moduledoc """
  Router-owned owner of per-conversation queue semantics.

  Queue mode behavior is implemented here so gateway remains execution-only.
  """

  use GenServer

  require Logger

  alias LemonGateway.ExecutionRequest
  alias LemonRouter.{SessionState, SessionTransitions}

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
    coordinator_entries()
    |> Enum.each(fn {_conversation_key, pid, _meta} ->
      if is_pid(pid) do
        GenServer.cast(pid, {:cancel_session, session_key, reason})
      end
    end)

    :ok
  end

  @spec abort_session(binary(), term()) :: :ok
  def abort_session(session_key, reason \\ :user_requested) when is_binary(session_key) do
    coordinator_entries()
    |> Enum.each(fn {_conversation_key, pid, _meta} ->
      if is_pid(pid) do
        GenServer.cast(pid, {:abort_session, session_key, reason})
      end
    end)

    maybe_cancel_resume_conversation(session_key, reason)
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

  @spec active_run_for_session(binary()) :: {:ok, binary()} | :none
  def active_run_for_session(session_key) when is_binary(session_key) and session_key != "" do
    case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
      [{_pid, %{run_id: run_id}} | _] when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _ -> :none
    end
  rescue
    _ -> :none
  end

  def active_run_for_session(_), do: :none

  @spec busy?(binary()) :: boolean()
  def busy?(session_key) when is_binary(session_key) and session_key != "" do
    active_run_for_session(session_key) != :none
  end

  def busy?(_), do: false

  @spec list_active_sessions() :: [%{session_key: binary(), run_id: binary()}]
  def list_active_sessions do
    Registry.select(LemonRouter.SessionRegistry, [
      {{:"$1", :"$2", %{run_id: :"$3"}}, [], [%{session_key: :"$1", run_id: :"$3"}]}
    ])
  rescue
    _ -> []
  end

  def start_link(opts) do
    key = Keyword.fetch!(opts, :conversation_key)
    name = {:via, Registry, {LemonRouter.ConversationRegistry, key}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    {:ok, SessionState.new(opts)}
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

    {:reply, reply, next_state} =
      apply_transition(
        SessionTransitions.submit(state, submission, System.monotonic_time(:millisecond)),
        state,
        reply?: true
      )

    {:reply, reply, next_state}
  end

  @impl true
  def handle_cast({:cancel, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel(state, reason), state)

    {:noreply, next_state}
  end

  def handle_cast({:cancel_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.cancel_session(state, session_key, reason), state)

    {:noreply, next_state}
  end

  def handle_cast({:abort_session, session_key, reason}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.abort_session(state, session_key, reason), state)

    {:noreply, next_state}
  end

  @impl true
  def handle_info(
        {:DOWN, mon_ref, :process, pid, _reason},
        %SessionState{active: %{pid: pid, mon_ref: mon_ref}} = state
      ) do
    state = clear_active_session_registry(state)

    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.active_down(state, pid, mon_ref, System.monotonic_time(:millisecond)),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, request.run_id), state)

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_accepted, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(SessionTransitions.steer_accepted(state, request.run_id), state)

    {:noreply, next_state}
  end

  def handle_info({:steer_rejected, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          request.run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info({:steer_backlog_rejected, %ExecutionRequest{} = request}, state) do
    {:noreply, next_state} =
      apply_transition(
        SessionTransitions.steer_rejected(
          state,
          request.run_id,
          System.monotonic_time(:millisecond)
        ),
        state
      )

    {:noreply, next_state}
  end

  def handle_info(:maybe_start_next, state) do
    {next_state, _result} = maybe_start_next(state, return_result?: false)
    {:noreply, next_state}
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

  defp apply_transition({:ok, transitioned_state, effects}, original_state, opts \\ []) do
    {next_state, reply} = apply_effects(transitioned_state, effects, original_state, opts)

    if opts[:reply?] do
      {:reply, reply, next_state}
    else
      {:noreply, next_state}
    end
  end

  defp apply_effects(state, effects, original_state, opts) do
    Enum.reduce(effects, {state, :ok}, fn effect, {state_acc, reply_acc} ->
      apply_effect(effect, state_acc, reply_acc, original_state, opts)
    end)
  end

  defp apply_effect(:maybe_start_next, state, reply_acc, _original_state, opts) do
    {next_state, start_result} =
      maybe_start_next(state, return_result?: Keyword.get(opts, :reply?, false))

    {next_state, merge_reply(reply_acc, start_result)}
  end

  defp apply_effect({:cancel_active, reason}, state, reply_acc, _original_state, _opts) do
    {maybe_cancel_active(state, reason), reply_acc}
  end

  defp apply_effect(
         {:dispatch_steer, active_run_id, steer_mode, submission, _fallback_mode},
         state,
         reply_acc,
         _original_state,
         _opts
       ) do
    case dispatch_steer(active_run_id, steer_mode, submission.execution_request) do
      :ok ->
        {state, reply_acc}

      :error ->
        {:ok, next_state, extra_effects} =
          SessionTransitions.dispatch_steer_failed(
            state,
            submission.run_id,
            System.monotonic_time(:millisecond)
          )

        apply_effects(next_state, extra_effects, state, [])
        |> then(fn {resolved_state, _} -> {resolved_state, reply_acc} end)
    end
  end

  defp apply_effect(:noop, state, reply_acc, _original_state, _opts), do: {state, reply_acc}

  defp merge_reply(:ok, :noop), do: :ok
  defp merge_reply(:ok, :started), do: :ok
  defp merge_reply(:ok, {:error, reason}), do: {:error, reason}
  defp merge_reply(reply, :ok), do: reply
  defp merge_reply(reply, :noop), do: reply
  defp merge_reply(reply, :started), do: reply
  defp merge_reply(reply, {:error, _reason}), do: reply

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

  defp maybe_start_next(%SessionState{active: nil, queue: [next | rest]} = state, opts) do
    case start_run_process(next, self(), state.conversation_key) do
      {:ok, pid} when is_pid(pid) ->
        mon_ref = Process.monitor(pid)
        put_active_session_registry(next)

        next_state = %SessionState{
          state
          | active: %{
              pid: pid,
              mon_ref: mon_ref,
              run_id: next.run_id,
              session_key: next.session_key
            },
            queue: rest
        }

        if opts[:return_result?], do: {next_state, :started}, else: {next_state, :ok}

      {:error, reason} ->
        Logger.warning(
          "SessionCoordinator failed to start run run_id=#{inspect(next.run_id)} key=#{inspect(state.conversation_key)} reason=#{inspect(reason)}"
        )

        next_state = %SessionState{state | queue: rest}

        if opts[:return_result?], do: {next_state, {:error, reason}}, else: {next_state, :ok}
    end
  end

  defp maybe_start_next(state, _opts), do: {state, :noop}

  defp maybe_cancel_active(%SessionState{active: %{pid: pid}} = state, reason) when is_pid(pid) do
    LemonRouter.RunProcess.abort(pid, reason)
    state
  rescue
    _ -> state
  end

  defp maybe_cancel_active(state, _reason), do: state

  defp dispatch_steer(active_run_id, steer_mode, %ExecutionRequest{} = request)
       when steer_mode in [:steer, :steer_backlog] do
    case gateway_run_pid(active_run_id) do
      nil ->
        :error

      run_pid ->
        GenServer.cast(run_pid, {steer_mode, request, self()})
        :ok
    end
  rescue
    _ -> :error
  end

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
         %SessionState{active: %{session_key: session_key, run_id: run_id}} = state
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

  defp gateway_run_pid(run_id) when is_binary(run_id) do
    case Registry.lookup(LemonGateway.RunRegistry, run_id) do
      [{pid, _}] when is_pid(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp gateway_run_pid(_), do: nil

  defp coordinator_entries do
    Registry.select(LemonRouter.ConversationRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
    ])
  rescue
    _ -> []
  end

  defp maybe_cancel_resume_conversation(session_key, reason) do
    case resume_conversation_key(session_key) do
      nil -> :ok
      conversation_key -> cancel_conversation(conversation_key, reason)
    end
  rescue
    _ -> :ok
  end

  defp resume_conversation_key(session_key) when is_binary(session_key) do
    case LemonCore.ChatStateStore.get(session_key) do
      %LemonGateway.ChatState{last_engine: engine, last_resume_token: token}
      when is_binary(engine) and is_binary(token) ->
        {:resume, engine, token}

      %{} = state ->
        engine = fetch(state, :last_engine)
        token = fetch(state, :last_resume_token)

        if is_binary(engine) and is_binary(token), do: {:resume, engine, token}, else: nil

      _ ->
        nil
    end
  end

  defp resume_conversation_key(_), do: nil

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

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
end
