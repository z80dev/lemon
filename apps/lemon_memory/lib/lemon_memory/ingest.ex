defmodule LemonMemory.Ingest do
  @moduledoc """
  Asynchronous ingest pipeline that writes normalized memory documents to
  `LemonMemory.Store` after a run is finalized.

  ## Design

  - Ingest runs in a dedicated `GenServer` so it never blocks run finalization.
  - Ingest failures are logged and silently dropped — they must never crash or
    slow down the caller.
  - The `session_search` feature flag gates whether ingest is active. The flag
    defaults to `:"default-on"`; set `LEMON_FEATURE_SESSION_SEARCH=off` (or
    `[features] session_search = "off"`) to make `ingest/3` a no-op.
  - Feature flags are resolved from config loaded via the injected
    `:config_loader` and cached in the server state with a short TTL
    (`:config_ttl_ms`, default 30s), so a full TOML config load does
    NOT happen on every finalized run. When both `session_search` and
    `routing_feedback` resolve to disabled, the run is skipped without even
    building a `Document`.

  ## Usage

      # Called by LemonCore.Store when finalizing a run
      LemonMemory.Ingest.ingest(run_id, record, summary)

  ## Configuration

  Ingest respects `LemonMemory.Store` configuration and the `session_search`
  feature flag in `[features]` of `~/.lemon/config.toml`.
  """

  use GenServer
  require Logger

  # How long resolved feature flags stay cached before the config is reloaded.
  # LemonCore.ConfigCache only caches the legacy base config (no [features]
  # section), so we cache the resolved Features struct here instead.
  @config_ttl_ms 30_000

  alias LemonCore.Bus
  alias LemonCore.Config.Features
  alias LemonCore.Events.RoutingFeedback
  alias LemonMemory.Document
  alias LemonMemory.Providers
  alias LemonMemory.Safety
  alias LemonMemory.Store
  alias LemonMemory.TaskFingerprint

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a finalized run for asynchronous memory ingest.

  This is a fire-and-forget cast. Feature flags are evaluated inside the ingest
  worker from a TTL-cached config, so the hot path does not re-read TOML from
  disk on every finalized run.
  """
  @spec ingest(run_id :: term(), record :: map(), summary :: map()) :: :ok
  def ingest(run_id, record, summary) do
    ingest(__MODULE__, run_id, record, summary)
  end

  @spec ingest(GenServer.server(), run_id :: term(), record :: map(), summary :: map()) :: :ok
  def ingest(server, run_id, record, summary) do
    GenServer.cast(server, {:ingest, run_id, record, summary})
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  `LemonCore.Store` finalize-run hook: enqueue the finalized run for ingest.

  Wired by the runtime, not by the store:

      config :lemon_core, LemonCore.Store,
        finalize_run_hooks: [{LemonMemory.Ingest, :handle_finalize_run}]
  """
  @spec handle_finalize_run(map()) :: :ok
  def handle_finalize_run(event), do: handle_finalize_run(__MODULE__, event)

  @spec handle_finalize_run(GenServer.server(), map()) :: :ok
  def handle_finalize_run(server, %{run_id: run_id, record: record, summary: summary}) do
    ingest(server, run_id, record, summary)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config_loader =
      Keyword.get(opts, :config_loader, fn -> LemonCore.Config.Modular.load() end)

    memory_store = Keyword.get(opts, :memory_store, Store)
    config_ttl_ms = Keyword.get(opts, :config_ttl_ms, @config_ttl_ms)

    {:ok,
     %{
       config_loader: config_loader,
       memory_store: memory_store,
       config_ttl_ms: config_ttl_ms,
       features: nil,
       features_loaded_at: nil
     }}
  end

  @impl true
  def handle_cast({:ingest, run_id, record, summary}, state) do
    t0 = System.monotonic_time(:microsecond)

    # Resolve feature flags from the TTL-cached config; loading a full TOML
    # config on every finalized run is too expensive for this hot path.
    {features, state} = resolve_features(state)
    session_search? = Features.enabled?(features, :session_search)
    routing_feedback? = Features.enabled?(features, :routing_feedback)

    # Short-circuit: with both consumers disabled there is nothing to do, so
    # skip building the Document entirely.
    if session_search? or routing_feedback? do
      try do
        doc = Document.from_run(run_id, record, summary)

        if valid_doc?(doc) and Safety.safe_document?(doc) do
          if session_search? do
            put_memory_doc(state.memory_store, doc)
          end

          if routing_feedback? do
            broadcast_routing_feedback(doc, record)
          end

          duration_us = System.monotonic_time(:microsecond) - t0

          LemonCore.Telemetry.emit(
            [:lemon, :memory, :ingest, :ok],
            %{duration_us: duration_us},
            %{run_id: run_id, session_key: doc.session_key, agent_id: doc.agent_id}
          )

          Logger.debug(
            "[Ingest] ingested doc_id=#{doc.doc_id} run_id=#{doc.run_id} " <>
              "session=#{doc.session_key} agent=#{doc.agent_id} duration_us=#{duration_us}"
          )
        end
      rescue
        e ->
          duration_us = System.monotonic_time(:microsecond) - t0

          LemonCore.Telemetry.emit(
            [:lemon, :memory, :ingest, :failure],
            %{count: 1, duration_us: duration_us},
            %{run_id: run_id, error: Exception.message(e)}
          )

          Logger.warning(
            "[Ingest] ingest failed for run #{inspect(run_id)}: #{Exception.message(e)}"
          )
      end
    end

    {:noreply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────────

  # A document is only worth ingesting if it has a session_key.
  defp valid_doc?(%Document{session_key: sk}) when is_binary(sk) and sk != "", do: true
  defp valid_doc?(_), do: false

  # Return the cached Features struct, reloading config when the TTL elapsed.
  defp resolve_features(state) do
    now = System.monotonic_time(:millisecond)

    if features_fresh?(state, now) do
      {state.features, state}
    else
      features =
        state.config_loader
        |> load_config()
        |> extract_features()

      {features, %{state | features: features, features_loaded_at: now}}
    end
  end

  defp features_fresh?(%{features: %Features{}, features_loaded_at: at, config_ttl_ms: ttl}, now)
       when is_integer(at),
       do: now - at < ttl

  defp features_fresh?(_state, _now), do: false

  defp load_config(config_loader) do
    try do
      config_loader.()
    rescue
      _ -> %{features: %{}}
    end
  end

  # Struct defaults apply when the loaded config carries no usable [features]
  # section (e.g. the loader raised and was rescued above). Note session_search
  # defaults to :"default-on", so the rescue path resolves to ingest ACTIVE.
  defp extract_features(config) do
    case config do
      %{features: %Features{} = features} -> features
      _ -> %Features{}
    end
  end

  defp put_memory_doc(memory_store, %Document{} = doc) when is_pid(memory_store) do
    Store.put(memory_store, doc)
  end

  defp put_memory_doc(Store, %Document{} = doc) do
    Providers.put(doc)
  end

  defp put_memory_doc(memory_store, %Document{} = doc) when is_atom(memory_store) do
    memory_store.put(doc)
  end

  defp broadcast_routing_feedback(%Document{} = doc, record) do
    fingerprint = TaskFingerprint.from_document(doc)
    # Strip toolset so the stored key matches the empty-toolset lookup used by RunOrchestrator
    fingerprint_key = TaskFingerprint.key(%{fingerprint | toolset: []})
    duration_ms = compute_duration_ms(record, doc)

    Bus.broadcast_event(
      "routing_feedback",
      :routing_feedback,
      RoutingFeedback.new(%{
        fingerprint_key: fingerprint_key,
        outcome: doc.outcome,
        duration_ms: duration_ms
      })
    )
  rescue
    e ->
      Logger.warning("[Ingest] routing feedback record failed: #{Exception.message(e)}")
  end

  defp compute_duration_ms(record, %Document{ingested_at_ms: ingested_at}) do
    started_at = Map.get(record, :started_at)

    if is_integer(started_at) and is_integer(ingested_at) and ingested_at > started_at do
      ingested_at - started_at
    end
  end
end
