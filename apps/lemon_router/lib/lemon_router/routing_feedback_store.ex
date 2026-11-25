defmodule LemonRouter.RoutingFeedbackStore do
  @moduledoc """
  SQLite-backed store for routing feedback samples.

  Records one row per finalized run, keyed by task fingerprint.  Provides
  aggregate queries over outcome rates, durations, and sample sizes so the
  router can suggest a model that has outperformed the configured default
  (`best_model_for_context/2`).

  ## Design

  - Separate SQLite database (`routing_feedback.sqlite3`) — never touches the
    main store or run-history DB.
  - Writes are async casts (fire-and-forget).  Read failures return
    `{:insufficient_data, n}` rather than raising.
  - A `min_sample_size` threshold (default `#{__MODULE__}.min_sample_size/0`)
    guards aggregates so the router never acts on statistically weak data, and a
    `min_success_rate` floor (default `0.75`) keeps a failing model from ever
    being suggested.
  - The write path is gated before Bus publication by `LemonMemory.Ingest`;
    router reads are gated by the caller before consulting historical data.

  ## Usage

      # Called by the router-owned Bus subscriber when routing_feedback flag is on
      RoutingFeedbackStore.record(fingerprint_key, outcome, duration_ms)

      # Called by router to read aggregate stats
      case RoutingFeedbackStore.aggregate(fingerprint_key) do
        {:ok, agg} -> agg.success_rate
        {:insufficient_data, _n} -> nil
      end

  ## Configuration

      config :lemon_router, LemonRouter.RoutingFeedbackStore,
        path: "~/.lemon/store",          # directory — routing_feedback.sqlite3 created inside
        min_sample_size: 5,              # minimum samples before returning aggregate
        min_success_rate: 0.75,          # suggested models must succeed at least this often
        retention_ms: 30 * 24 * 3600_000,# 30 days (default)
        subscribe?: true                 # consume routing_feedback Bus events

  Independently named stores can pass `subscribe?: false` to accept only
  explicit calls and avoid duplicating the process-wide Bus subscription.
  """

  use GenServer
  require Logger

  alias LemonCore.{Bus, Event}
  alias LemonCore.Events.RoutingFeedback
  alias Exqlite.Sqlite3

  @default_min_sample_size 5
  @default_min_success_rate 0.75
  @default_retention_ms 30 * 24 * 60 * 60 * 1000
  @sweep_interval_ms 60 * 60 * 1000
  @filename "routing_feedback.sqlite3"

  @schema_sql """
  CREATE TABLE IF NOT EXISTS routing_feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    fingerprint_key TEXT NOT NULL,
    outcome TEXT NOT NULL,
    duration_ms INTEGER,
    recorded_at_ms INTEGER NOT NULL
  );
  """

  @index_sql """
  CREATE INDEX IF NOT EXISTS idx_routing_feedback_fingerprint
  ON routing_feedback (fingerprint_key, recorded_at_ms DESC);
  """

  @insert_sql """
  INSERT INTO routing_feedback (fingerprint_key, outcome, duration_ms, recorded_at_ms)
  VALUES (?1, ?2, ?3, ?4)
  """

  @aggregate_sql """
  SELECT outcome, COUNT(*) as count, AVG(duration_ms) as avg_duration_ms
  FROM routing_feedback
  WHERE fingerprint_key = ?1
  GROUP BY outcome
  """

  @count_sql """
  SELECT COUNT(*) FROM routing_feedback WHERE fingerprint_key = ?1
  """

  @sweep_sql """
  DELETE FROM routing_feedback WHERE recorded_at_ms < ?1
  """

  @list_fingerprints_sql """
  SELECT fingerprint_key,
         COUNT(*) AS total,
         SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END) AS success_count,
         CAST(ROUND(AVG(CASE WHEN duration_ms IS NOT NULL THEN CAST(duration_ms AS REAL) END)) AS INTEGER) AS avg_duration_ms,
         MAX(recorded_at_ms) AS last_seen_ms
  FROM routing_feedback
  GROUP BY fingerprint_key
  ORDER BY total DESC
  """

  @store_stats_sql """
  SELECT COUNT(*) AS total_records,
         COUNT(DISTINCT fingerprint_key) AS unique_fingerprints,
         MIN(recorded_at_ms) AS oldest_ms,
         MAX(recorded_at_ms) AS newest_ms
  FROM routing_feedback
  """

  # Keys under a context share the `context|` prefix. A half-open range on the
  # indexed column selects exactly that prefix (`}` follows `|`), so the lookup
  # is an index range scan with no LIKE metacharacters to escape.
  @best_model_sql """
  SELECT fingerprint_key,
         COUNT(*) AS total,
         SUM(CASE WHEN outcome='success' THEN 1 ELSE 0 END) AS success_count
  FROM routing_feedback
  WHERE fingerprint_key >= ?1 AND fingerprint_key < ?2
  GROUP BY fingerprint_key
  """

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @doc """
  Returns the configured minimum sample size threshold.
  """
  @spec min_sample_size() :: pos_integer()
  def min_sample_size do
    config = Application.get_env(:lemon_router, __MODULE__, [])
    Keyword.get(config, :min_sample_size, @default_min_sample_size)
  end

  @doc """
  Record a routing feedback sample for a fingerprint key.

  Fire-and-forget cast.  Returns `:ok` immediately.  If the GenServer is not
  running, the call is silently swallowed (non-fatal).
  """
  @spec record(String.t(), atom(), integer() | nil) :: :ok
  def record(fingerprint_key, outcome, duration_ms \\ nil)
      when is_binary(fingerprint_key) and is_atom(outcome) do
    GenServer.cast(__MODULE__, {:record, fingerprint_key, Atom.to_string(outcome), duration_ms})
  catch
    :exit, _ -> :ok
  end

  @doc """
  List all fingerprint keys with summary stats.

  Returns `{:ok, [map()]}` where each map has:
  `fingerprint_key`, `total`, `success_count`, `avg_duration_ms`, `last_seen_ms`.

  Returns `{:error, :not_running}` if the GenServer is not available.
  """
  @spec list_fingerprints() :: {:ok, [map()]} | {:error, term()}
  def list_fingerprints do
    GenServer.call(__MODULE__, :list_fingerprints, 5_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Return store-level summary statistics.

  Returns `{:ok, map()}` with keys:
  `total_records`, `unique_fingerprints`, `oldest_ms`, `newest_ms`.
  """
  @spec store_stats() :: {:ok, map()} | {:error, term()}
  def store_stats do
    GenServer.call(__MODULE__, :store_stats, 5_000)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Return aggregate stats for a fingerprint key.

  Returns `{:ok, agg}` when enough samples are available, or
  `{:insufficient_data, sample_count}` when below the `min_sample_size`
  threshold.

  ## Aggregate map

      %{
        fingerprint_key: "code|bash,read_file|...",
        total: 12,
        outcomes: %{success: 8, partial: 2, failure: 2},
        success_rate: 0.667,
        mean_duration_ms: 4200
      }
  """
  @spec aggregate(String.t()) ::
          {:ok, map()} | {:insufficient_data, non_neg_integer()}
  def aggregate(fingerprint_key) when is_binary(fingerprint_key) do
    GenServer.call(__MODULE__, {:aggregate, fingerprint_key}, 5_000)
  catch
    :exit, _ -> {:insufficient_data, 0}
  end

  @doc """
  Suggest a model for a context key (3-segment prefix) instead of `default_model`.

  Queries all fingerprint keys that share the same `family|toolset|workspace`
  prefix and aggregates success counts per model (across providers). A model is
  a candidate when it has at least `min_sample_size` samples and a success rate
  of at least `min_success_rate`.

  History is advisory: the configured default stays in charge unless it has
  itself been measured in this context (`min_sample_size` samples) and the best
  candidate's success rate is strictly higher. A default changed after the
  samples were taken therefore has no samples and is kept.

  Returns `{:ok, model}` for a suggestion, or `:keep_default` when there is
  none (including when the store cannot be read).
  """
  @spec best_model_for_context(String.t(), String.t() | nil) :: {:ok, String.t()} | :keep_default
  def best_model_for_context(context_key, default_model) when is_binary(context_key) do
    GenServer.call(__MODULE__, {:best_model_for_context, context_key, default_model}, 5_000)
  catch
    :exit, _ -> :keep_default
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Keyword.merge(Application.get_env(:lemon_router, __MODULE__, []), opts)

    if Keyword.get(config, :subscribe?, true) do
      Bus.subscribe("routing_feedback")
    end

    path = resolve_path(config)
    retention_ms = Keyword.get(config, :retention_ms, @default_retention_ms)
    min_samples = Keyword.get(config, :min_sample_size, @default_min_sample_size)
    min_success_rate = Keyword.get(config, :min_success_rate, @default_min_success_rate)

    {:ok,
     %{
       conn: nil,
       stmts: nil,
       path: path,
       retention_ms: retention_ms,
       min_sample_size: min_samples,
       min_success_rate: min_success_rate,
       sweep_scheduled?: false
     }}
  end

  @impl true
  def handle_cast({:record, fingerprint_key, outcome_str, duration_ms}, state) do
    {:noreply, record_sample(state, fingerprint_key, outcome_str, duration_ms)}
  end

  @impl true
  def handle_call({:aggregate, fingerprint_key}, _from, state) do
    case ensure_open(state) do
      {:ok, state} ->
        result = do_aggregate(state, fingerprint_key)
        {:reply, result, state}

      {:error, _reason, state} ->
        {:reply, {:insufficient_data, 0}, state}
    end
  end

  @impl true
  def handle_call(:list_fingerprints, _from, state) do
    case ensure_open(state) do
      {:ok, state} -> {:reply, do_list_fingerprints(state), state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:store_stats, _from, state) do
    case ensure_open(state) do
      {:ok, state} -> {:reply, do_store_stats(state), state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:best_model_for_context, context_key, default_model}, _from, state) do
    case ensure_open(state) do
      {:ok, state} ->
        {:reply, do_best_model_for_context(state, context_key, default_model), state}

      {:error, _reason, state} ->
        {:reply, :keep_default, state}
    end
  end

  @impl true
  def handle_info(
        %Event{
          type: :routing_feedback,
          payload: %RoutingFeedback{
            fingerprint_key: fingerprint_key,
            outcome: outcome,
            duration_ms: duration_ms
          }
        },
        state
      )
      when is_binary(fingerprint_key) and is_atom(outcome) do
    {:noreply, record_sample(state, fingerprint_key, Atom.to_string(outcome), duration_ms)}
  end

  # Legacy free-form payload, accepted for one deprecation cycle. See
  # docs/platform/bus-events.md §4.3.
  def handle_info(%Event{type: :routing_feedback, payload: payload}, state)
      when is_map(payload) and not is_struct(payload) do
    handle_info(
      %Event{
        type: :routing_feedback,
        ts_ms: Event.now_ms(),
        payload: RoutingFeedback.from_map(payload)
      },
      state
    )
  end

  @impl true
  def handle_info(:sweep, state) do
    case ensure_open(state) do
      {:ok, state} ->
        cutoff = System.system_time(:millisecond) - state.retention_ms

        with :ok <- Sqlite3.reset(state.stmts.sweep),
             :ok <- Sqlite3.bind(state.stmts.sweep, [cutoff]),
             :done <- Sqlite3.step(state.conn, state.stmts.sweep) do
          :ok
        else
          err -> Logger.warning("[RoutingFeedbackStore] sweep failed: #{inspect(err)}")
        end

        {:noreply, schedule_sweep(%{state | sweep_scheduled?: false})}

      {:error, _reason, state} ->
        {:noreply, %{state | sweep_scheduled?: false}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Sqlite3.close(conn)
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private helpers ────────────────────────────────────────────────────────────

  defp record_sample(state, fingerprint_key, outcome_str, duration_ms) do
    case ensure_open(state) do
      {:ok, state} ->
        do_record_sample(state, fingerprint_key, outcome_str, duration_ms)

      {:error, _reason, state} ->
        state
    end
  end

  defp do_record_sample(state, fingerprint_key, outcome_str, duration_ms) do
    now = System.system_time(:millisecond)

    with :ok <- Sqlite3.reset(state.stmts.insert),
         :ok <- Sqlite3.bind(state.stmts.insert, [fingerprint_key, outcome_str, duration_ms, now]),
         :done <- Sqlite3.step(state.conn, state.stmts.insert) do
      :ok
    else
      err ->
        Logger.warning("[RoutingFeedbackStore] record failed: #{inspect(err)}")
    end

    state
  end

  defp ensure_open(%{conn: conn} = state) when not is_nil(conn), do: {:ok, state}

  defp ensure_open(state) do
    with :ok <- File.mkdir_p(Path.dirname(state.path)),
         {:ok, conn} <- Sqlite3.open(state.path),
         :ok <- init_db(conn),
         {:ok, stmts} <- prepare_statements(conn) do
      {:ok, schedule_sweep(%{state | conn: conn, stmts: stmts})}
    else
      {:error, reason} ->
        Logger.error("[RoutingFeedbackStore] open failed: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp do_aggregate(state, fingerprint_key) do
    total = fetch_count(state, fingerprint_key)

    if total < state.min_sample_size do
      {:insufficient_data, total}
    else
      case fetch_outcome_rows(state, fingerprint_key) do
        {:ok, rows} ->
          {:ok, build_aggregate(fingerprint_key, total, rows)}

        {:error, reason} ->
          Logger.warning("[RoutingFeedbackStore] aggregate query failed: #{inspect(reason)}")
          {:insufficient_data, total}
      end
    end
  end

  defp fetch_count(state, fingerprint_key) do
    with :ok <- Sqlite3.reset(state.stmts.count),
         :ok <- Sqlite3.bind(state.stmts.count, [fingerprint_key]),
         {:row, [n]} <- Sqlite3.step(state.conn, state.stmts.count) do
      n
    else
      _ -> 0
    end
  end

  defp fetch_outcome_rows(state, fingerprint_key) do
    with :ok <- Sqlite3.reset(state.stmts.aggregate),
         :ok <- Sqlite3.bind(state.stmts.aggregate, [fingerprint_key]),
         {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.aggregate) do
      {:ok, rows}
    else
      err -> {:error, err}
    end
  end

  defp build_aggregate(fingerprint_key, total, rows) do
    outcomes =
      Enum.reduce(rows, %{}, fn [outcome_str, count, _avg], acc ->
        atom = safe_to_atom(outcome_str)
        Map.put(acc, atom, count)
      end)

    mean_duration =
      rows
      |> Enum.filter(fn [_, _, avg] -> is_number(avg) end)
      |> case do
        [] ->
          nil

        valid_rows ->
          weighted_sum =
            Enum.reduce(valid_rows, 0.0, fn [_, count, avg], acc ->
              acc + count * avg
            end)

          total_with_duration = Enum.sum(Enum.map(valid_rows, fn [_, count, _] -> count end))
          if total_with_duration > 0, do: weighted_sum / total_with_duration, else: nil
      end

    success_count = Map.get(outcomes, :success, 0)
    success_rate = if total > 0, do: success_count / total, else: 0.0

    %{
      fingerprint_key: fingerprint_key,
      total: total,
      outcomes: outcomes,
      success_rate: Float.round(success_rate, 4),
      mean_duration_ms: if(mean_duration, do: round(mean_duration))
    }
  end

  defp do_list_fingerprints(state) do
    with :ok <- Sqlite3.reset(state.stmts.list_fingerprints),
         {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.list_fingerprints) do
      entries =
        Enum.map(rows, fn [key, total, success_count, avg_dur, last_seen] ->
          %{
            fingerprint_key: key,
            total: total,
            success_count: success_count || 0,
            avg_duration_ms: avg_dur,
            last_seen_ms: last_seen
          }
        end)

      {:ok, entries}
    else
      err ->
        Logger.warning("[RoutingFeedbackStore] list_fingerprints failed: #{inspect(err)}")
        {:error, :query_failed}
    end
  end

  defp do_store_stats(state) do
    with :ok <- Sqlite3.reset(state.stmts.store_stats),
         {:row, [total_records, unique_fps, oldest_ms, newest_ms]} <-
           Sqlite3.step(state.conn, state.stmts.store_stats) do
      {:ok,
       %{
         total_records: total_records,
         unique_fingerprints: unique_fps,
         oldest_ms: oldest_ms,
         newest_ms: newest_ms
       }}
    else
      err ->
        Logger.warning("[RoutingFeedbackStore] store_stats failed: #{inspect(err)}")
        {:error, :query_failed}
    end
  end

  defp safe_to_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> :unknown
  end

  defp resolve_path(config) do
    raw =
      Keyword.get(config, :path) ||
        Application.get_env(:lemon_core, LemonCore.Store, [])
        |> Keyword.get(:backend_opts, [])
        |> Keyword.get(:path, "~/.lemon/store")

    dir = LemonCore.Paths.store_dir(raw)
    Path.join(dir, @filename)
  end

  defp init_db(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode=WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous=NORMAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA temp_store=MEMORY"),
         :ok <- Sqlite3.execute(conn, "PRAGMA busy_timeout=5000"),
         :ok <- Sqlite3.execute(conn, @schema_sql),
         :ok <- Sqlite3.execute(conn, @index_sql) do
      :ok
    end
  end

  defp prepare_statements(conn) do
    with {:ok, insert} <- Sqlite3.prepare(conn, @insert_sql),
         {:ok, aggregate} <- Sqlite3.prepare(conn, @aggregate_sql),
         {:ok, count} <- Sqlite3.prepare(conn, @count_sql),
         {:ok, sweep} <- Sqlite3.prepare(conn, @sweep_sql),
         {:ok, list_fingerprints} <- Sqlite3.prepare(conn, @list_fingerprints_sql),
         {:ok, store_stats} <- Sqlite3.prepare(conn, @store_stats_sql),
         {:ok, best_model} <- Sqlite3.prepare(conn, @best_model_sql) do
      {:ok,
       %{
         insert: insert,
         aggregate: aggregate,
         count: count,
         sweep: sweep,
         list_fingerprints: list_fingerprints,
         store_stats: store_stats,
         best_model: best_model
       }}
    else
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp do_best_model_for_context(state, context_key, default_model) do
    with :ok <- Sqlite3.reset(state.stmts.best_model),
         :ok <-
           Sqlite3.bind(state.stmts.best_model, [context_key <> "|", context_key <> "}"]),
         {:ok, rows} <- Sqlite3.fetch_all(state.conn, state.stmts.best_model) do
      rows
      |> models_by_stats()
      |> suggest(state, default_model)
    else
      err ->
        Logger.warning("[RoutingFeedbackStore] best_model_for_context failed: #{inspect(err)}")
        :keep_default
    end
  end

  # Aggregate by model (last segment of fingerprint_key) across providers.
  defp models_by_stats(rows) do
    Enum.reduce(rows, %{}, fn [fp_key, total, success_count], acc ->
      model = fp_key |> String.split("|") |> List.last()
      prev = Map.get(acc, model, %{total: 0, success_count: 0})

      Map.put(acc, model, %{
        total: prev.total + total,
        success_count: prev.success_count + (success_count || 0)
      })
    end)
  end

  defp suggest(by_model, state, default_model) do
    best =
      by_model
      |> Enum.filter(fn {model, %{total: total} = stats} ->
        model != "-" and total >= state.min_sample_size and
          success_rate(stats) >= state.min_success_rate
      end)
      |> Enum.max_by(fn {_model, stats} -> success_rate(stats) end, fn -> nil end)

    default_stats =
      by_model
      |> Enum.filter(fn {model, _stats} -> default_model?(model, default_model) end)
      |> Enum.reduce(%{total: 0, success_count: 0}, fn {_model, stats}, acc ->
        %{total: acc.total + stats.total, success_count: acc.success_count + stats.success_count}
      end)

    cond do
      is_nil(best) ->
        :keep_default

      not is_binary(default_model) ->
        {:ok, elem(best, 0)}

      default_model?(elem(best, 0), default_model) ->
        :keep_default

      default_stats.total >= state.min_sample_size and
          success_rate(elem(best, 1)) > success_rate(default_stats) ->
        {:ok, elem(best, 0)}

      true ->
        :keep_default
    end
  end

  defp success_rate(%{total: total, success_count: success}), do: success / max(total, 1)

  # Samples record the model id a run reported; the default is a configured
  # selector that may carry a `provider:` or `provider/` prefix.
  defp default_model?(model, default_model) when is_binary(default_model) do
    model == default_model or model == unprefixed(default_model)
  end

  defp default_model?(_model, _default_model), do: false

  defp unprefixed(selector) do
    case String.split(selector, [":", "/"], parts: 2) do
      [_provider, model] -> model
      [model] -> model
    end
  end

  defp schedule_sweep(%{sweep_scheduled?: true} = state), do: state

  defp schedule_sweep(state) do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
    %{state | sweep_scheduled?: true}
  end
end
