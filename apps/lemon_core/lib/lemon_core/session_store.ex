defmodule LemonCore.SessionStore do
  @moduledoc """
  Typed store for session-related state.

  Provides a clear, typed API for managing chat state, session index,
  and session metadata. Delegates to `LemonCore.Store` internally and
  emits telemetry events for each operation.

  ## Tables managed

  - `:chat` - Chat state with automatic TTL expiry (24h default)
  - `:sessions_index` - Durable session metadata (agent_id, origin, timestamps, run count)

  ## Telemetry events

  Each operation emits a pair of telemetry events:

  - `[:lemon_core, :store, :put_chat_state, :start/:stop]`
  - `[:lemon_core, :store, :get_chat_state, :start/:stop]`
  - `[:lemon_core, :store, :delete_chat_state, :start/:stop]`
  - `[:lemon_core, :store, :get_session, :start/:stop]`
  - `[:lemon_core, :store, :list_sessions, :start/:stop]`
  - `[:lemon_core, :store, :delete_session, :start/:stop]`
  """

  alias LemonCore.Store

  @type session_key :: term()
  @type chat_state :: map()
  @type session_entry :: %{
          session_key: binary(),
          agent_id: binary(),
          origin: atom(),
          created_at_ms: non_neg_integer(),
          updated_at_ms: non_neg_integer(),
          run_count: non_neg_integer()
        }

  # --- Chat State API ---

  @doc """
  Store chat state for a session scope.

  Chat state is persisted with an automatic TTL (default 24h) and
  expired entries are lazily evicted on read or by periodic sweep.
  """
  @spec put_chat_state(session_key(), chat_state()) :: :ok
  def put_chat_state(scope, state) do
    emit_telemetry(:put_chat_state, %{table: :chat, session_key: scope}, fn ->
      Store.put_chat_state(scope, state)
    end)
  end

  @doc """
  Get chat state for a session scope.

  Returns `nil` if the key doesn't exist or the entry has expired.
  """
  @spec get_chat_state(session_key()) :: chat_state() | nil
  def get_chat_state(scope) do
    emit_telemetry(:get_chat_state, %{table: :chat, session_key: scope}, fn ->
      Store.get_chat_state(scope)
    end)
  end

  @doc """
  Delete chat state for a session scope.
  """
  @spec delete_chat_state(session_key()) :: :ok
  def delete_chat_state(scope) do
    emit_telemetry(:delete_chat_state, %{table: :chat, session_key: scope}, fn ->
      Store.delete_chat_state(scope)
    end)
  end

  # --- Sessions Index API ---

  @doc """
  Get session metadata by session key.

  Returns session entry from the `:sessions_index` table, or `nil` if not found.
  """
  @spec get_session(session_key()) :: session_entry() | nil
  def get_session(session_key) do
    emit_telemetry(:get_session, %{table: :sessions_index, session_key: session_key}, fn ->
      Store.get(:sessions_index, session_key)
    end)
  end

  @doc """
  List all sessions from the sessions index.

  Returns a list of `{session_key, session_entry}` tuples.
  """
  @spec list_sessions() :: [{session_key(), session_entry()}]
  def list_sessions do
    emit_telemetry(:list_sessions, %{table: :sessions_index}, fn ->
      Store.list(:sessions_index)
    end)
  end

  @doc """
  Delete a session from the sessions index.
  """
  @spec delete_session(session_key()) :: :ok | {:error, term()}
  def delete_session(session_key) do
    emit_telemetry(:delete_session, %{table: :sessions_index, session_key: session_key}, fn ->
      Store.delete(:sessions_index, session_key)
    end)
  end

  # Emit start/stop telemetry around an operation.
  @spec emit_telemetry(atom(), map(), (-> result)) :: result when result: term()
  defp emit_telemetry(operation, metadata, fun) do
    start_time = System.monotonic_time()

    :telemetry.execute(
      [:lemon_core, :store, operation, :start],
      %{system_time: System.system_time()},
      metadata
    )

    result = fun.()

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:lemon_core, :store, operation, :stop],
      %{duration: duration},
      metadata
    )

    result
  end
end
