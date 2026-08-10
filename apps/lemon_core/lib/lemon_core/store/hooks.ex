defmodule LemonCore.Store.Hooks do
  @moduledoc """
  Registration and safe invocation of `LemonCore.Store` extension points.

  `LemonCore.Store` is a storage primitive: it must not know about run history,
  memory ingest, Telegram, or any other domain. Collaborators attach to it
  instead, either through configuration or at runtime.

  ## Extension points

    * `:finalize_run_hooks` — invoked after a run is finalized with a session
      key. See `LemonCore.Store.finalize_run/3` for the payload.
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
  starts. Runtime registrations live in `:persistent_term` keyed by store name,
  so they survive a store crash and can be made before the store boots.

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
    current = registered(store, kind)

    if value in current do
      :ok
    else
      :persistent_term.put(registry_key(store, kind), current ++ [value])
    end
  end

  @doc "Remove a runtime registration."
  @spec unregister(atom(), kind(), term()) :: :ok
  def unregister(store, kind, value) do
    case registered(store, kind) do
      [] -> :ok
      current -> :persistent_term.put(registry_key(store, kind), List.delete(current, value))
    end
  end

  @doc "List runtime registrations for `store`."
  @spec registered(atom(), kind()) :: [term()]
  def registered(store, kind) when is_atom(store) do
    :persistent_term.get(registry_key(store, kind), [])
  end

  def registered(_store, _kind), do: []

  @doc """
  Publish a store's resolved value for a kind, for client-side reads.

  Written by the store as it starts; read from caller processes that need to
  know the effective configuration without a round trip through the GenServer.
  """
  @spec publish(atom(), kind(), term()) :: :ok
  def publish(store, kind, value) do
    key = published_key(store, kind)

    if :persistent_term.get(key, :__unset__) != value do
      :persistent_term.put(key, value)
    end

    :ok
  end

  @doc "Read a store's published value for a kind."
  @spec published(atom(), kind(), term()) :: term()
  def published(store, kind, default \\ [])

  def published(store, kind, default) when is_atom(store) and not is_nil(store) do
    :persistent_term.get(published_key(store, kind), default)
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
    apply_hook(hook, payload)
    :ok
  rescue
    exception ->
      log_failure(
        hook_context(context, hook),
        Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  catch
    kind, reason ->
      log_failure(hook_context(context, hook), Exception.format(kind, reason, __STACKTRACE__))
      :ok
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
  # collaborators it doesn't depend on. That is a skip, not a failure; only
  # hooks that exist and then misbehave are worth an error.
  defp apply_loaded(module, function, args) do
    if Code.ensure_loaded?(module) do
      apply(module, function, args)
    else
      Logger.debug(
        "[LemonCore.Store.Hooks] skipping #{inspect(module)}.#{function}/#{length(args)}: " <>
          "module not available"
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
