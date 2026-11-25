defmodule LemonCore.Store.Hooks do
  @moduledoc """
  Registration and safe invocation of `LemonCore.Store` extension points.

  `LemonCore.Store` is a storage primitive: it must not know about run history,
  memory ingest, chat transports, or any other domain. Collaborators attach to it
  instead, either through configuration or at runtime.

  ## Extension points

    * `:finalize_run_hooks` — invoked after a run and its session index are
      finalized. Delivery is at least once, so hooks must be idempotent by run
      id. See `LemonCore.Store.finalize_run/3` for the payload.
    * `:cached_tables` — generic tables the store mirrors into
      `LemonCore.Store.ReadCache`.

  ## Hook shapes

  The payload is always passed as the **last** argument:

      {module, function}          # module.function(payload)
      {module, function, args}    # module.function(arg1, ..., payload)
      fun                         # fun.(payload) — 1-arity, runtime only

  ## Configuration vs runtime registration

  Configured values (`start_link/1` opts, falling back to
  `Application.get_env(:lemon_core, store_name)`) are resolved when the store
  starts. Runtime registrations live in supervised `LemonCore.RuntimeCache`
  ETS storage keyed by store name, so they survive a store crash and can be
  made before that store boots (after `:lemon_core` has started).

      LemonCore.Store.register_finalize_run_hook({MyApp.Archive, :on_run})
      LemonCore.Store.register_cached_table(:my_index)

  Invocation is isolated: a hook that raises, throws, or exits is logged and
  skipped so one bad collaborator cannot take down the store.
  """

  require Logger

  @type kind :: :finalize_run_hooks | :cached_tables
  @type hook :: {module(), atom()} | {module(), atom(), [term()]} | (term() -> any())

  @doc """
  Add a runtime registration for `store`, appended after existing ones.

  Registration order is preserved, and re-registering the same value is a no-op,
  so a collaborator that restarts does not accumulate duplicates.
  """
  @spec register(atom(), kind(), term()) :: :ok
  def register(store, kind, value) do
    LemonCore.RuntimeCache.register(registry_key(store, kind), value)
  end

  @doc "Remove a runtime registration."
  @spec unregister(atom(), kind(), term()) :: :ok
  def unregister(store, kind, value) do
    LemonCore.RuntimeCache.unregister(registry_key(store, kind), value)
  end

  @doc "List runtime registrations for `store`."
  @spec registered(atom(), kind()) :: [term()]
  def registered(store, kind) when is_atom(store) do
    LemonCore.RuntimeCache.get(registry_key(store, kind), [])
  end

  def registered(_store, _kind), do: []

  @doc """
  Publish a store's resolved value for a kind, for client-side reads.

  Written by the store at startup and when tables are registered at runtime;
  read directly from ETS without a round trip through the GenServer.
  """
  @spec publish(atom(), kind(), term()) :: :ok
  def publish(store, kind, value) do
    LemonCore.RuntimeCache.put(published_key(store, kind), value)
  end

  @doc "Read a store's published value for a kind."
  @spec published(atom(), kind(), term()) :: term()
  def published(store, kind, default \\ [])

  def published(store, kind, default) when is_atom(store) and not is_nil(store) do
    LemonCore.RuntimeCache.get(published_key(store, kind), default)
  end

  def published(_store, _kind, default), do: default

  @doc """
  Invoke every hook with `payload`, isolating failures.

  Hooks run in registration order, in the caller's process. `context` is used
  only for log messages.
  """
  @spec invoke([hook()], term(), keyword()) :: :ok
  def invoke(hooks, payload, context \\ []) do
    Enum.each(hooks, &safe_invoke(&1, payload, context))
  end

  @doc """
  Runs hooks outside the Store under a shared caller-policy budget.

  `:store_hook_budget_ms` in `:lemon_core` defaults to 5,000 milliseconds.
  Persistence has completed; a timed-out hook is killed and its failure is
  returned to the finalization owner for repair. Hooks must remain idempotent.
  """
  def invoke_bounded([], _payload, _context), do: :ok

  def invoke_bounded(hooks, payload, context) do
    budget = Application.get_env(:lemon_core, :store_hook_budget_ms, 5_000)
    result_ref = make_ref()
    caller = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          Enum.reduce(hooks, :ok, fn hook, acc ->
            case safe_invoke(hook, payload, context) do
              :ok -> acc
              error -> error
            end
          end)

        send(caller, {result_ref, result})
      end)

    {:ok, timer} = :timer.kill_after(budget, pid)

    try do
      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} ->
          Logger.warning("[LemonCore.Store.Hooks] finalize hook budget exhausted")
          {:error, :hook_timeout}

        {^result_ref, result} ->
          Process.demonitor(ref, [:flush])
          result

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          {:error, :hook_failed}
      end
    after
      :timer.cancel(timer)
    end
  end

  @doc """
  Call `fun`, returning `fallback` if it raises, throws, or exits.

  Used for collaborator calls made from inside the store process, where an
  exception would otherwise take the store down with it.
  """
  @spec safely((-> result), result, keyword()) :: result when result: term()
  def safely(fun, fallback, context \\ []) do
    fun.()
  rescue
    exception ->
      log_failure(context, Exception.format(:error, exception, __STACKTRACE__))
      fallback
  catch
    kind, reason ->
      log_failure(context, Exception.format(kind, reason, __STACKTRACE__))
      fallback
  end

  defp safe_invoke(hook, payload, context) do
    case apply_hook(hook, payload) do
      {:error, _} -> {:error, :hook_failed}
      _ -> :ok
    end
  rescue
    exception ->
      log_failure(
        hook_context(context, hook),
        Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :hook_failed}
  catch
    kind, reason ->
      log_failure(hook_context(context, hook), Exception.format(kind, reason, __STACKTRACE__))
      {:error, :hook_failed}
  end

  defp apply_hook(fun, payload) when is_function(fun, 1), do: fun.(payload)
  defp apply_hook({module, function}, payload), do: apply_loaded(module, function, [payload])

  defp apply_hook({module, function, args}, payload) when is_list(args),
    do: apply_loaded(module, function, args ++ [payload])

  defp apply_hook(other, _payload) do
    raise ArgumentError, "invalid store hook: #{inspect(other)}"
  end

  # A hook whose module isn't loaded is not installed in this build — the
  # umbrella shares one config across apps, so an app-scoped run sees hooks for
  # collaborators it doesn't depend on. That is a skip, not a failure.
  #
  # It is warned about once per module, though, because the other way to get
  # here is a typo in configured hooks, and that is a collaborator silently
  # never running. Once per module keeps the legitimate partial-build case from
  # becoming noise on every finalized run.
  defp apply_loaded(module, function, args) do
    if Code.ensure_loaded?(module) do
      apply(module, function, args)
    else
      warn_missing_once(module, function, length(args))
      :ok
    end
  end

  defp warn_missing_once(module, function, arity) do
    key = {__MODULE__, :missing_hook_module, module}

    if LemonCore.RuntimeCache.warn_once?(key) do
      Logger.warning(
        "[LemonCore.Store.Hooks] skipping #{inspect(module)}.#{function}/#{arity}: module not " <>
          "available. Expected when this build does not include that collaborator; if it " <>
          "should be here, check the module name in :finalize_run_hooks — a typo silently " <>
          "disables the hook. Logged once per module."
      )

      :ok
    end
  end

  defp hook_context(context, hook), do: Keyword.put(context, :hook, hook)

  defp log_failure(context, formatted) do
    Logger.error("[LemonCore.Store.Hooks] #{describe(context)} failed:\n#{formatted}")
  end

  defp describe(context) do
    context
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> case do
      "" -> "hook"
      described -> described
    end
  end

  defp registry_key(store, kind), do: {__MODULE__, store, kind, :registered}
  defp published_key(store, kind), do: {__MODULE__, store, kind, :published}
end
