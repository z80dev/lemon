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

  alias LemonCore.MapHelpers
  alias LemonCore.Store.EtsBackend
  alias LemonCore.Store.ReadCache
  require Logger

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
  @compact_history_answer_bytes 16_000
  @compact_history_prompt_bytes 8_000
  @default_introspection_retention_days 7
  @default_introspection_retention_ms @default_introspection_retention_days * 24 * 60 * 60 * 1000
  @default_introspection_query_limit 100
  @max_introspection_query_limit 1_000
  @store_call_timeout_ms 5_000
  @generic_cached_tables [:sessions_index, :telegram_known_targets]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Chat State API

  @spec put_chat_state(term(), map()) :: :ok
  def put_chat_state(scope, state) do
    # Eagerly update read cache before async GenServer cast for consistency
    ReadCache.put(:chat, scope, state)
    GenServer.cast(__MODULE__, {:put_chat_state, scope, state})
  end

  @spec get_chat_state(term()) :: map() | nil
  def get_chat_state(scope) do
    # Fast path: read from ETS cache, bypassing GenServer mailbox
    case ReadCache.get(:chat, scope) do
      nil ->
        # Cache miss — fall through to GenServer for backend lookup
        safe_store_call({:get_chat_state, scope}, nil,
          op: :get_chat_state,
          table: :chat,
          key: scope
        )

      %{expires_at: expires_at} = value when is_integer(expires_at) ->
        if System.system_time(:millisecond) > expires_at do
          # Expired — trigger lazy cleanup through GenServer
          safe_store_call({:get_chat_state, scope}, nil,
            op: :get_chat_state,
            table: :chat,
            key: scope
          )
        else
          value
        end

      value ->
        value
    end
  end

  @spec delete_chat_state(term()) :: :ok
  def delete_chat_state(scope) do
    ReadCache.delete(:chat, scope)
    GenServer.cast(__MODULE__, {:delete_chat_state, scope})
  end

  # Run Events API

  @spec append_run_event(term(), term()) :: :ok
  def append_run_event(run_id, event) do
    # Eagerly update read cache: prepend event to cached record
    case ReadCache.get(:runs, run_id) do
      nil -> :ok
      record -> ReadCache.put(:runs, run_id, %{record | events: [event | record.events]})
    end

    GenServer.cast(__MODULE__, {:append_run_event, run_id, event})
  end

  @spec finalize_run(term(), map()) :: :ok
  def finalize_run(run_id, summary) do
    # Eagerly update read cache with summary
    case ReadCache.get(:runs, run_id) do
      nil -> :ok
      record -> ReadCache.put(:runs, run_id, %{record | summary: summary})
    end

    GenServer.cast(__MODULE__, {:finalize_run, run_id, summary})
  end

  # Progress Mapping API

  @spec put_progress_mapping(term(), integer(), term()) :: :ok
  def put_progress_mapping(scope, progress_msg_id, run_id) do
    ReadCache.put(:progress, {scope, progress_msg_id}, run_id)
    GenServer.cast(__MODULE__, {:put_progress_mapping, scope, progress_msg_id, run_id})
  end

  @spec get_run_by_progress(term(), integer()) :: term() | nil
  def get_run_by_progress(scope, progress_msg_id) do
    # Fast path: direct ETS cache lookup
    case ReadCache.get(:progress, {scope, progress_msg_id}) do
      nil ->
        safe_store_call({:get_run_by_progress, scope, progress_msg_id}, nil,
          op: :get_run_by_progress,
          table: :progress,
          key: {scope, progress_msg_id}
        )

      value ->
        value
    end
  end

  @spec delete_progress_mapping(term(), integer()) :: :ok
  def delete_progress_mapping(scope, progress_msg_id) do
    ReadCache.delete(:progress, {scope, progress_msg_id})
    GenServer.cast(__MODULE__, {:delete_progress_mapping, scope, progress_msg_id})
  end

  # Generic Table API (for use by other lemon_* apps)

  @doc """
  Put a value into a named table.

  This is a generic API for use by other apps (e.g., lemon_core, lemon_automation).
  """
  @spec put(table :: atom(), key :: term(), value :: term()) :: :ok | {:error, term()}
  def put(table, key, value) do
    safe_store_call({:generic_put, table, key, value}, {:error, :store_unavailable},
      op: :put,
      table: table,
      key: key
    )
  end

  @doc """
  Get a value from a named table.

  Returns `nil` if the key doesn't exist.
  """
  @spec get(table :: atom(), key :: term()) :: term() | nil
  def get(table, key) do
    if table in @generic_cached_tables do
      case ReadCache.get(table, key) do
        nil ->
          value =
            safe_store_call({:generic_get, table, key}, nil, op: :get, table: table, key: key)

          if not is_nil(value) do
            ReadCache.put(table, key, value)
          end

          value

        value ->
          value
      end
    else
      safe_store_call({:generic_get, table, key}, nil, op: :get, table: table, key: key)
    end
  end

  @doc """
  Delete a key from a named table.
  """
  @spec delete(table :: atom(), key :: term()) :: :ok | {:error, term()}
  def delete(table, key) do
    safe_store_call({:generic_delete, table, key}, {:error, :store_unavailable},
      op: :delete,
      table: table,
      key: key
    )
  end

  @doc """
  List all key-value pairs in a named table.
  """
  @spec list(table :: atom()) :: [{term(), term()}]
  def list(table) do
    if table in @generic_cached_tables do
      ReadCache.list(table)
    else
      safe_store_call({:generic_list, table}, [], op: :list, table: table, key: :all)
    end
  end

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
    safe_store_call({:get_run_history, session_key, opts}, [],
      op: :get_run_history,
      table: :run_history,
      key: session_key
    )
  end

  @doc """
  Get a specific run by ID.
  """
  @spec get_run(term()) :: map() | nil
  def get_run(run_id) do
    # Fast path: direct ETS cache lookup
    case ReadCache.get(:runs, run_id) do
      nil -> safe_store_call({:get_run, run_id}, nil, op: :get_run, table: :runs, key: run_id)
      value -> value
    end
  end

  # Introspection Event API

  @doc """
  Append a canonical introspection event.
  """
  @spec append_introspection_event(map()) :: :ok | {:error, term()}
  def append_introspection_event(event) when is_map(event) do
    # Validate required fields client-side so callers get immediate feedback
    # on malformed events without blocking on the GenServer.
    event_id = MapHelpers.get_key(event, :event_id)
    ts_ms = MapHelpers.get_key(event, :ts_ms)
    event_type = MapHelpers.get_key(event, :event_type)

    provenance = MapHelpers.get_key(event, :provenance) || :direct
    payload = MapHelpers.get_key(event, :payload) || %{}

    valid_id? = is_binary(event_id) and event_id != ""
    valid_ts? = is_integer(ts_ms) and ts_ms > 0

    valid_type? =
      (is_atom(event_type) and not is_nil(event_type)) or
        (is_binary(event_type) and event_type != "")

    valid_provenance? = provenance in [:direct, :inferred, :unavailable]
    valid_payload? = is_map(payload)

    if valid_id? and valid_ts? and valid_type? and valid_provenance? and valid_payload? do
      GenServer.cast(__MODULE__, {:append_introspection_event, event})
      :ok
    else
      {:error, :invalid_introspection_event}
    end
  end

  def append_introspection_event(_), do: {:error, :invalid_introspection_event}

  @doc """
  List introspection events.

  ## Options

    * `:run_id` - Filter by run id
    * `:session_key` - Filter by session key
    * `:agent_id` - Filter by agent id
    * `:event_type` - Filter by event type
    * `:since_ms` - Include events at or after this timestamp
    * `:until_ms` - Include events at or before this timestamp
    * `:limit` - Maximum number of events to return (default: #{@default_introspection_query_limit})
  """
  @spec list_introspection_events(keyword()) :: [map()]
  def list_introspection_events(opts \\ []) do
    safe_store_call({:list_introspection_events, opts}, [],
      op: :list_introspection_events,
      table: :introspection_log,
      key: :all
    )
  end

  defp safe_store_call(request, fallback, context) do
    GenServer.call(__MODULE__, request, @store_call_timeout_ms)
  catch
    :exit, reason ->
      Logger.warning(
        "Store client call failed op=#{inspect(context[:op])} table=#{inspect(context[:table])} " <>
          "key=#{inspect(context[:key])} reason=#{inspect(store_call_exit_reason(reason))}"
      )

      fallback
  end

  defp store_call_exit_reason({:timeout, {GenServer, :call, _}}), do: :timeout
  defp store_call_exit_reason({:noproc, {GenServer, :call, _}}), do: :noproc
  defp store_call_exit_reason({:shutdown, {GenServer, :call, _}}), do: :shutdown
  defp store_call_exit_reason(_), do: :exit

  defp warm_generic_table_caches(backend, backend_state) do
    Enum.reduce(@generic_cached_tables, backend_state, fn table, acc_state ->
      case backend.list(acc_state, table) do
        {:ok, entries, next_state} ->
          Enum.each(entries, fn {key, value} ->
            ReadCache.put(table, key, value)
          end)

          next_state

        {:error, reason} ->
          Logger.warning(
            "Store cache warm failed table=#{inspect(table)} reason=#{inspect(reason)}"
          )

          acc_state

        other ->
          Logger.warning(
            "Store cache warm failed table=#{inspect(table)} reason=#{inspect(other)}"
          )

          acc_state
      end
    end)
  end

  # GenServer Implementation

  @impl true
  def init(_opts) do
    config =
      Application.get_env(:lemon_core, __MODULE__, [])
      |> merge_runtime_override(Application.get_env(:lemon_core, :store_runtime_override, []))

    backend = Keyword.get(config, :backend, @default_backend)
    backend_opts = Keyword.get(config, :backend_opts, [])
    chat_state_ttl_ms = Keyword.get(config, :chat_state_ttl_ms, @default_chat_state_ttl_ms)

    case backend.init(backend_opts) do
      {:ok, backend_state} ->
        # Initialize read-through cache for high-traffic domains
        ReadCache.init()

        backend_state = warm_generic_table_caches(backend, backend_state)

        # Schedule periodic sweep for expired chat states
        schedule_sweep()

        {:ok,
         %{
           backend: backend,
           backend_state: backend_state,
           chat_state_ttl_ms: chat_state_ttl_ms,
           introspection_retention_ms: @default_introspection_retention_ms
         }}

      {:error, reason} ->
        {:stop, {:backend_init_failed, reason}}
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_expired_chat_states, @sweep_interval_ms)
  end

  defp merge_runtime_override(config, []), do: config

  defp merge_runtime_override(config, override) when is_list(config) and is_list(override) do
    override_without_backend_opts = Keyword.delete(override, :backend_opts)
    merged = Keyword.merge(config, override_without_backend_opts)

    case Keyword.fetch(override, :backend_opts) do
      {:ok, override_backend_opts} ->
        backend_opts =
          Keyword.merge(Keyword.get(config, :backend_opts, []), override_backend_opts)

        Keyword.put(merged, :backend_opts, backend_opts)

      :error ->
        merged
    end
  end

  defp merge_runtime_override(config, _override), do: config

  @impl true
  def handle_call({:get_chat_state, scope}, _from, state) do
    case state.backend.get(state.backend_state, :chat, scope) do
      {:ok, value, backend_state} ->
        # Check if chat state is expired (lazy expiry)
        {result, backend_state} =
          case value do
            %{expires_at: expires_at} when is_integer(expires_at) ->
              now = System.system_time(:millisecond)

              if now > expires_at do
                # Expired - delete and return nil
                case state.backend.delete(backend_state, :chat, scope) do
                  {:ok, next_state} ->
                    ReadCache.delete(:chat, scope)
                    {nil, next_state}

                  {:error, reason} ->
                    log_backend_error(:delete, :chat, scope, reason)
                    {nil, backend_state}

                  other ->
                    log_backend_unexpected(:delete, :chat, scope, other)
                    {nil, backend_state}
                end
              else
                {value, backend_state}
              end

            _ ->
              {value, backend_state}
          end

        {:reply, result, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, :chat, scope, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, :chat, scope, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:get_run_by_progress, scope, progress_msg_id}, _from, state) do
    key = {scope, progress_msg_id}

    case state.backend.get(state.backend_state, :progress, key) do
      {:ok, value, backend_state} ->
        {:reply, value, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, :progress, key, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, :progress, key, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:get_run, run_id}, _from, state) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, value, backend_state} ->
        {:reply, value, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:get_run_history, session_key, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)

    # Try the optimized path first: fetch a limited number of recent rows
    # from SQL (avoids loading the entire table). If the backend doesn't
    # support list_recent/3, fall back to a full table scan.
    result =
      if function_exported?(state.backend, :list_recent, 3) do
        # Fetch more rows than needed because other sessions' entries
        # may be interleaved. If we still don't get enough matches
        # after filtering, we fall back to a full scan below.
        prefetch_limit = limit * 20
        state.backend.list_recent(state.backend_state, :run_history, prefetch_limit)
      else
        state.backend.list(state.backend_state, :run_history)
      end

    case result do
      {:ok, entries, backend_state} ->
        history = filter_run_history(entries, session_key, limit)

        # If we used list_recent and didn't find enough matching entries,
        # the session's history may be buried deeper — fall back to full scan.
        {history, backend_state} =
          if function_exported?(state.backend, :list_recent, 3) and
               length(history) < limit do
            case state.backend.list(state.backend_state, :run_history) do
              {:ok, all_entries, bs} ->
                {filter_run_history(all_entries, session_key, limit), bs}

              _ ->
                {history, backend_state}
            end
          else
            {history, backend_state}
          end

        {:reply, history, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:list, :run_history, session_key, reason)
        {:reply, [], state}

      other ->
        log_backend_unexpected(:list, :run_history, session_key, other)
        {:reply, [], state}
    end
  end

  def handle_cast({:append_introspection_event, event}, state) do
    case normalize_introspection_event(event) do
      {:ok, event} ->
        key = {event.ts_ms, event.event_id}

        case state.backend.put(state.backend_state, :introspection_log, key, event) do
          {:ok, backend_state} ->
            {:noreply, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:put, :introspection_log, key, reason)
            {:noreply, state}

          other ->
            log_backend_unexpected(:put, :introspection_log, key, other)
            {:noreply, state}
        end

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  def handle_call({:list_introspection_events, opts}, _from, state) do
    limit =
      normalize_introspection_limit(Keyword.get(opts, :limit, @default_introspection_query_limit))

    has_field_filters = introspection_opts_have_field_filters?(opts)

    backend_supports_list_recent =
      function_exported?(state.backend, :list_recent, 3)

    # Optimization: when no field-level filters are active AND the backend
    # supports list_recent/3, push ORDER BY + LIMIT into SQL so we don't
    # load all rows into memory.
    result =
      if backend_supports_list_recent and not has_field_filters do
        state.backend.list_recent(state.backend_state, :introspection_log, limit)
      else
        state.backend.list(state.backend_state, :introspection_log)
      end

    case result do
      {:ok, entries, backend_state} ->
        events =
          if backend_supports_list_recent and not has_field_filters do
            # Already limited and ordered by recency from SQL; just extract
            # values and sort by the canonical sort key for stable ordering.
            entries
            |> Enum.map(fn {_key, event} -> event end)
            |> Enum.sort_by(&introspection_sort_key/1, :desc)
          else
            entries
            |> Enum.map(fn {_key, event} -> event end)
            |> Enum.filter(&introspection_event_matches?(&1, opts))
            |> Enum.sort_by(&introspection_sort_key/1, :desc)
            |> Enum.take(limit)
          end

        {:reply, events, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:list, :introspection_log, :all, reason)
        {:reply, [], state}

      other ->
        log_backend_unexpected(:list, :introspection_log, :all, other)
        {:reply, [], state}
    end
  end

  # Generic table handlers

  def handle_call({:generic_put, table, key, value}, _from, state) do
    case state.backend.put(state.backend_state, table, key, value) do
      {:ok, backend_state} ->
        if table in @generic_cached_tables do
          ReadCache.put(table, key, value)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:put, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:put, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_get, table, key}, _from, state) do
    case state.backend.get(state.backend_state, table, key) do
      {:ok, value, backend_state} ->
        {:reply, value, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:get, table, key, reason)
        {:reply, nil, state}

      other ->
        log_backend_unexpected(:get, table, key, other)
        {:reply, nil, state}
    end
  end

  def handle_call({:generic_delete, table, key}, _from, state) do
    case state.backend.delete(state.backend_state, table, key) do
      {:ok, backend_state} ->
        if table in @generic_cached_tables do
          ReadCache.delete(table, key)
        end

        {:reply, :ok, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:delete, table, key, reason)
        {:reply, {:error, reason}, state}

      other ->
        log_backend_unexpected(:delete, table, key, other)
        {:reply, {:error, {:unexpected_backend_response, other}}, state}
    end
  end

  def handle_call({:generic_list, table}, _from, state) do
    case state.backend.list(state.backend_state, table) do
      {:ok, entries, backend_state} ->
        {:reply, entries, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:list, table, :all, reason)
        {:reply, [], state}

      other ->
        log_backend_unexpected(:list, table, :all, other)
        {:reply, [], state}
    end
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

    case state.backend.put(state.backend_state, :chat, scope, value_with_expiry) do
      {:ok, backend_state} ->
        ReadCache.put(:chat, scope, value_with_expiry)
        {:noreply, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:put, :chat, scope, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:put, :chat, scope, other)
        {:noreply, state}
    end
  end

  def handle_cast({:delete_chat_state, scope}, state) do
    case state.backend.delete(state.backend_state, :chat, scope) do
      {:ok, backend_state} ->
        ReadCache.delete(:chat, scope)
        {:noreply, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:delete, :chat, scope, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:delete, :chat, scope, other)
        {:noreply, state}
    end
  end

  def handle_cast({:append_run_event, run_id, event}, state) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, existing, backend_state} ->
        record =
          existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

        record = %{record | events: [event | record.events]}

        case state.backend.put(backend_state, :runs, run_id, record) do
          {:ok, backend_state} ->
            ReadCache.put(:runs, run_id, record)
            {:noreply, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:put, :runs, run_id, reason)
            {:noreply, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:put, :runs, run_id, other)
            {:noreply, %{state | backend_state: backend_state}}
        end

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:noreply, state}
    end
  end

  def handle_cast({:finalize_run, run_id, summary}, state) do
    case state.backend.get(state.backend_state, :runs, run_id) do
      {:ok, existing, backend_state} ->
        record =
          existing || %{events: [], summary: nil, started_at: System.system_time(:millisecond)}

        record = %{record | summary: summary}

        case state.backend.put(backend_state, :runs, run_id, record) do
          {:ok, backend_state} ->
            ReadCache.put(:runs, run_id, record)
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

                  case put_run_history_with_fallback(
                         state.backend,
                         backend_state,
                         history_key,
                         history_data
                       ) do
                    {:ok, bs} ->
                      bs =
                        update_sessions_index(state.backend, bs, session_key, summary, started_at)

                      maybe_index_telegram_message_resume(state.backend, bs, summary)

                    {:error, reason} ->
                      log_backend_error(:put, :run_history, history_key, reason)
                      backend_state
                  end

                true ->
                  backend_state
              end

            {:noreply, %{state | backend_state: backend_state}}

          {:error, reason} ->
            log_backend_error(:put, :runs, run_id, reason)
            {:noreply, %{state | backend_state: backend_state}}

          other ->
            log_backend_unexpected(:put, :runs, run_id, other)
            {:noreply, %{state | backend_state: backend_state}}
        end

      {:error, reason} ->
        log_backend_error(:get, :runs, run_id, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:get, :runs, run_id, other)
        {:noreply, state}
    end
  end

  def handle_cast({:put_progress_mapping, scope, progress_msg_id, run_id}, state) do
    key = {scope, progress_msg_id}

    case state.backend.put(state.backend_state, :progress, key, run_id) do
      {:ok, backend_state} ->
        ReadCache.put(:progress, key, run_id)
        {:noreply, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:put, :progress, key, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:put, :progress, key, other)
        {:noreply, state}
    end
  end

  def handle_cast({:delete_progress_mapping, scope, progress_msg_id}, state) do
    key = {scope, progress_msg_id}

    case state.backend.delete(state.backend_state, :progress, key) do
      {:ok, backend_state} ->
        ReadCache.delete(:progress, key)
        {:noreply, %{state | backend_state: backend_state}}

      {:error, reason} ->
        log_backend_error(:delete, :progress, key, reason)
        {:noreply, state}

      other ->
        log_backend_unexpected(:delete, :progress, key, other)
        {:noreply, state}
    end
  end

  # Update sessions_index when a run is finalized
  defp update_sessions_index(backend, backend_state, session_key, summary, timestamp) do
    case backend.get(backend_state, :sessions_index, session_key) do
      {:ok, existing, backend_state} ->
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

        case backend.put(backend_state, :sessions_index, session_key, session_entry) do
          {:ok, backend_state} ->
            backend_state

          {:error, reason} ->
            log_backend_error(:put, :sessions_index, session_key, reason)
            backend_state

          other ->
            log_backend_unexpected(:put, :sessions_index, session_key, other)
            backend_state
        end

      {:error, reason} ->
        log_backend_error(:get, :sessions_index, session_key, reason)
        backend_state

      other ->
        log_backend_unexpected(:get, :sessions_index, session_key, other)
        backend_state
    end
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

      thread_generation =
        normalize_thread_generation(meta[:thread_generation] || meta["thread_generation"])

      msg_ids =
        [progress_msg_id, user_msg_id]
        |> Enum.map(&normalize_msg_id/1)
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()

      Enum.reduce(msg_ids, backend_state, fn msg_id, bs ->
        key = {account_id || "default", chat_id, topic_id, thread_generation, msg_id}

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

  defp normalize_thread_generation(value) when is_integer(value) and value >= 0, do: value

  defp normalize_thread_generation(value) when is_binary(value) do
    case Integer.parse(value) do
      {generation, _} when generation >= 0 -> generation
      _ -> 0
    end
  end

  defp normalize_thread_generation(_), do: 0

  # We persist resume tokens as-is (often a struct from another app). To avoid
  # compile-time coupling, detect by shape.
  defp resume_token_like?(resume) when is_map(resume) do
    engine = MapHelpers.get_key(resume, :engine)
    value = MapHelpers.get_key(resume, :value)
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

  defp put_run_history_with_fallback(backend, backend_state, history_key, history_data) do
    case backend.put(backend_state, :run_history, history_key, history_data) do
      {:ok, backend_state} ->
        {:ok, backend_state}

      {:error, reason} = error ->
        if blob_too_big_reason?(reason) do
          compact = compact_history_payload(history_data)

          Logger.warning(
            "[LemonCore.Store] run_history payload too large; retrying compact write key=#{inspect(history_key)}"
          )

          case backend.put(backend_state, :run_history, history_key, compact) do
            {:ok, compact_state} ->
              {:ok, compact_state}

            {:error, compact_reason} ->
              {:error, {:compact_run_history_write_failed, compact_reason}}

            other ->
              {:error, {:compact_run_history_write_unexpected, other}}
          end
        else
          error
        end

      other ->
        {:error, {:run_history_write_unexpected, other}}
    end
  end

  defp blob_too_big_reason?({:sqlite_bind_failed, :blob_too_big}), do: true

  defp blob_too_big_reason?(reason) when is_binary(reason) do
    String.contains?(String.downcase(reason), "too big")
  end

  defp blob_too_big_reason?(_), do: false

  defp compact_history_payload(%{} = history_data) do
    summary = Map.get(history_data, :summary)

    history_data
    |> Map.put(:events, [])
    |> Map.put(:summary, compact_summary(summary))
  end

  defp compact_history_payload(other), do: other

  defp compact_summary(nil), do: nil

  defp compact_summary(summary) when is_map(summary) do
    completed =
      summary
      |> map_get_any([:completed, "completed"])
      |> compact_completed()

    summary
    |> map_put_any([:completed, "completed"], completed)
    |> map_update_any(
      [:prompt, "prompt"],
      &truncate_binary_field(&1, @compact_history_prompt_bytes)
    )
    |> deep_truncate_text(@compact_history_answer_bytes)
  end

  defp compact_summary(other), do: other

  defp compact_completed(nil), do: nil

  defp compact_completed(completed) when is_map(completed) do
    completed
    |> map_update_any(
      [:answer, "answer"],
      &truncate_binary_field(&1, @compact_history_answer_bytes)
    )
    |> map_update_any(
      [:error, "error"],
      &truncate_binary_field(&1, @compact_history_prompt_bytes)
    )
  end

  defp compact_completed(other), do: other

  defp map_get_any(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      Map.get(map, key)
    end)
  end

  defp map_get_any(_map, _keys), do: nil

  defp map_put_any(map, keys, value) when is_map(map) and is_list(keys) do
    cond do
      Enum.any?(keys, &Map.has_key?(map, &1)) ->
        Enum.reduce(keys, map, fn key, acc ->
          if Map.has_key?(acc, key), do: Map.put(acc, key, value), else: acc
        end)

      true ->
        Map.put(map, hd(keys), value)
    end
  end

  defp map_put_any(map, _keys, _value), do: map

  defp map_update_any(map, keys, fun)
       when is_map(map) and is_list(keys) and is_function(fun, 1) do
    Enum.reduce(keys, map, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.update!(acc, key, fun), else: acc
    end)
  end

  defp map_update_any(map, _keys, _fun), do: map

  defp deep_truncate_text(term, max_bytes) when is_binary(term) do
    truncate_binary_field(term, max_bytes)
  end

  defp deep_truncate_text(list, max_bytes) when is_list(list) do
    Enum.map(list, &deep_truncate_text(&1, max_bytes))
  end

  defp deep_truncate_text(%{__struct__: _} = struct, max_bytes) do
    struct
    |> Map.from_struct()
    |> deep_truncate_text(max_bytes)
  end

  defp deep_truncate_text(map, max_bytes) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, deep_truncate_text(v, max_bytes)} end)
  end

  defp deep_truncate_text(tuple, max_bytes) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.map(&deep_truncate_text(&1, max_bytes))
    |> List.to_tuple()
  end

  defp deep_truncate_text(term, _max_bytes), do: term

  defp truncate_binary_field(value, max_bytes)
       when is_binary(value) and byte_size(value) > max_bytes do
    prefix = value |> binary_part(0, max_bytes) |> trim_to_valid_utf8()
    "#{prefix}...[truncated #{byte_size(value) - byte_size(prefix)} bytes]"
  end

  defp truncate_binary_field(value, _max_bytes), do: value

  defp trim_to_valid_utf8(<<>>), do: ""

  defp trim_to_valid_utf8(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary
      |> binary_part(0, byte_size(binary) - 1)
      |> trim_to_valid_utf8()
    end
  end

  defp normalize_introspection_event(event) when is_map(event) do
    event_id = MapHelpers.get_key(event, :event_id)
    ts_ms = MapHelpers.get_key(event, :ts_ms)
    event_type = MapHelpers.get_key(event, :event_type)
    payload = MapHelpers.get_key(event, :payload) || %{}
    provenance = MapHelpers.get_key(event, :provenance) || :direct

    with true <- is_binary(event_id) and event_id != "",
         true <- is_integer(ts_ms) and ts_ms > 0,
         true <- valid_introspection_event_type?(event_type),
         true <- valid_introspection_provenance?(provenance),
         true <- is_map(payload) do
      {:ok,
       %{
         event_id: event_id,
         event_type: event_type,
         ts_ms: ts_ms,
         run_id: normalize_optional_binary(MapHelpers.get_key(event, :run_id)),
         session_key: normalize_optional_binary(MapHelpers.get_key(event, :session_key)),
         agent_id: normalize_optional_binary(MapHelpers.get_key(event, :agent_id)),
         parent_run_id: normalize_optional_binary(MapHelpers.get_key(event, :parent_run_id)),
         engine: normalize_optional_binary(MapHelpers.get_key(event, :engine)),
         provenance: provenance,
         payload: payload
       }}
    else
      _ -> {:error, :invalid_introspection_event}
    end
  end

  defp normalize_introspection_event(_), do: {:error, :invalid_introspection_event}

  defp valid_introspection_event_type?(value) when is_atom(value), do: not is_nil(value)
  defp valid_introspection_event_type?(value) when is_binary(value), do: value != ""
  defp valid_introspection_event_type?(_), do: false

  defp valid_introspection_provenance?(value), do: value in [:direct, :inferred, :unavailable]

  defp normalize_optional_binary(value) when is_binary(value) and value != "", do: value
  defp normalize_optional_binary(_), do: nil

  # Returns true when the opts contain any field-level filter beyond :limit.
  # When no field filters are present, we can skip the Elixir-side filter pass
  # and rely on SQL ORDER BY + LIMIT alone.
  defp introspection_opts_have_field_filters?(opts) do
    Keyword.get(opts, :run_id) != nil or
      Keyword.get(opts, :session_key) != nil or
      Keyword.get(opts, :agent_id) != nil or
      Keyword.get(opts, :event_type) != nil or
      Keyword.get(opts, :since_ms) != nil or
      Keyword.get(opts, :until_ms) != nil
  end

  defp introspection_event_matches?(event, opts) do
    run_id = Keyword.get(opts, :run_id)
    session_key = Keyword.get(opts, :session_key)
    agent_id = Keyword.get(opts, :agent_id)
    event_type = Keyword.get(opts, :event_type)
    since_ms = Keyword.get(opts, :since_ms)
    until_ms = Keyword.get(opts, :until_ms)

    event_run_id = MapHelpers.get_key(event, :run_id)
    event_session_key = MapHelpers.get_key(event, :session_key)
    event_agent_id = MapHelpers.get_key(event, :agent_id)
    event_event_type = MapHelpers.get_key(event, :event_type)
    event_ts_ms = MapHelpers.get_key(event, :ts_ms)

    optional_binary_match?(run_id, event_run_id) and
      optional_binary_match?(session_key, event_session_key) and
      optional_binary_match?(agent_id, event_agent_id) and
      optional_event_type_match?(event_type, event_event_type) and
      timestamp_range_match?(event_ts_ms, since_ms, until_ms)
  end

  defp optional_binary_match?(nil, _actual), do: true
  defp optional_binary_match?(expected, actual) when is_binary(expected), do: expected == actual
  defp optional_binary_match?(_expected, _actual), do: false

  defp optional_event_type_match?(nil, _actual), do: true

  defp optional_event_type_match?(expected, actual) when is_list(expected) do
    Enum.any?(expected, &event_type_equal?(&1, actual))
  end

  defp optional_event_type_match?(expected, actual), do: event_type_equal?(expected, actual)

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_atom(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_binary(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_binary(actual),
    do: Atom.to_string(expected) == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_atom(actual),
    do: expected == Atom.to_string(actual)

  defp event_type_equal?(_expected, _actual), do: false

  defp timestamp_range_match?(ts_ms, since_ms, until_ms) when is_integer(ts_ms) do
    lower_ok = is_nil(since_ms) or (is_integer(since_ms) and ts_ms >= since_ms)
    upper_ok = is_nil(until_ms) or (is_integer(until_ms) and ts_ms <= until_ms)
    lower_ok and upper_ok
  end

  defp timestamp_range_match?(_ts_ms, _since_ms, _until_ms), do: false

  defp introspection_sort_key(event) do
    ts_ms =
      case MapHelpers.get_key(event, :ts_ms) do
        ts when is_integer(ts) -> ts
        _ -> 0
      end

    event_id =
      case MapHelpers.get_key(event, :event_id) do
        id when is_binary(id) -> id
        _ -> ""
      end

    {ts_ms, event_id}
  end

  defp normalize_introspection_limit(limit) when is_integer(limit) do
    limit
    |> max(1)
    |> min(@max_introspection_query_limit)
  end

  defp normalize_introspection_limit(_), do: @default_introspection_query_limit

  @impl true
  def handle_info(:sweep_expired_chat_states, state) do
    backend_state = sweep_expired_chat_states(state.backend, state.backend_state)

    backend_state =
      sweep_expired_introspection_events(
        state.backend,
        backend_state,
        state.introspection_retention_ms
      )

    schedule_sweep()
    {:noreply, %{state | backend_state: backend_state}}
  end

  defp sweep_expired_chat_states(backend, backend_state) do
    case backend.list(backend_state, :chat) do
      {:ok, all_chat_states, backend_state} ->
        now = System.system_time(:millisecond)

        # Find and delete expired entries
        Enum.reduce(all_chat_states, backend_state, fn {scope, value}, acc_state ->
          case value do
            %{expires_at: expires_at} when is_integer(expires_at) and now > expires_at ->
              case backend.delete(acc_state, :chat, scope) do
                {:ok, new_state} ->
                  new_state

                {:error, reason} ->
                  log_backend_error(:delete, :chat, scope, reason)
                  acc_state

                other ->
                  log_backend_unexpected(:delete, :chat, scope, other)
                  acc_state
              end

            _ ->
              acc_state
          end
        end)

      {:error, reason} ->
        log_backend_error(:list, :chat, :all, reason)
        backend_state

      other ->
        log_backend_unexpected(:list, :chat, :all, other)
        backend_state
    end
  end

  defp sweep_expired_introspection_events(_backend, backend_state, retention_ms)
       when not is_integer(retention_ms) or retention_ms <= 0 do
    backend_state
  end

  defp sweep_expired_introspection_events(backend, backend_state, retention_ms) do
    case backend.list(backend_state, :introspection_log) do
      {:ok, all_events, backend_state} ->
        cutoff_ms = System.system_time(:millisecond) - retention_ms

        Enum.reduce(all_events, backend_state, fn {key, event}, acc_state ->
          event_ts_ms = introspection_event_timestamp(key, event)

          if is_integer(event_ts_ms) and event_ts_ms < cutoff_ms do
            case backend.delete(acc_state, :introspection_log, key) do
              {:ok, next_state} ->
                next_state

              {:error, reason} ->
                log_backend_error(:delete, :introspection_log, key, reason)
                acc_state

              other ->
                log_backend_unexpected(:delete, :introspection_log, key, other)
                acc_state
            end
          else
            acc_state
          end
        end)

      {:error, reason} ->
        log_backend_error(:list, :introspection_log, :all, reason)
        backend_state

      other ->
        log_backend_unexpected(:list, :introspection_log, :all, other)
        backend_state
    end
  end

  defp introspection_event_timestamp({ts_ms, _event_id}, _event) when is_integer(ts_ms), do: ts_ms

  defp introspection_event_timestamp(_key, event) when is_map(event) do
    case MapHelpers.get_key(event, :ts_ms) do
      ts when is_integer(ts) -> ts
      _ -> nil
    end
  end

  defp introspection_event_timestamp(_key, _event), do: nil

  # Shared filter/sort/limit logic for run history entries.
  # Canonical run history key format: {session_key, started_at_ms, run_id}
  defp filter_run_history(entries, session_key, limit) do
    entries
    |> Enum.filter(fn
      {{key, _ts, _run_id}, _data} -> key == session_key
      _ -> false
    end)
    |> Enum.sort_by(
      fn {{_s, ts, _run_id}, _data} -> ts end,
      :desc
    )
    |> Enum.take(limit)
    |> Enum.map(fn {{_scope, _ts, run_id}, data} -> {run_id, data} end)
  end

  defp log_backend_error(op, table, key, reason) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} failed table=#{inspect(table)} key=#{inspect(key)} " <>
        "reason=#{inspect(reason)}"
    )
  end

  defp log_backend_unexpected(op, table, key, response) do
    Logger.warning(
      "[LemonCore.Store] backend #{op} returned unexpected response table=#{inspect(table)} " <>
        "key=#{inspect(key)} response=#{inspect(response)}"
    )
  end
end
