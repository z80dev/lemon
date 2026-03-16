defmodule LemonCore.MemoryIngest do
  @moduledoc """
  Asynchronous ingest pipeline that writes normalized memory documents to
  `LemonCore.MemoryStore` after a run is finalized.

  ## Design

  - Ingest runs in a dedicated `GenServer` so it never blocks run finalization.
  - Ingest failures are logged and silently dropped — they must never crash or
    slow down the caller.
  - The `session_search` feature flag gates whether ingest is active.  When the
    flag is `:off` (the default), calls to `ingest/3` are no-ops.

  ## Usage

      # Called by LemonCore.Store when finalizing a run
      LemonCore.MemoryIngest.ingest(run_id, record, summary)

  ## Configuration

  Ingest respects `LemonCore.MemoryStore` configuration and the `session_search`
  feature flag in `[features]` of `~/.lemon/config.toml`.
  """

  use GenServer
  require Logger

  alias LemonCore.MemoryDocument
  alias LemonCore.MemoryStore
  alias LemonCore.RoutingFeedbackStore
  alias LemonCore.TaskFingerprint

  # ── Public API ────────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueue a finalized run for asynchronous memory ingest.

  This is a fire-and-forget cast. If the `session_search` feature flag is off,
  this is a no-op. Failures inside the GenServer are logged and swallowed.
  """
  @spec ingest(run_id :: term(), record :: map(), summary :: map()) :: :ok
  def ingest(run_id, record, summary) do
    if session_search_enabled?() or routing_feedback_enabled?() do
      GenServer.cast(__MODULE__, {:ingest, run_id, record, summary})
    end

    :ok
  catch
    # GenServer not running — non-fatal, swallow
    :exit, _ -> :ok
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:ingest, run_id, record, summary}, state) do
    t0 = System.monotonic_time(:microsecond)

    try do
      doc = MemoryDocument.from_run(run_id, record, summary)

      if valid_doc?(doc) do
        if session_search_enabled?() do
          MemoryStore.put(doc)
        end

        if routing_feedback_enabled?() do
          record_routing_feedback(doc, record)
        end

        duration_us = System.monotonic_time(:microsecond) - t0

        LemonCore.Telemetry.emit(
          [:lemon, :memory, :ingest, :ok],
          %{duration_us: duration_us},
          %{run_id: run_id, session_key: doc.session_key, agent_id: doc.agent_id}
        )

        Logger.debug(
          "[MemoryIngest] ingested doc_id=#{doc.doc_id} run_id=#{doc.run_id} " <>
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
          "[MemoryIngest] ingest failed for run #{inspect(run_id)}: #{Exception.message(e)}"
        )
    end

    {:noreply, state}
  end

  # ── Private helpers ────────────────────────────────────────────────────────────

  # A document is only worth ingesting if it has a session_key.
  defp valid_doc?(%MemoryDocument{session_key: sk}) when is_binary(sk) and sk != "", do: true
  defp valid_doc?(_), do: false

  defp session_search_enabled? do
    try do
      config = LemonCore.Config.Modular.load()
      LemonCore.Config.Features.enabled?(config.features, :session_search)
    rescue
      _ -> false
    end
  end

  defp routing_feedback_enabled? do
    try do
      config = LemonCore.Config.Modular.load()
      LemonCore.Config.Features.enabled?(config.features, :routing_feedback)
    rescue
      _ -> false
    end
  end

  defp record_routing_feedback(%MemoryDocument{} = doc, record) do
    fingerprint = TaskFingerprint.from_document(doc)
    fingerprint_key = TaskFingerprint.key(fingerprint)
    duration_ms = compute_duration_ms(record, doc)
    RoutingFeedbackStore.record(fingerprint_key, doc.outcome, duration_ms)
  rescue
    e ->
      Logger.warning("[MemoryIngest] routing feedback record failed: #{Exception.message(e)}")
  end

  defp compute_duration_ms(record, %MemoryDocument{ingested_at_ms: ingested_at}) do
    started_at = Map.get(record, :started_at)

    if is_integer(started_at) and is_integer(ingested_at) and ingested_at > started_at do
      ingested_at - started_at
    end
  end
end
