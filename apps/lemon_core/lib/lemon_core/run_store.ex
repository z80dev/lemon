defmodule LemonCore.RunStore do
  @moduledoc """
  Run records and the per-session index of finalized runs.

  Owns two tables:

    * `:runs` — one record per run id: `%{events: [...], summary: map | nil,
      started_at: ms}`. Events are prepended as they stream
      (`append_event/3`, asynchronous); `finalize/3` records the summary.
      Declared ephemeral, because a run's events are read back rarely and the
      durable copy is the run history (`LemonCore.RunHistoryStore`).
    * `:sessions_index` — one entry per session key that has finalized a run,
      with agent id, origin, timestamps and a run count. Mirrored into the
      read cache for the session listings.

  ## Finalize hooks

  When a run with a session key is finalized, the hooks registered for the
  store are invoked, in the finalizing process and in registration order,
  with

      %{store: server, run_id: run_id, record: record, summary: summary,
        session_key: session_key, started_at: started_at}

  The reference runtime wires run history and memory ingest this way, so this
  module names neither:

      config :lemon_core, LemonCore.RunStore,
        finalize_hooks: [
          {LemonCore.RunHistoryStore, :handle_finalize_run},
          {LemonMemory.Ingest, :handle_finalize_run}
        ]

  Configured hooks apply to the default store; `register_finalize_hook/2`
  adds one at runtime for any store instance, and the registration survives
  a store restart. A hook that raises is logged and skipped
  (`LemonCore.Store.Hooks`); it never fails the finalization.
  """

  use LemonCore.Store.Table,
    tables: [
      runs: [cached: true, persistence: :ephemeral],
      sessions_index: [cached: true]
    ]

  alias LemonCore.{RunHistoryStore, Store}
  alias LemonCore.Store.Hooks

  @runs :runs
  @sessions_index :sessions_index
  @hook_kind :finalize_run_hooks

  @type record :: %{events: [term()], summary: map() | nil, started_at: integer()}

  @doc "The record for `run_id`, or `nil`."
  @spec get(Store.server(), term()) :: record() | nil
  def get(server \\ Store, run_id), do: Store.get(server, @runs, run_id)

  @doc """
  Append an event to a run's record, creating the record on the first event.

  Asynchronous, because runs stream events far more often than anything reads
  them back; `LemonCore.Store.ping/1` is the barrier when a caller needs the
  write to have landed.
  """
  @spec append_event(Store.server(), term(), term()) :: :ok
  def append_event(server \\ Store, run_id, event) do
    Store.update_async(server, @runs, run_id, new_record(), fn record ->
      %{record | events: [event | record.events]}
    end)
  end

  @doc """
  Record a run's summary, index its session and fire the finalize hooks.

  Synchronous: when it returns `:ok`, the record is written, the session
  index is updated and every hook has run. A run whose summary carries no
  `:session_key` is recorded without indexing or hooks.
  """
  @spec finalize(Store.server(), term(), map()) :: :ok | {:error, term()}
  def finalize(server \\ Store, run_id, summary) when is_map(summary) do
    case Store.update(server, @runs, run_id, new_record(), &%{&1 | summary: summary}) do
      {:ok, record} ->
        session_key = Map.get(summary, :session_key)

        if is_binary(session_key) and session_key != "" do
          index_session(server, session_key, summary, record.started_at)

          Hooks.invoke(
            finalize_hooks(server),
            %{
              store: server,
              run_id: run_id,
              record: record,
              summary: summary,
              session_key: session_key,
              started_at: record.started_at
            },
            op: :finalize_run,
            store: server,
            run_id: run_id
          )
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Register a hook invoked after each run with a session key is finalized."
  @spec register_finalize_hook(Store.server(), Hooks.hook()) :: :ok
  def register_finalize_hook(server \\ Store, hook) when is_atom(server) do
    Hooks.register(server, @hook_kind, hook)
  end

  @doc "Remove a previously registered finalize hook."
  @spec unregister_finalize_hook(Store.server(), Hooks.hook()) :: :ok
  def unregister_finalize_hook(server \\ Store, hook) when is_atom(server) do
    Hooks.unregister(server, @hook_kind, hook)
  end

  @doc "Run history for a session, newest first (`LemonCore.RunHistoryStore`)."
  @spec history(binary(), keyword()) :: [{term(), map()}]
  def history(session_key, opts \\ []) when is_binary(session_key) and is_list(opts) do
    RunHistoryStore.get(session_key, opts)
  end

  @doc "Every indexed session as `{session_key, entry}`."
  @spec list_sessions(Store.server()) :: [{term(), map()}]
  def list_sessions(server \\ Store), do: Store.list(server, @sessions_index)

  @spec delete_session_index(Store.server(), term()) :: :ok | {:error, term()}
  def delete_session_index(server \\ Store, session_key) do
    Store.delete(server, @sessions_index, session_key)
  end

  @spec delete_history(term()) :: :ok
  def delete_history(session_key) do
    RunHistoryStore.delete_session(session_key)
  end

  @doc "Forget a session: its index entry and its run history."
  @spec delete_session(term()) :: :ok
  def delete_session(session_key) do
    _ = delete_session_index(session_key)
    delete_history(session_key)
  end

  defp new_record do
    %{events: [], summary: nil, started_at: System.system_time(:millisecond)}
  end

  defp index_session(server, session_key, summary, timestamp) do
    # The agent id comes from the summary when the caller knows it, else from
    # the session key's `agent:<id>:...` shape.
    agent_id = Map.get(summary, :agent_id) || parse_agent_id(session_key)
    origin = get_in(summary, [:meta, :origin]) || Map.get(summary, :origin) || :unknown

    Store.update(server, @sessions_index, session_key, nil, fn
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
    end)
  end

  defp parse_agent_id(session_key) when is_binary(session_key) do
    case String.split(session_key, ":") do
      ["agent", agent_id | _] -> agent_id
      _ -> "default"
    end
  end

  defp parse_agent_id(_), do: "default"

  # Configured hooks belong to the default store; runtime registrations are
  # per instance. Deduplicated, so a collaborator wired both ways runs once.
  defp finalize_hooks(server) do
    configured =
      if server == Store do
        :lemon_core
        |> Application.get_env(__MODULE__, [])
        |> Keyword.get(:finalize_hooks, [])
        |> List.wrap()
      else
        []
      end

    Enum.uniq(configured ++ Hooks.registered(server, @hook_kind))
  end
end
