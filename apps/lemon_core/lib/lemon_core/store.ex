defmodule LemonCore.Store do
  @moduledoc """
  Persistent key-value store with pluggable backends.

  ## Configuration

  Configure the backend in your application config:

      config :lemon_core, LemonCore.Store,
        backend: LemonCore.Store.SqliteBackend,
        backend_opts: [path: "/var/lib/lemon/store"]

  Defaults to `LemonCore.Store.EtsBackend` (in-memory, ephemeral).
  """

  use GenServer

  alias LemonCore.Store.EtsBackend

  @default_backend EtsBackend
  # Default TTL: 24 hours in milliseconds
  @default_chat_state_ttl_ms 24 * 60 * 60 * 1000
  # Sweep interval: 5 minutes in milliseconds
  @sweep_interval_ms 5 * 60 * 1000
  @agent_policy_table :agent_policies
  @channel_policy_table :channel_policies
  @session_policy_table :session_policies
  @runtime_policy_table :runtime_policy
  @runtime_policy_key :global

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Chat State API

  @spec put_chat_state(term(), map()) :: :ok
  def put_chat_state(scope, state),
    do: GenServer.cast(__MODULE__, {:put_chat_state, scope, state})

  @spec get_chat_state(term()) :: map() | nil
  def get_chat_state(scope), do: GenServer.call(__MODULE__, {:get_chat_state, scope})

  @spec delete_chat_state(term()) :: :ok
  def delete_chat_state(scope), do: GenServer.cast(__MODULE__, {:delete_chat_state, scope})

  # Run Events API

  @spec append_run_event(term(), term()) :: :ok
  def append_run_event(run_id, event),
    do: GenServer.cast(__MODULE__, {:append_run_event, run_id, event})

  @spec finalize_run(term(), map()) :: :ok
  def finalize_run(run_id, summary),
    do: GenServer.cast(__MODULE__, {:finalize_run, run_id, summary})

  # Progress Mapping API

  @spec put_progress_mapping(term(), integer(), term()) :: :ok
  def put_progress_mapping(scope, progress_msg_id, run_id) do
    GenServer.cast(__MODULE__, {:put_progress_mapping, scope, progress_msg_id, run_id})
  end

  @spec get_run_by_progress(term(), integer()) :: term() | nil
  def get_run_by_progress(scope, progress_msg_id) do
    GenServer.call(__MODULE__, {:get_run_by_progress, scope, progress_msg_id})
  end

  @spec delete_progress_mapping(term(), integer()) :: :ok
  def delete_progress_mapping(scope, progress_msg_id) do
    GenServer.cast(__MODULE__, {:delete_progress_mapping, scope, progress_msg_id})
  end

  # Generic Table API (for use by other lemon_* apps)

  @doc """
  Put a value into a named table.

  This is a generic API for use by other apps (e.g., lemon_core, lemon_automation).
  """
  @spec put(table :: atom(), key :: term(), value :: term()) :: :ok
  def put(table, key, value), do: GenServer.call(__MODULE__, {:generic_put, table, key, value})

  @doc """
  Get a value from a named table.

  Returns `nil` if the key doesn't exist.
  """
  @spec get(table :: atom(), key :: term()) :: term() | nil
  def get(table, key), do: GenServer.call(__MODULE__, {:generic_get, table, key})

  @doc """
  Delete a key from a named table.
  """
  @spec delete(table :: atom(), key :: term()) :: :ok
  def delete(table, key), do: GenServer.call(__MODULE__, {:generic_delete, table, key})

  @doc """
  List all key-value pairs in a named table.
  """
  @spec list(table :: atom()) :: [{term(), term()}]
  def list(table), do: GenServer.call(__MODULE__, {:generic_list, table})

  # Policy Table API

  @doc """
  Put an agent policy.
  """
  @spec put_agent_policy(agent_id :: term(), policy :: map()) :: :ok
  def put_agent_policy(agent_id, policy), do: put(@agent_policy_table, agent_id, policy)

  @doc """
  Get an agent policy by agent_id.
  """
  @spec get_agent_policy(agent_id :: term()) :: map() | nil
  def get_agent_policy(agent_id), do: get(@agent_policy_table, agent_id)

  @doc """
  Delete an agent policy by agent_id.
  """
  @spec delete_agent_policy(agent_id :: term()) :: :ok
  def delete_agent_policy(agent_id), do: delete(@agent_policy_table, agent_id)

  @doc """
  List all agent policies.
  """
  @spec list_agent_policies() :: [{term(), map()}]
  def list_agent_policies, do: list(@agent_policy_table)

  @doc """
  Put a channel policy.
  """
  @spec put_channel_policy(channel_id :: term(), policy :: map()) :: :ok
  def put_channel_policy(channel_id, policy), do: put(@channel_policy_table, channel_id, policy)

  @doc """
  Get a channel policy by channel_id.
  """
  @spec get_channel_policy(channel_id :: term()) :: map() | nil
  def get_channel_policy(channel_id), do: get(@channel_policy_table, channel_id)

  @doc """
  Delete a channel policy by channel_id.
  """
  @spec delete_channel_policy(channel_id :: term()) :: :ok
  def delete_channel_policy(channel_id), do: delete(@channel_policy_table, channel_id)

  @doc """
  List all channel policies.
  """
  @spec list_channel_policies() :: [{term(), map()}]
  def list_channel_policies, do: list(@channel_policy_table)

  @doc """
  Put a session policy.
  """
  @spec put_session_policy(session_key :: term(), policy :: map()) :: :ok
  def put_session_policy(session_key, policy), do: put(@session_policy_table, session_key, policy)

  @doc """
  Get a session policy by session key.
  """
  @spec get_session_policy(session_key :: term()) :: map() | nil
  def get_session_policy(session_key), do: get(@session_policy_table, session_key)

  @doc """
  Delete a session policy by session key.
  """
  @spec delete_session_policy(session_key :: term()) :: :ok
  def delete_session_policy(session_key), do: delete(@session_policy_table, session_key)

  @doc """
  List all session policies.
  """
  @spec list_session_policies() :: [{term(), map()}]
  def list_session_policies, do: list(@session_policy_table)

  @doc """
  Put global runtime policy overrides.
  """
  @spec put_runtime_policy(policy :: map()) :: :ok
  def put_runtime_policy(policy), do: put(@runtime_policy_table, @runtime_policy_key, policy)

  @doc """
  Get global runtime policy overrides.
  """
  @spec get_runtime_policy() :: map() | nil
  def get_runtime_policy, do: get(@runtime_policy_table, @runtime_policy_key)

  @doc """
  Delete global runtime policy overrides.
  """
  @spec delete_runtime_policy() :: :ok
  def delete_runtime_policy, do: delete(@runtime_policy_table, @runtime_policy_key)

  @doc """
  List runtime policy entries.
  """
  @spec list_runtime_policies() :: [{term(), map()}]
  def list_runtime_policies, do: list(@runtime_policy_table)

  # Run History API

  @doc """
  Get run history for a session key, ordered by most recent first.

  ## Options

    * `:limit` - Maximum number of runs to return (default: 10)

  Returns a list of `{run_id, %{events: [...], summary: %{...}, session_key: key, started_at: ts}}`.
  """
  @spec get_run_history(term(), keyword()) :: [{term(), map()}]
  def get_run_history(session_key, opts \\ []) do
    GenServer.call(__MODULE__, {:get_run_history, session_key, opts})
  end

  @doc """
  Get a specific run by ID.
  """
  @spec get_run(term()) :: map() | nil
  def get_run(run_id) do
    GenServer.call(__MODULE__, {:get_run, run_id})
  end

  # GenServer Implementation

  @impl true
  def init(_opts) do
    config = Application.get_env(:lemon_core, __MODULE__, [])

    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])
    chat_state_ttl_ms = Keyword.get(config, :chat_state_ttl_ms, @default_chat_state_ttl_ms)

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        # Schedule periodic sweep for expired chat states
        schedule_sweep()

        {:ok,
         %{
           backend: backend,
           backend_state: backend_state,
           chat_state_ttl_ms: chat_state_ttl_ms
         }}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired_chat_states, @sweep_interval_ms)
  end

  @impl true
  def handle_call({:get_chat_state, scope}, _from, state) do
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :chat, scope)

    # Check if chat state is expired (lazy expiry)
    {result, backend_state} =
      case value do
        %{expires_at: expires_at} when is_integer(expires_at) ->
          now = System.system_time(:millisecond)

          if now > expires_at do
            # Expired - delete and return nil
            {:ok, backend_state} = state.backend.delete(backend_state, :chat, scope)
            {nil, backend_state}
          else
            {value, backend_state}
          end

        _ ->
          {value, backend_state}
      end

    {:reply, result, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run_by_progress, scope, progress_msg_id}, _from, state) do
    key = {scope, progress_msg_id}
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :progress, key)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    {:ok, value, backend_state} = state.backend.get(state.backend_state, :runs, run_id)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:get_run_history, session_key, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    {:ok, all_history, backend_state} = state.backend.list(state.backend_state, :run_history)

    # Canonical run history key format: {session_key, started_at_ms, run_id}
    history =
      all_history
      |> Enum.filter(fn
        {{key, _ts, _run_id}, _data} ->
          key == session_key

        _ ->
          false
      end)
      |> Enum.sort_by(
        fn
          {{_s, ts, _run_id}, _data} -> ts
        end,
        :desc
      )
      |> Enum.take(limit)
      |> Enum.map(fn
        {{_scope, _ts, run_id}, data} -> {run_id, data}
      end)

    {:reply, history, %{state | backend_state: backend_state}}
  end

  # Generic table handlers

  def handle_call({:generic_put, table, key, value}, _from, state) do
    {:ok, backend_state} = state.backend.put(state.backend_state, table, key, value)
    {:reply, :ok, %{state | backend_state: backend_state}}
  end

  def handle_call({:generic_get, table, key}, _from, state) do
    {:ok, value, backend_state} = state.backend.get(state.backend_state, table, key)
    {:reply, value, %{state | backend_state: backend_state}}
  end

  def handle_call({:generic_delete, table, key}, _from, state) do
    {:ok, backend_state} = state.backend.delete(state.backend_state, table, key)
    {:reply, :ok, %{state | backend_state: backend_state}}
  end

  def handle_call({:generic_list, table}, _from, state) do
    {:ok, entries, backend_state} = state.backend.list(state.backend_state, table)
    {:reply, entries, %{state | backend_state: backend_state}}
  end

  @impl true
  def handle_cast({:put_chat_state, scope, value}, state) do
    # Calculate expires_at based on TTL
    now = System.system_time(:millisecond)
    expires_at = now + state.chat_state_ttl_ms

    # Add expires_at to the value (works with both maps and ChatState structs)
    value_with_expiry =
      case value do
        %{__struct__: _} = struct -> %{struct | expires_at: expires_at}
        map when is_map(map) -> Map.put(map, :expires_at, expires_at)
      end

    {:ok, backend_state} = state.backend.put(state.backend_state, :chat, scope, value_with_expiry)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:delete_chat_state, scope}, state) do
    {:ok, backend_state} = state.backend.delete(state.backend_state, :chat, scope)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:append_run_event, run_id, event}, state) do
    {:ok, existing, backend_state} = state.backend.get(state.backend_state, :runs, run_id)

    record = existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
    record = %{record | events: [event | record.events]}

    {:ok, backend_state} = state.backend.put(backend_state, :runs, run_id, record)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:finalize_run, run_id, summary}, state) do
    {:ok, existing, backend_state} = state.backend.get(state.backend_state, :runs, run_id)

    record = existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
    record = %{record | summary: summary}

    {:ok, backend_state} = state.backend.put(backend_state, :runs, run_id, record)

    session_key = Map.get(summary, :session_key)
    started_at = record.started_at

    # Store by session_key.
    backend_state =
      cond do
        is_binary(session_key) and session_key != "" ->
          history_key = {session_key, started_at, run_id}

          history_data = %{
            events: record.events,
            summary: summary,
            session_key: session_key,
            run_id: run_id,
            started_at: started_at
          }

          {:ok, bs} = state.backend.put(backend_state, :run_history, history_key, history_data)

          bs = update_sessions_index(state.backend, bs, session_key, summary, started_at)
          maybe_index_telegram_message_resume(state.backend, bs, summary)

        true ->
          backend_state
      end

    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:put_progress_mapping, scope, progress_msg_id, run_id}, state) do
    key = {scope, progress_msg_id}
    {:ok, backend_state} = state.backend.put(state.backend_state, :progress, key, run_id)
    {:noreply, %{state | backend_state: backend_state}}
  end

  def handle_cast({:delete_progress_mapping, scope, progress_msg_id}, state) do
    key = {scope, progress_msg_id}
    {:ok, backend_state} = state.backend.delete(state.backend_state, :progress, key)
    {:noreply, %{state | backend_state: backend_state}}
  end

  # Update sessions_index when a run is finalized
  defp update_sessions_index(backend, backend_state, session_key, summary, timestamp) do
    {:ok, existing, backend_state} = backend.get(backend_state, :sessions_index, session_key)

    # Parse agent_id from session_key if not in summary
    agent_id = Map.get(summary, :agent_id) || parse_agent_id(session_key)
    origin = get_in(summary, [:meta, :origin]) || Map.get(summary, :origin) || :unknown

    session_entry =
      case existing do
        nil ->
          %{
            session_key: session_key,
            agent_id: agent_id,
            origin: origin,
            created_at_ms: timestamp,
            updated_at_ms: timestamp,
            run_count: 1
          }

        entry ->
          %{entry | updated_at_ms: timestamp, run_count: (entry[:run_count] || 0) + 1}
      end

    {:ok, backend_state} = backend.put(backend_state, :sessions_index, session_key, session_entry)
    backend_state
  end

  # Index Telegram message IDs to resume tokens so replying to an old message can
  # explicitly switch sessions, even if the replied-to text doesn't include a resume line.
  defp maybe_index_telegram_message_resume(backend, backend_state, summary)
       when is_map(summary) do
    completed = summary[:completed] || summary["completed"]
    session_key = summary[:session_key] || summary["session_key"]
    meta = summary[:meta] || summary["meta"] || %{}

    resume =
      cond do
        is_map(completed) and is_struct(completed) and Map.has_key?(completed, :resume) ->
          Map.get(completed, :resume)

        is_map(completed) ->
          completed[:resume] || completed["resume"]

        true ->
          nil
      end

    with true <- resume_token_like?(resume),
         %{kind: :channel_peer, channel_id: "telegram", account_id: account_id} <-
           parse_session_key(session_key),
         {chat_id, topic_id} <- telegram_ids_from_meta(meta),
         true <- is_integer(chat_id) do
      progress_msg_id = meta[:progress_msg_id] || meta["progress_msg_id"]
      user_msg_id = meta[:user_msg_id] || meta["user_msg_id"]

      msg_ids =
        [progress_msg_id, user_msg_id]
        |> Enum.map(&normalize_msg_id/1)
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()

      Enum.reduce(msg_ids, backend_state, fn msg_id, bs ->
        key = {account_id || "default", chat_id, topic_id, msg_id}

        case backend.put(bs, :telegram_msg_resume, key, resume) do
          {:ok, bs2} -> bs2
          _ -> bs
        end
      end)
    else
      _ -> backend_state
    end
  rescue
    _ -> backend_state
  end

  defp maybe_index_telegram_message_resume(_backend, backend_state, _summary), do: backend_state

  defp normalize_msg_id(nil), do: nil
  defp normalize_msg_id(i) when is_integer(i), do: i

  defp normalize_msg_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp normalize_msg_id(_), do: nil

  # We persist resume tokens as-is (often a struct from another app). To avoid
  # compile-time coupling, detect by shape.
  defp resume_token_like?(resume) when is_map(resume) do
    engine = Map.get(resume, :engine) || Map.get(resume, "engine")
    value = Map.get(resume, :value) || Map.get(resume, "value")
    is_binary(engine) and is_binary(value)
  rescue
    _ -> false
  end

  defp resume_token_like?(_), do: false

  defp parse_session_key(session_key) when is_binary(session_key) do
    case LemonCore.SessionKey.parse(session_key) do
      {:error, _} -> :error
      parsed -> parsed
    end
  rescue
    _ -> :error
  end

  defp parse_session_key(_), do: :error

  defp telegram_ids_from_meta(meta) when is_map(meta) do
    chat_id =
      meta[:chat_id] ||
        meta["chat_id"] ||
        get_in(meta, [:peer, :id]) ||
        get_in(meta, ["peer", "id"])

    topic_id =
      meta[:topic_id] ||
        meta["topic_id"] ||
        get_in(meta, [:peer, :thread_id]) ||
        get_in(meta, ["peer", "thread_id"])

    {normalize_msg_id(chat_id), normalize_msg_id(topic_id)}
  rescue
    _ -> {nil, nil}
  end

  defp parse_agent_id(nil), do: "default"

  defp parse_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      _ -> "default"
    end
  end

  defp parse_agent_id(_), do: "default"

  @impl true
  def handle_info(:sweep_expired_chat_states, state) do
    backend_state = sweep_expired_chat_states(state.backend, state.backend_state)
    schedule_sweep()
    {:noreply, %{state | backend_state: backend_state}}
  end

  defp sweep_expired_chat_states(backend, backend_state) do
    {:ok, all_chat_states, backend_state} = backend.list(backend_state, :chat)
    now = System.system_time(:millisecond)

    # Find and delete expired entries
    Enum.reduce(all_chat_states, backend_state, fn {scope, value}, acc_state ->
      case value do
        %{expires_at: expires_at} when is_integer(expires_at) and now > expires_at ->
          {:ok, new_state} = backend.delete(acc_state, :chat, scope)
          new_state

        _ ->
          acc_state
      end
    end)
  end
end
