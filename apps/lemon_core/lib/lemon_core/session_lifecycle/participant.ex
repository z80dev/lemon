defmodule LemonCore.SessionLifecycle.Participant do
  @moduledoc """
  Contract for session-keyed state that `LemonCore.SessionLifecycle` deletes
  or resets together with the session.

  Every store keyed by a session key (or reachable only through one session)
  belongs to one owning app. The owner implements this behaviour and registers
  it at application start with `register/3`, naming the operations it takes
  part in (`:delete`, `:reset`). Core-owned state that is not one of the
  canonical lifecycle stores (session-scoped exec-approval grants) is a
  built-in participant.

  `SessionLifecycle.delete/2` and `reset/2` run every participant registered
  for the operation while holding the session's lifecycle fence:

    1. `c:snapshot/2` on every participant before the first mutation. Reads are
       strict: an unreadable store is `{:error, reason}`, never an empty
       snapshot, and stops the operation with nothing changed.
    2. `c:delete/3` then `c:verify_deleted/3`, in registration order, before
       the canonical (unrestorable) run-history commit. Only when every
       participant verified does the operation report `verified: true`.
    3. On any failure before the canonical commit, `c:restore/3` on every
       participant in reverse order, with its snapshot. Restore must be
       idempotent and safe for a participant whose delete never ran. A failed
       restore makes the operation `{:error, :outcome_unknown}`.
    4. After the canonical commit, the optional `c:commit/3` discards staged
       data (a quarantined file, for example); a failure there is
       `{:error, :outcome_unknown}`.

  A raise, throw or exit from a callback is a failure of that step. Reasons
  never reach clients verbatim: the lifecycle service reports only the
  participant name and step.

  Registration lives in `:persistent_term` and survives the owner's restarts:
  a registered participant whose store is down makes delete/reset fail closed
  rather than skip its data.
  """

  @type operation :: :delete | :reset
  @type snapshot :: term()

  @doc "Strictly read everything `c:restore/3` needs; nothing is mutated."
  @callback snapshot(session_key :: String.t(), operation()) ::
              {:ok, snapshot()} | {:error, term()}

  @doc "Delete the session's state. Must report a failed write as an error."
  @callback delete(session_key :: String.t(), operation(), snapshot()) :: :ok | {:error, term()}

  @doc """
  Strictly verify that no state of the session remains: neither the
  snapshot's state nor any other state now keyed by the session.
  """
  @callback verify_deleted(session_key :: String.t(), operation(), snapshot()) ::
              :ok | {:error, term()}

  @doc "Write the snapshot back. Idempotent; safe when `c:delete/3` never ran."
  @callback restore(session_key :: String.t(), operation(), snapshot()) :: :ok | {:error, term()}

  @doc "Discard staged data once the canonical deletion is committed."
  @callback commit(session_key :: String.t(), operation(), snapshot()) :: :ok | {:error, term()}

  @optional_callbacks commit: 3

  @operations [:delete, :reset]
  @registry_key {__MODULE__, :registry}
  @default_order 50
  @builtin %{
    exec_approval_grants: %{
      module: LemonCore.SessionLifecycle.ExecApprovalGrants,
      operations: [:delete, :reset],
      order: 10
    },
    run_diagnostics: %{
      module: LemonCore.SessionLifecycle.RunDiagnostics,
      operations: [:delete],
      order: 80
    }
  }

  @type prepared :: {operation(), [{atom(), module(), snapshot()}]}

  @doc """
  Register `module` as participant `name`.

  Options: `:operations` (default `[:delete]`), `:order` (default 50; lower
  runs first). Re-registering a name replaces it.
  """
  @spec register(atom(), module(), keyword()) :: :ok
  def register(name, module, opts \\ []) when is_atom(name) and is_atom(module) do
    operations = Keyword.get(opts, :operations, [:delete])

    unless operations != [] and Enum.all?(operations, &(&1 in @operations)),
      do: raise(ArgumentError, "invalid session lifecycle operations")

    entry = %{
      module: module,
      operations: operations,
      order: Keyword.get(opts, :order, @default_order)
    }

    update_registry(&Map.put(&1, name, entry))
  end

  @doc "Remove a registered participant (tests and deliberate retirement)."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name), do: update_registry(&Map.delete(&1, name))

  @doc "Participants of `operation` as `{name, module}`, in run order."
  @spec registered(operation()) :: [{atom(), module()}]
  def registered(operation) when operation in @operations do
    @builtin
    |> Map.merge(:persistent_term.get(@registry_key, %{}))
    |> Enum.filter(fn {_name, entry} -> operation in entry.operations end)
    |> Enum.sort_by(fn {name, entry} -> {entry.order, name} end)
    |> Enum.map(fn {name, entry} -> {name, entry.module} end)
  end

  @doc false
  @spec snapshot_all(String.t(), operation()) :: {:ok, prepared()} | {:error, term()}
  def snapshot_all(session_key, operation) do
    operation
    |> registered()
    |> Enum.reduce_while({:ok, []}, fn {name, module}, {:ok, acc} ->
      case invoke(fn -> module.snapshot(session_key, operation) end) do
        {:ok, snapshot} -> {:cont, {:ok, [{name, module, snapshot} | acc]}}
        _unreadable -> {:halt, {:error, {:participant_unavailable, name}}}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, {operation, Enum.reverse(prepared)}}
      error -> error
    end
  end

  @doc false
  @spec delete_all(String.t(), prepared()) :: :ok | {:error, term()}
  def delete_all(session_key, {operation, prepared}) do
    Enum.reduce_while(prepared, :ok, fn {name, module, snapshot}, :ok ->
      with :ok <- invoke(fn -> module.delete(session_key, operation, snapshot) end),
           :ok <- invoke(fn -> module.verify_deleted(session_key, operation, snapshot) end) do
        {:cont, :ok}
      else
        _failed -> {:halt, {:error, {:participant_delete_failed, name}}}
      end
    end)
  end

  @doc false
  @spec restore_all(String.t(), prepared()) :: :ok | {:error, :restore_failed}
  def restore_all(session_key, {operation, prepared}) do
    prepared
    |> Enum.reverse()
    |> Enum.map(fn {_name, module, snapshot} ->
      invoke(fn -> module.restore(session_key, operation, snapshot) end)
    end)
    |> Enum.all?(&(&1 == :ok))
    |> if(do: :ok, else: {:error, :restore_failed})
  end

  @doc false
  @spec commit_all(String.t(), prepared()) :: :ok | {:error, term()}
  def commit_all(session_key, {operation, prepared}) do
    Enum.reduce_while(prepared, :ok, fn {name, module, snapshot}, :ok ->
      if Code.ensure_loaded?(module) and function_exported?(module, :commit, 3) do
        case invoke(fn -> module.commit(session_key, operation, snapshot) end) do
          :ok -> {:cont, :ok}
          _failed -> {:halt, {:error, {:participant_commit_failed, name}}}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp invoke(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} = ok -> ok
      {:error, _} = error -> error
      _unexpected -> {:error, :unexpected_result}
    end
  rescue
    _ -> {:error, :participant_raised}
  catch
    _kind, _reason -> {:error, :participant_raised}
  end

  # Registration is boot-time configuration publication (one write per owning
  # app start); the lock serializes concurrent registrations.
  defp update_registry(fun) do
    result =
      :global.trans(
        {@registry_key, self()},
        fn ->
          :persistent_term.put(@registry_key, fun.(:persistent_term.get(@registry_key, %{})))
        end,
        [node()],
        10
      )

    if result == :aborted, do: raise("session lifecycle participant registry is locked")
    :ok
  end
end
