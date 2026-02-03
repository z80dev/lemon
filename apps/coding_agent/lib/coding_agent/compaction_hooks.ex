defmodule CodingAgent.CompactionHooks do
  @moduledoc """
  Pre-compaction flush hooks for session state preservation.

  Allows subagents and extensions to write durable state before
  compaction thresholds are reached.

  ## Features

  - Register hooks to be called before compaction
  - Write state to durable storage
  - Graceful handling of hook failures
  - Hook timeout protection

  ## Usage

      # Register a hook
      CompactionHooks.register_hook(session_id, fn ->
        # Save state before compaction
        MyState.save()
      end)

      # Execute hooks before compaction
      CompactionHooks.execute_hooks(session_id)
  """

  use GenServer
  require Logger

  @table :coding_agent_compaction_hooks
  @default_timeout_ms 5000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Start the CompactionHooks server.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a hook to be called before compaction.

  ## Options

  - `:timeout_ms` - Maximum time to wait for hook (default: 5000)
  - `:priority` - Execution priority: :high, :normal, :low (default: :normal)

  ## Examples

      CompactionHooks.register_hook(session_id, fn ->
        # Flush state to disk
        :ok
      end, priority: :high)
  """
  @spec register_hook(String.t(), (() -> term()), keyword()) :: :ok
  def register_hook(session_id, hook_fn, opts \\ []) when is_function(hook_fn, 0) do
    hook = %{
      id: generate_hook_id(),
      session_id: session_id,
      fn: hook_fn,
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      priority: Keyword.get(opts, :priority, :normal),
      registered_at: System.system_time(:millisecond)
    }

    :ets.insert(@table, {{session_id, hook.id}, hook})
    :ok
  end

  @doc """
  Unregister a hook.
  """
  @spec unregister_hook(String.t(), String.t()) :: :ok
  def unregister_hook(session_id, hook_id) do
    :ets.delete(@table, {session_id, hook_id})
    :ok
  end

  @doc """
  Unregister all hooks for a session.
  """
  @spec unregister_all_hooks(String.t()) :: :ok
  def unregister_all_hooks(session_id) do
    # Match and delete all hooks for this session
    :ets.select_delete(@table, [
      {{{session_id, :_}, :_}, [], [true]}
    ])

    :ok
  end

  @doc """
  Execute all hooks for a session before compaction.

  Hooks are executed in priority order (:high, :normal, :low).
  If a hook fails or times out, it's logged but doesn't block other hooks.

  Returns a summary of hook execution results.
  """
  @spec execute_hooks(String.t(), keyword()) :: %{
          executed: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: non_neg_integer(),
          timed_out: non_neg_integer()
        }
  def execute_hooks(session_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    # Get all hooks for this session
    hooks = get_hooks_for_session(session_id)

    # Sort by priority
    sorted_hooks = sort_by_priority(hooks)

    # Execute hooks
    results =
      Enum.map(sorted_hooks, fn hook ->
        execute_single_hook(hook, timeout)
      end)

    # Summarize results
    %{
      executed: length(results),
      succeeded: Enum.count(results, fn {status, _} -> status == :ok end),
      failed: Enum.count(results, fn {status, _} -> status == :error end),
      timed_out: Enum.count(results, fn {status, _} -> status == :timeout end)
    }
  end

  @doc """
  Check if compaction should be triggered with pre-compaction hooks.

  This is a wrapper around Compaction.should_compact? that first
  executes pre-compaction hooks if compaction is needed.
  """
  @spec should_compact_with_hooks?(
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          map()
        ) :: boolean()
  def should_compact_with_hooks?(context_tokens, context_window, session_id, settings) do
    enabled = Map.get(settings, :enabled, true)
    reserve_tokens = Map.get(settings, :reserve_tokens, 16384)

    should_compact = enabled && context_tokens > context_window - reserve_tokens

    if should_compact do
      Logger.info("Compaction triggered for session #{session_id}, executing pre-compaction hooks")

      # Execute hooks before confirming compaction
      results = execute_hooks(session_id)

      Logger.info(
        "Pre-compaction hooks executed: #{results.succeeded}/#{results.executed} succeeded"
      )

      # Log any failures
      if results.failed > 0 or results.timed_out > 0 do
        Logger.warning(
          "Some pre-compaction hooks failed: #{results.failed} failed, #{results.timed_out} timed out"
        )
      end
    end

    should_compact
  end

  @doc """
  List all hooks for a session.
  """
  @spec list_hooks(String.t()) :: [map()]
  def list_hooks(session_id) do
    @table
    |> :ets.select([{{{session_id, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.map(fn hook ->
      %{
        id: hook.id,
        timeout_ms: hook.timeout_ms,
        priority: hook.priority,
        registered_at: hook.registered_at
      }
    end)
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for hooks
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_hooks_for_session(session_id) do
    :ets.select(@table, [{{{session_id, :_}, :"$1"}, [], [:"$1"]}])
  end

  defp sort_by_priority(hooks) do
    priority_order = %{high: 0, normal: 1, low: 2}

    Enum.sort_by(hooks, fn hook ->
      Map.get(priority_order, hook.priority, 1)
    end)
  end

  defp execute_single_hook(hook, default_timeout) do
    timeout = hook.timeout_ms || default_timeout
    caller = self()

    try do
      # Use a simple spawn to avoid linking issues
      ref = make_ref()

      pid =
        spawn(fn ->
          try do
            result = hook.fn.()
            send(caller, {:hook_result, ref, {:ok, result}})
          rescue
            e ->
              send(caller, {:hook_result, ref, {:error, e}})
          catch
            kind, err ->
              send(caller, {:hook_result, ref, {:error, {kind, err}}})
          end
        end)

      receive do
        {:hook_result, ^ref, {:ok, _}} ->
          {:ok, hook.id}

        {:hook_result, ^ref, {:error, _}} ->
          Logger.error("Pre-compaction hook #{hook.id} failed")
          {:error, hook.id}
      after
        timeout ->
          Process.exit(pid, :kill)
          Logger.warning("Pre-compaction hook #{hook.id} timed out after #{timeout}ms")
          {:timeout, hook.id}
      end
    rescue
      e ->
        Logger.error("Pre-compaction hook #{hook.id} failed: #{inspect(e)}")
        {:error, hook.id}
    catch
      kind, err ->
        Logger.error("Pre-compaction hook #{hook.id} crashed: #{kind} - #{inspect(err)}")
        {:error, hook.id}
    end
  end

  defp generate_hook_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
