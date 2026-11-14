defmodule CodingAgent.Session.ManualOperation do
  @moduledoc """
  Owns the model-calling operations a caller waits on: manual compaction
  (`CodingAgent.Session.compact/2`) and branch summaries
  (`CodingAgent.Session.summarize_current_branch/2`).

  The session never calls the model inside `handle_call`. The slow call runs in
  a supervised background task while the session stays responsive, and the
  waiting caller gets its reply later with `GenServer.reply/2`. The reply values
  are the ones the synchronous implementation returned (`:ok | {:error, reason}`).

  At most one operation is in flight. Its slot in the session state is the
  `manual_operation` field, holding a `CodingAgent.Session.ManualOperation.State`
  (or `nil`). While it is set, mutating calls that already refuse to run during a
  stream (prompt, compact, summarize, rewind, navigate, plan, reload) report busy
  instead of racing it; read-only calls keep being served.

  The operation ends exactly once, always replying to the caller:

    * the task's result arrives for the captured session signature: the result is
      applied inside the session process and the caller gets `:ok` or the error;
    * the session moved on (the signature changed, a turn started):
      the result is discarded and the caller gets `{:error, :stale_session}`;
    * `abort/1` (or reset) cancels it: the task is killed and the caller gets
      `{:error, :aborted}`;
    * the task crashes: `{:error, {:task_exit, reason}}`;
    * the task exceeds the auto-compaction task timeout: `{:error, :timeout}`;
    * the session terminates: `{:error, :session_terminated}`.
  """

  alias CodingAgent.Session.BackgroundTasks
  alias CodingAgent.Session.CompactionLifecycle
  alias CodingAgent.Session.CompactionManager

  defmodule State do
    @moduledoc """
    The in-flight operation: who is waiting, what snapshot it captured, and the
    task it tracks (pid, monitor, timeout timer, abort signal).
    """

    @type t :: %__MODULE__{
            kind: :compact | :summarize_branch,
            from: GenServer.from(),
            ref: reference(),
            signature: CodingAgent.Session.CompactionManager.session_signature(),
            signal: reference(),
            custom_summary: String.t() | nil,
            from_id: String.t() | nil,
            task_pid: pid(),
            monitor_ref: reference(),
            timeout_ref: reference() | nil
          }

    defstruct [
      :kind,
      :from,
      :ref,
      :signature,
      :signal,
      :custom_summary,
      :from_id,
      :task_pid,
      :monitor_ref,
      :timeout_ref
    ]
  end

  @type callbacks(state) :: %{
          required(:broadcast_event) => (state, LemonAgent.Types.agent_event() -> :ok),
          required(:restore_messages_from_session) => (term() -> [term()]),
          optional(atom()) => term()
        }

  @doc "Whether an operation is in flight."
  @spec in_flight?(map()) :: boolean()
  def in_flight?(%{manual_operation: %State{}}), do: true
  def in_flight?(_state), do: false

  @doc """
  Start a manual compaction in a background task.

  Returns `{:ok, state}` once the task is tracked; the caller in `from` is
  answered when it finishes.
  """
  @spec start_compaction(map(), GenServer.from(), keyword()) :: {:ok, map()}
  def start_compaction(state, from, opts) do
    signal = LemonAgent.AbortSignal.new()

    compaction_opts =
      state
      |> CompactionManager.normalize_compaction_opts(Keyword.put_new(opts, :force, true))
      |> Keyword.put(:signal, signal)

    session_manager = state.session_manager
    model = state.model

    run = fn ->
      CompactionManager.auto_compaction_task_result(session_manager, model, compaction_opts)
    end

    launch(state, from, :compact, signal, %{custom_summary: Keyword.get(opts, :summary)}, run)
  end

  @doc """
  Start a branch summary in a background task.

  Keeps the synchronous preconditions: `{:error, :busy, state}` while streaming
  and `{:error, :empty_branch, state}` for a branch without messages.
  """
  @spec start_branch_summary(map(), GenServer.from(), keyword()) ::
          {:ok, map()} | {:error, term(), map()}
  def start_branch_summary(state, from, opts) do
    case BackgroundTasks.branch_summary_request(state, opts) do
      {:ok, request} ->
        signal = LemonAgent.AbortSignal.new()
        summary_opts = Keyword.put(request.opts, :signal, signal)
        model = state.model

        run = fn ->
          guarded(fn ->
            CodingAgent.Compaction.generate_branch_summary(
              request.branch_entries,
              model,
              summary_opts
            )
          end)
        end

        launch(state, from, :summarize_branch, signal, %{from_id: request.from_id}, run)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @doc """
  Apply a task's result message. Results for an operation that is no longer
  in flight (cancelled, timed out, replaced) are ignored.
  """
  @spec handle_result(map(), reference(), term(), callbacks(map())) :: map()
  def handle_result(%{manual_operation: %State{ref: ref} = op} = state, ref, result, callbacks) do
    state = finish(state, op)

    if stale?(state, op) do
      GenServer.reply(op.from, {:error, :stale_session})
      state
    else
      apply_result(state, op, result, callbacks)
    end
  end

  def handle_result(state, _ref, _result, _callbacks), do: state

  @doc "Handle the task process going down without delivering a result."
  @spec handle_task_down(map(), reference(), term()) :: {:handled, map()} | :unhandled
  def handle_task_down(
        %{manual_operation: %State{monitor_ref: monitor_ref} = op} = state,
        monitor_ref,
        reason
      ) do
    GenServer.reply(op.from, {:error, {:task_exit, reason}})
    {:handled, finish(state, op)}
  end

  def handle_task_down(_state, _monitor_ref, _reason), do: :unhandled

  @doc "Handle the task timeout timer; stale timers are ignored."
  @spec handle_timeout(map(), reference()) :: {:handled, map()} | :stale
  def handle_timeout(
        %{manual_operation: %State{monitor_ref: monitor_ref} = op} = state,
        monitor_ref
      ) do
    kill_task(state, op, :manual_operation_timeout)
    GenServer.reply(op.from, {:error, :timeout})
    {:handled, finish(state, op)}
  end

  def handle_timeout(_state, _monitor_ref), do: :stale

  @doc """
  Cancel the in-flight operation (if any): signal and kill the task, answer the
  waiting caller with `{:error, reason}`.
  """
  @spec cancel(map(), term()) :: map()
  def cancel(%{manual_operation: %State{} = op} = state, reason) do
    LemonAgent.AbortSignal.abort(op.signal)
    kill_task(state, op, :manual_operation_cancelled)
    GenServer.reply(op.from, {:error, reason})
    finish(state, op)
  end

  def cancel(state, _reason), do: state

  # ---- Private helpers ----

  defp launch(state, from, kind, signal, fields, run) do
    ref = make_ref()
    session_pid = self()

    task = fn -> send(session_pid, {:manual_operation_result, ref, run.()}) end

    # Falls back to an unsupervised Task.start/1, so it cannot fail to start.
    {:ok, meta} =
      CompactionManager.start_tracked_background_task(
        task,
        CompactionManager.auto_compaction_task_timeout_ms(),
        :manual_operation_timeout
      )

    op =
      struct!(
        State,
        Map.merge(fields, %{
          kind: kind,
          from: from,
          ref: ref,
          signature: CompactionManager.session_signature(state),
          signal: signal,
          task_pid: meta.pid,
          monitor_ref: meta.monitor_ref,
          timeout_ref: meta.timeout_ref
        })
      )

    {:ok, %{state | manual_operation: op}}
  end

  defp apply_result(state, %State{kind: :compact} = op, result, callbacks) do
    case CompactionLifecycle.apply_result(state, result, op.custom_summary, callbacks) do
      {:ok, new_state} ->
        GenServer.reply(op.from, :ok)
        new_state

      {:error, reason, new_state} ->
        GenServer.reply(op.from, {:error, reason})
        new_state
    end
  end

  defp apply_result(state, %State{kind: :summarize_branch} = op, result, callbacks) do
    case result do
      {:ok, summary} ->
        new_state = BackgroundTasks.store_branch_summary(state, op.from_id, summary, callbacks)
        GenServer.reply(op.from, :ok)
        new_state

      {:error, reason} ->
        GenServer.reply(op.from, {:error, reason})
        state
    end
  end

  # A turn that started (or a deferred prompt that is about to) or any change to
  # the session revision since the snapshot invalidates the generated summary.
  defp stale?(state, %State{signature: signature}) do
    state.is_streaming or not is_nil(state.pending_prompt_timer_ref) or
      CompactionManager.session_signature(state) != signature
  end

  defp kill_task(state, %State{task_pid: pid}, reason),
    do: CompactionManager.maybe_kill_background_task(state, pid, reason)

  defp finish(state, %State{} = op) do
    CompactionManager.maybe_cancel_timer(op.timeout_ref)
    CompactionManager.maybe_demonitor(op.monitor_ref)
    LemonAgent.AbortSignal.clear(op.signal)
    %{state | manual_operation: nil}
  end

  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
