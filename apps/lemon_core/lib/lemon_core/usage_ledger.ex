defmodule LemonCore.UsageLedger do
  @moduledoc """
  Records every finalized run's token usage and cost into `LemonCore.UsageStore`.

  Wired as a `LemonCore.Store` finalize-run hook (see `config/config.exs`):

      finalize_run_hooks: [{LemonCore.UsageLedger, :handle_finalize_run}]

  The hook casts to this server to avoid calling Store from inside Store.
  Native run/usage occurrence IDs are inserted durably before updating bounded
  daily projections. Replayed completion survives ledger restart without billing
  twice. `UsageStore.records/1` is the canonical, unbounded-by-session ledger;
  daily projections are known-cost subtotals, not spend enforcement authority.

  Projection is replay-safe and fail-closed. A `:usage_projections` marker is
  inserted (`:pending`) before the occurrence and set `:done` after the daily
  record includes it. The daily record is read strictly and replaced by
  compare-and-swap; while an occurrence is applied but not yet marked done its
  ID sits in the record's `:pending_occurrences` list, so a replay
  after a crash or failed write repairs a missing projection without counting
  it twice. A failed read never resets a day: the record call returns an error
  and the replay repairs it. The `:current` summary is derived from today's
  daily record rather than incremented separately.

  An occurrence recorded before markers existed may or may not be counted in
  its day (the old ledger could commit the occurrence and fail the aggregate).
  Its first replay marks the marker `intent: :legacy_rebuild`, then rebuilds
  that day from the canonical occurrences attributed to it (by marker date,
  else by the occurrence's own timestamp), so it is neither lost nor counted
  twice. Any replay that finds a pending marker over a stored occurrence whose
  ID is not in the day's `:pending_occurrences` cannot tell whether the day
  counts it (for example a legacy migration interrupted before or during its
  rebuild), so it rebuilds the day canonically instead of adding to it. A
  pre-marker occurrence without a timestamp cannot be attributed to a day and
  is left out of rebuilt days.

  Each UTC day's record (key `"YYYY-MM-DD"`) keeps the historical shape read by
  `usage.cost` and `LemonCore.UsageDiagnostics` (`total_cost`, provider-keyed
  `breakdown`/`requests`/`tokens`) plus:

    * `models` — `"provider:model"` → `%{provider, model, cost, requests, input, output}`
    * `sessions` — session key → `%{cost, requests, input, output, last_at_ms}`,
      bounded to 100 per day; runs beyond that are counted in
      `sessions_omitted`.

  The `:current` summary carries its `date` and restarts each UTC day, so it is
  "today" for `usage.status`. Only counts, costs, provider/model identifiers and
  session keys are stored — never prompts, answers or credentials.
  """

  use GenServer

  alias LemonCore.Events.Usage
  alias LemonCore.UsageStore

  @max_sessions_per_day 100
  @max_label_bytes 128
  @max_projection_attempts 8

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  `LemonCore.Store` finalize-run hook. Never blocks or raises in the store.
  """
  @spec handle_finalize_run(map()) :: :ok
  def handle_finalize_run(event), do: handle_finalize_run(__MODULE__, event)

  @spec handle_finalize_run(GenServer.server(), map()) :: :ok
  def handle_finalize_run(server, %{run_id: run_id, summary: summary} = event)
      when is_map(summary) do
    entries = entries(run_id, Map.get(event, :session_key), summary)
    store = Map.get(event, :store, LemonCore.Store)
    Enum.each(entries, &GenServer.cast(server, {:record, &1, store}))

    :ok
  catch
    :exit, _ -> :ok
  end

  def handle_finalize_run(_server, _event), do: :ok

  @doc """
  Records one usage occurrence synchronously (callers outside the Store hook).
  `entry` carries native `:run_id`, `:occurrence`, `:session_key`, `:agent_id`,
  `:at_ms`, provider/model, nullable token counts, optional `:input_characters`,
  and nullable `:cost`/`:price_known`. Canonical occurrences retain unknown counters;
  a reported positive cost does not require complete token counters. Known zero
  requires complete counters and explicit `:price_known`; daily projections remain
  known-only subtotals.
  """
  @spec record(GenServer.server(), map()) :: :ok | {:error, term()}
  def record(server \\ __MODULE__, entry) when is_map(entry),
    do: GenServer.call(server, {:record, entry})

  @doc "Extracts actual per-call usage, falling back to explicitly incomplete historical totals."
  def entries(run_id, session_key, summary) do
    completed = field(summary, :completed) || %{}
    usage = field(completed, :usage) || %{}

    case field(usage, :occurrences) do
      occurrences when is_list(occurrences) ->
        occurrences
        |> Enum.with_index()
        |> Enum.flat_map(fn {occurrence, index} ->
          occurrence_summary = %{
            completed: %{usage: field(occurrence, :usage)},
            meta: %{
              model: field(occurrence, :model),
              provider: field(occurrence, :provider),
              agent_id: field(field(summary, :meta), :agent_id)
            },
            completed_at_ms: field(occurrence, :at_ms),
            occurrence: index
          }

          case entry(run_id, session_key, occurrence_summary) do
            nil -> []
            entry -> [entry]
          end
        end)

      _ ->
        case entry(run_id, session_key, summary) do
          nil -> []
          entry -> [entry]
        end
    end
  end

  @doc """
  Builds a usage entry from a finalized run summary. Explicit provider occurrences
  are retained even with no counters; historical summaries without usage return `nil`.
  """
  @spec entry(term(), term(), map()) :: map() | nil
  def entry(run_id, session_key, summary) when is_map(summary) do
    completed = field(summary, :completed) || %{}
    usage = completed |> field(:usage) |> usage()
    meta = summary |> field(:meta) |> plain_map()

    input = count(usage.input)
    output = count(usage.output)
    cache_read = count(usage.cache_read)
    cache_write = count(usage.cache_write)
    reported_total = count(usage.total_tokens)

    inclusive_input =
      cond do
        is_integer(reported_total) and is_integer(output) and reported_total >= output ->
          reported_total - output

        is_nil(input) ->
          nil

        true ->
          sum_known([input, cache_read, cache_write])
      end

    cost = cost(usage)

    if Enum.all?([input, output, reported_total, cost], &is_nil/1) and
         is_nil(field(summary, :occurrence)) do
      nil
    else
      {provider, model} = provider_model(meta)

      %{
        run_id: run_id,
        session_key: identity(session_key || field(summary, :session_key)),
        provider: provider,
        model: model,
        input: inclusive_input,
        output: output,
        uncached_input: input,
        cache_read: cache_read,
        cache_write: cache_write,
        cost: cost,
        price_known: not is_nil(cost),
        total_tokens: reported_total || sum_known([inclusive_input, output]),
        agent_id:
          identity(
            field(meta, :agent_id) ||
              LemonCore.SessionKey.agent_id(session_key || field(summary, :session_key) || "")
          ),
        at_ms: timestamp(field(summary, :completed_at_ms)),
        occurrence: field(summary, :occurrence) || 0
      }
    end
  rescue
    _ -> nil
  end

  def entry(_run_id, _session_key, _summary), do: nil

  # -- GenServer ---------------------------------------------------------------

  @impl true
  def init(opts), do: {:ok, %{store: Keyword.get(opts, :store, LemonCore.Store)}}

  @impl true
  def handle_cast({:record, entry, store}, state) do
    _ = do_record(entry, store)
    {:noreply, state}
  end

  @impl true
  def handle_call({:record, entry}, _from, state),
    do: {:reply, do_record(entry, state.store), state}

  defp do_record(%{run_id: run_id} = entry, store) when is_binary(run_id) and run_id != "" do
    record = occurrence_record(entry)
    at_ms = Map.get(entry, :at_ms) || System.system_time(:millisecond)
    date = DateTime.from_unix!(at_ms, :millisecond) |> DateTime.to_date() |> Date.to_iso8601()
    marker = %{state: :pending, date: date, at_ms: at_ms}

    case UsageStore.put_projection_new(store, record.id, marker) do
      :ok ->
        insert_occurrence(store, entry, record, marker, :new)

      {:error, :exists} ->
        case UsageStore.fetch_projection(store, record.id) do
          {:ok, %{state: :done, date: date}} ->
            clear_pending(store, record.id, date)

          {:ok, %{state: :pending} = marker} ->
            insert_occurrence(store, entry, record, marker, :replay)

          {:ok, _missing_or_invalid} ->
            {:error, :usage_projection_unavailable}

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  defp do_record(_, _store), do: {:error, :invalid_usage_identity}

  defp insert_occurrence(store, entry, record, marker, mode) do
    case UsageStore.put_occurrence(store, record) do
      :ok ->
        project(store, entry, record.id, marker)

      # Every occurrence written since markers exist has one, so an occurrence
      # found under a brand-new marker predates them. The old ledger wrote the
      # occurrence before its aggregate and could fail in between, so whether
      # the day counts it is unknown. The marker records that intent first, so
      # a replay after an interrupted rebuild rebuilds again instead of adding.
      {:error, :exists} when mode == :new ->
        legacy = Map.put(marker, :intent, :legacy_rebuild)

        case UsageStore.compare_and_swap_projection(store, record.id, marker, legacy) do
          :ok -> rebuild_and_finish(store, record.id, legacy)
          {:error, _} = error -> error
        end

      {:error, :exists} ->
        reconcile_existing(store, record.id, marker)

      {:error, _} = error ->
        error
    end
  end

  # A pending marker over a stored occurrence. The day counts the occurrence
  # exactly when its ID is in `:pending_occurrences` (added atomically with
  # its counts, removed only after the marker is done). Otherwise it is
  # ambiguous: a legacy migration interrupted before or during its rebuild may
  # already be counted by the pre-marker aggregate, so the day is rebuilt from
  # the canonical occurrences rather than projected on top.
  defp reconcile_existing(store, id, %{intent: :legacy_rebuild} = marker),
    do: rebuild_and_finish(store, id, marker)

  defp reconcile_existing(store, id, marker) do
    with {:ok, day} <- UsageStore.fetch_record(store, marker.date) do
      if id in pending_occurrences(day || %{}) do
        with :ok <- mark_done(store, id, marker), do: clear_pending(store, id, marker.date)
      else
        rebuild_and_finish(store, id, marker)
      end
    end
  end

  defp rebuild_and_finish(store, id, marker) do
    with :ok <- rebuild_day(store, marker.date, @max_projection_attempts),
         :ok <- mark_done(store, id, marker) do
      clear_pending(store, id, marker.date)
    end
  end

  # Replaces one day's projection with the sum of the canonical occurrences
  # attributed to it. Occurrences whose marker is still pending are listed in
  # `:pending_occurrences`, so their in-flight projection skips them instead of
  # adding them twice; one projected after the occurrence read changes the
  # record and fails the compare-and-swap, so the rebuild retries.
  defp rebuild_day(_store, _date, 0), do: {:error, :usage_record_busy}

  defp rebuild_day(store, date, attempts) do
    with {:ok, current} <- UsageStore.fetch_record(store, date),
         {:ok, occurrences} <- UsageStore.fetch_occurrences(store),
         {:ok, markers} <- UsageStore.fetch_projections(store) do
      markers = Map.new(markers)

      counted =
        occurrences
        |> Enum.flat_map(fn {id, occurrence} ->
          marker = Map.get(markers, id)

          if is_map(occurrence) and occurrence_date(occurrence, marker) == date,
            do: [{id, occurrence, marker}],
            else: []
        end)
        |> Enum.sort_by(fn {id, occurrence, _marker} ->
          {Map.get(occurrence, :at_ms) || 0, id}
        end)

      rebuilt =
        counted
        |> Enum.reduce(%{date: date}, fn {_id, occurrence, marker}, day ->
          at_ms = Map.get(occurrence, :at_ms) || marker_at_ms(marker)
          add_to_record(day, occurrence_projection(occurrence), date, at_ms)
        end)
        |> Map.put(:pending_occurrences, for({id, _, %{state: :pending}} <- counted, do: id))

      case UsageStore.compare_and_swap_record(store, date, current, rebuilt) do
        :ok -> :ok
        {:error, :mismatch} -> rebuild_day(store, date, attempts - 1)
        {:error, _} = error -> error
      end
    end
  end

  # A marker carries the date its projection used. A pre-marker occurrence is
  # attributed by its own timestamp; one without a timestamp cannot be placed.
  defp occurrence_date(_occurrence, %{date: date}) when is_binary(date), do: date

  defp occurrence_date(%{at_ms: at_ms}, _marker) when is_integer(at_ms),
    do: at_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

  defp occurrence_date(_occurrence, _marker), do: nil

  defp marker_at_ms(%{at_ms: at_ms}), do: at_ms
  defp marker_at_ms(_marker), do: nil

  defp occurrence_projection(occurrence) do
    %{
      provider: Map.get(occurrence, :provider),
      model: Map.get(occurrence, :model),
      session_key: Map.get(occurrence, :session_key),
      cost: Map.get(occurrence, :cost_usd) || 0.0,
      input: Map.get(occurrence, :input_tokens) || 0,
      output: Map.get(occurrence, :output_tokens) || 0,
      price_known: Map.get(occurrence, :price_known)
    }
  end

  defp project(store, entry, id, marker) do
    # Aggregates remain known-cost subtotals; canonical records retain nil.
    projection = %{
      entry
      | cost: entry.cost || 0.0,
        input: entry.input || 0,
        output: entry.output || 0
    }

    with :ok <- apply_projection(store, projection, id, marker, @max_projection_attempts),
         :ok <- mark_done(store, id, marker) do
      clear_pending(store, id, marker.date)
    end
  end

  defp apply_projection(_store, _projection, _id, _marker, 0), do: {:error, :usage_record_busy}

  defp apply_projection(store, projection, id, %{date: date, at_ms: at_ms} = marker, attempts) do
    with {:ok, current} <- UsageStore.fetch_record(store, date) do
      day = current || %{date: date}
      pending = pending_occurrences(day)

      if id in pending do
        :ok
      else
        updated =
          day
          |> add_to_record(projection, date, at_ms)
          |> Map.put(:pending_occurrences, [id | pending])

        case UsageStore.compare_and_swap_record(store, date, current, updated) do
          :ok -> :ok
          {:error, :mismatch} -> apply_projection(store, projection, id, marker, attempts - 1)
          {:error, _} = error -> error
        end
      end
    end
  end

  defp mark_done(store, id, marker) do
    done = %{marker | state: :done}

    case UsageStore.compare_and_swap_projection(store, id, marker, done) do
      :ok ->
        :ok

      {:error, :mismatch} ->
        case UsageStore.fetch_projection(store, id) do
          {:ok, ^done} -> :ok
          {:ok, _other} -> {:error, :usage_projection_conflict}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  # Drops a completed occurrence from the day's pending list and refreshes the
  # derived `:current` summary from the record that was read or written.
  defp clear_pending(store, id, date),
    do: clear_pending(store, id, date, @max_projection_attempts)

  defp clear_pending(_store, _id, _date, 0), do: {:error, :usage_record_busy}

  defp clear_pending(store, id, date, attempts) do
    with {:ok, current} <- UsageStore.fetch_record(store, date) do
      pending = pending_occurrences(current || %{})

      if id in pending do
        updated = Map.put(current, :pending_occurrences, List.delete(pending, id))

        case UsageStore.compare_and_swap_record(store, date, current, updated) do
          :ok -> refresh_summary(store, date, updated)
          {:error, :mismatch} -> clear_pending(store, id, date, attempts - 1)
          {:error, _} = error -> error
        end
      else
        refresh_summary(store, date, current)
      end
    end
  end

  defp pending_occurrences(day) do
    case Map.get(day, :pending_occurrences) do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp refresh_summary(store, date, day) when is_map(day) do
    if date == Date.to_iso8601(Date.utc_today()),
      do: UsageStore.put_summary(store, :current, summary_from_record(date, day)),
      else: :ok
  end

  defp refresh_summary(_store, _date, nil), do: :ok

  @doc false
  def occurrence_record(entry) do
    occurrence = Map.get(entry, :occurrence, 0)

    id =
      :crypto.hash(:sha256, :erlang.term_to_binary({entry.run_id, occurrence}))
      |> Base.url_encode64(padding: false)

    %{
      id: id,
      run_id: entry.run_id,
      session_key: entry.session_key,
      agent_id: Map.get(entry, :agent_id),
      at_ms: Map.get(entry, :at_ms),
      provider: entry.provider,
      model: entry.model,
      input_tokens: entry.input,
      output_tokens: entry.output,
      total_tokens: Map.get(entry, :total_tokens, sum_known([entry.input, entry.output])),
      uncached_input_tokens: Map.get(entry, :uncached_input),
      cache_read_tokens: Map.get(entry, :cache_read),
      cache_write_tokens: Map.get(entry, :cache_write),
      input_characters: Map.get(entry, :input_characters),
      cost_usd: entry.cost,
      price_known: Map.get(entry, :price_known, not is_nil(entry.cost))
    }
  end

  @doc false
  def add_to_record(record, entry, date, now_ms) do
    provider = entry.provider
    record = Map.put(record, :date, date)

    record
    |> Map.put(
      :unknown_cost_records,
      integer(record[:unknown_cost_records]) +
        if(is_nil(Map.get(entry, :price_known)) or entry.price_known, do: 0, else: 1)
    )
    |> Map.put(:total_cost, number(record[:total_cost]) + entry.cost)
    |> Map.put(:breakdown, bump(record[:breakdown], provider, entry.cost))
    |> Map.put(:requests, bump(record[:requests], provider, 1))
    |> Map.put(:tokens, bump_tokens(record[:tokens], provider, entry))
    |> Map.put(:models, bump_model(record[:models], entry))
    |> add_session(entry, now_ms)
  end

  defp summary_from_record(date, day) do
    tokens = day[:tokens] || %{}
    requests = day[:requests] || %{}

    %{
      date: date,
      total_cost: number(day[:total_cost]),
      total_requests: requests |> Map.values() |> Enum.map(&integer/1) |> Enum.sum(),
      total_tokens: %{
        input: tokens |> Map.values() |> Enum.map(&token_count(&1, :input)) |> Enum.sum(),
        output: tokens |> Map.values() |> Enum.map(&token_count(&1, :output)) |> Enum.sum()
      },
      breakdown: day[:breakdown] || %{},
      requests: requests,
      tokens: tokens
    }
  end

  defp token_count(tokens, key) when is_map(tokens),
    do: integer(Map.get(tokens, key) || Map.get(tokens, Atom.to_string(key)))

  defp token_count(_tokens, _key), do: 0

  defp add_session(record, %{session_key: nil}, _now_ms), do: record

  defp add_session(record, entry, now_ms) do
    sessions = record[:sessions] || %{}
    key = entry.session_key

    cond do
      Map.has_key?(sessions, key) or map_size(sessions) < @max_sessions_per_day ->
        current = Map.get(sessions, key, %{cost: 0.0, requests: 0, input: 0, output: 0})

        Map.put(
          record,
          :sessions,
          Map.put(sessions, key, %{
            cost: number(current[:cost]) + entry.cost,
            requests: integer(current[:requests]) + 1,
            input: integer(current[:input]) + entry.input,
            output: integer(current[:output]) + entry.output,
            last_at_ms: now_ms
          })
        )

      true ->
        Map.put(record, :sessions_omitted, integer(record[:sessions_omitted]) + 1)
    end
  end

  defp bump(map, key, amount) do
    map = map || %{}
    Map.put(map, key, (Map.get(map, key) || 0) + amount)
  end

  defp bump_tokens(map, provider, entry) do
    map = map || %{}
    current = Map.get(map, provider) || %{}

    Map.put(map, provider, %{
      input: integer(current[:input] || current["input"]) + entry.input,
      output: integer(current[:output] || current["output"]) + entry.output
    })
  end

  defp bump_model(map, entry) do
    map = map || %{}
    key = "#{entry.provider}:#{entry.model}"
    current = Map.get(map, key) || %{}

    Map.put(map, key, %{
      provider: entry.provider,
      model: entry.model,
      cost: number(current[:cost]) + entry.cost,
      requests: integer(current[:requests]) + 1,
      input: integer(current[:input]) + entry.input,
      output: integer(current[:output]) + entry.output
    })
  end

  # -- Extraction ----------------------------------------------------------------

  defp provider_model(meta) do
    model = label(field(meta, :model))
    provider = label(field(meta, :provider))

    case {provider, model && String.split(model, ":", parts: 2)} do
      {_, nil} -> {provider || "unknown", "unknown"}
      {nil, [p, m]} when p != "" and m != "" -> {p, m}
      {provider, [p, m]} when p == provider and m != "" -> {provider, m}
      {provider, _} -> {provider || "unknown", model}
    end
  end

  defp label(value) when is_atom(value) and not is_nil(value) and not is_boolean(value),
    do: label(Atom.to_string(value))

  defp label(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" or not String.valid?(value),
      do: nil,
      else: binary_part(value, 0, min(byte_size(value), @max_label_bytes))
  end

  defp label(_), do: nil

  defp cost(%Usage{} = usage) do
    value =
      case usage.cost do
        %{} = cost -> to_float(field(plain_map(cost), :total))
        cost -> to_float(cost)
      end

    case usage.price_known do
      false -> nil
      _ when is_number(value) and value > 0 -> value
      true -> if counters_known?(usage), do: value
      _ -> nil
    end
  end

  defp counters_known?(%Usage{} = usage) do
    Enum.all?([usage.input, usage.output], &count/1) and
      (count(usage.total_tokens) != nil or
         Enum.all?([usage.cache_read, usage.cache_write], &count/1))
  end

  defp timestamp(value) when is_integer(value) and value > 0, do: value
  defp timestamp(_), do: nil

  defp identity(value) when is_binary(value) and byte_size(value) in 1..1024 do
    if String.valid?(value), do: value, else: nil
  end

  defp identity(_), do: nil

  defp usage(usage) when is_map(usage), do: Usage.from_map(usage)
  defp usage(_usage), do: %Usage{}

  defp count(value) when is_integer(value) and value >= 0, do: value
  defp count(_value), do: nil

  defp plain_map(%{__struct__: _} = struct), do: Map.from_struct(struct)
  defp plain_map(map) when is_map(map), do: map
  defp plain_map(_), do: %{}

  defp field(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp field(_map, _key), do: nil

  defp sum_known(values) do
    if Enum.all?(values, &is_integer/1), do: Enum.sum(values), else: nil
  end

  defp to_float(value) when is_number(value) and value >= 0, do: value * 1.0
  defp to_float(_), do: nil

  defp number(value) when is_number(value), do: value * 1.0
  defp number(_), do: 0.0

  defp integer(value) when is_integer(value), do: value
  defp integer(_), do: 0
end
