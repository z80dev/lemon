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

  This is a fire-and-forget cast. Feature flags are evaluated inside the ingest
  worker so the config only needs to be loaded once per ingest.
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

  # ── GenServer callbacks ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config_loader =
      Keyword.get(opts, :config_loader, fn -> LemonCore.Config.Modular.load() end)

    memory_store = Keyword.get(opts, :memory_store, MemoryStore)
    routing_feedback_store = Keyword.get(opts, :routing_feedback_store, RoutingFeedbackStore)

    {:ok,
     %{
       config_loader: config_loader,
       memory_store: memory_store,
       routing_feedback_store: routing_feedback_store
     }}
  end

  @impl true
  def handle_cast({:ingest, run_id, record, summary}, state) do
    t0 = System.monotonic_time(:microsecond)

    try do
      doc = MemoryDocument.from_run(run_id, record, summary)

      if valid_doc?(doc) do
        config = load_config(state.config_loader)
        features = Map.get(config, :features, %{})

        if LemonCore.Config.Features.enabled?(features, :session_search) do
          put_memory_doc(state.memory_store, doc)
        end

        if LemonCore.Config.Features.enabled?(features, :routing_feedback) do
          record_routing_feedback(doc, record, state.routing_feedback_store)
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

  defp load_config(config_loader) do
    try do
      config_loader.()
    rescue
      _ -> %{features: %{}}
    end
  end

  defp put_memory_doc(memory_store, %MemoryDocument{} = doc) when is_pid(memory_store) do
    MemoryStore.put(memory_store, doc)
  end

  defp put_memory_doc(memory_store, %MemoryDocument{} = doc) when is_atom(memory_store) do
    memory_store.put(doc)
  end

  defp record_routing_feedback(%MemoryDocument{} = doc, record, routing_feedback_store) do
    fingerprint = TaskFingerprint.from_document(doc)
    # Strip toolset so the stored key matches the empty-toolset lookup used by RunOrchestrator
    fingerprint_key = TaskFingerprint.key(%{fingerprint | toolset: []})
    duration_ms = compute_duration_ms(record, doc)
    put_routing_feedback(routing_feedback_store, fingerprint_key, doc.outcome, duration_ms)
  rescue
    e ->
      Logger.warning("[MemoryIngest] routing feedback record failed: #{Exception.message(e)}")
  end

  defp put_routing_feedback(routing_feedback_store, fingerprint_key, outcome, duration_ms)
       when is_pid(routing_feedback_store) do
    GenServer.cast(
      routing_feedback_store,
      {:record, fingerprint_key, Atom.to_string(outcome), duration_ms}
    )
  end

  defp put_routing_feedback(routing_feedback_store, fingerprint_key, outcome, duration_ms)
       when is_atom(routing_feedback_store) do
    routing_feedback_store.record(fingerprint_key, outcome, duration_ms)
  end

  defp compute_duration_ms(record, %MemoryDocument{ingested_at_ms: ingested_at}) do
    started_at = Map.get(record, :started_at)

    if is_integer(started_at) and is_integer(ingested_at) and ingested_at > started_at do
      ingested_at - started_at
    end
  end
end
