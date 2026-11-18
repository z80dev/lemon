defmodule LemonCore.NativeSessionOwner do
  @moduledoc """
  Authoritative binding from a native session to the session key (chat or
  principal) that created it.

  The router binds a native session the first time it is attached to a run
  (`LemonRouter.ResumeResolver.bind/3`), using that run's own session key.
  The first binding wins and is never rewritten: binding the same session to
  another key is `{:error, :resume_owner_conflict}`.

  Consumers:

    * resume admission refuses a native session bound to another session key,
      and refuses an unbound one for requests carrying channel provenance;
    * chat checkpoint access (`LemonChannels.CheckpointStatusMessage`) only
      treats a native session as the chat's checkpoint owner when it is bound
      to that chat's session key.

  Native sessions created before this binding existed are unbound, so channel
  chats cannot resume them and start a fresh native session instead. Operator,
  TUI and agent-messaging surfaces keep their legacy unbound behaviour.
  """

  alias LemonCore.{ResumeToken, Store}

  @table :native_session_owners

  @doc "Bind `resume` to `session_key` once; a different existing owner is a conflict."
  @spec bind(Store.server(), ResumeToken.t(), binary()) :: :ok | {:error, term()}
  def bind(store \\ Store, %ResumeToken{} = resume, session_key)
      when is_binary(session_key) and session_key != "" do
    key = key(resume)

    case Store.put_new(store, @table, key, session_key, durable: true) do
      :ok ->
        :ok

      {:error, :exists} ->
        case Store.fetch(store, @table, key) do
          {:ok, ^session_key} -> Store.confirm_durable(store)
          {:ok, _other} -> {:error, :resume_owner_conflict}
          {:error, _reason} = error -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "The session key bound to `resume`, `{:ok, nil}` when unbound."
  @spec fetch(Store.server(), ResumeToken.t()) ::
          {:ok, binary() | nil} | {:error, :store_unavailable}
  def fetch(store \\ Store, %ResumeToken{} = resume), do: Store.fetch(store, @table, key(resume))

  @doc "Whether `resume` is bound to exactly `session_key`; unavailable reads are `false`."
  @spec owned_by?(Store.server(), ResumeToken.t(), term()) :: boolean()
  def owned_by?(store \\ Store, resume, session_key)

  def owned_by?(store, %ResumeToken{} = resume, session_key)
      when is_binary(session_key) and session_key != "" do
    fetch(store, resume) == {:ok, session_key}
  end

  def owned_by?(_store, _resume, _session_key), do: false

  defp key(%ResumeToken{engine: engine, value: value}), do: {engine, value}
end
