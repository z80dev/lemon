defmodule LemonSkills.Synthesis.Pipeline do
  @moduledoc """
  Orchestrates the skill synthesis draft pipeline.

  The pipeline runs a full cycle:

      select → generate → lint → audit → store

  Only runs when the `skill_synthesis_drafts` feature flag is active.  Each
  step is independent: a failure on one candidate does not abort the rest.

  ## Usage

      # Generate drafts from the last 50 agent-scoped memory documents
      {:ok, results} = Pipeline.run(:agent, "my-agent-id", max_docs: 50)

      # Generate with project scope
      {:ok, results} = Pipeline.run(:workspace, workspace_key, cwd: "/myproject")

      # Automation pass: only look at documents ingested after the caller's
      # watermark
      {:ok, results} = Pipeline.run(:agent, "my-agent-id", since_ms: 1_700_000_000_000)

  ## Feature gating

  The `skill_synthesis_drafts` flag ships `"default-on"`; `"off"` is an operator
  kill switch that disables the pipeline for every caller. The `"opt-in"`
  state still parses and only runs when the caller passes `opt_in: true` —
  legacy compatibility for configs written before the flag was promoted
  (2026-08-14; the rollout-gate machinery that governed the promotion was
  removed at the same time).

  ## Return value

  `{:ok, %{generated: [key], skipped: [{key, reason}], total_candidates: n,
  latest_doc_ms: ms | nil, backlog_saturated: boolean()}}`

  `latest_doc_ms` is the newest `ingested_at_ms` across *all* documents the pass
  considered (not just the qualified candidates), so a caller tracking a
  watermark never re-examines documents that failed candidate selection.

  ## Watermarks and the fetch limit

  When `:since_ms` is an integer it is pushed down into the store query, which
  then returns the **oldest** unseen `max_docs` documents rather than the
  newest. That ordering is what makes the watermark safe: a pass can only ever
  advance it over a contiguous prefix of the backlog, so a backlog larger than
  `max_docs` drains one window per pass instead of being skipped forever.

  `since_ms: nil` means "no watermark" and keeps the newest-first window — the
  right shape for a one-off manual invocation. A watermark-driven caller with
  no watermark yet must pass `0`, not `nil`, or its first pass skips everything
  older than the newest `max_docs` documents.

  `backlog_saturated` is `true` when the fetch came back full (`max_docs`
  documents), meaning more documents are very likely waiting for the next pass.

  Returns `{:error, :feature_disabled}` when the flag gate rejects the call.
  """

  require Logger

  alias LemonMemory.Store
  alias LemonSkills.Audit.BundleAudit
  alias LemonSkills.Synthesis.{CandidateSelector, DraftGenerator, DraftStore}

  @type scope :: :agent | :session | :workspace
  @type run_result :: %{
          generated: [String.t()],
          skipped: [{String.t(), term()}],
          total_candidates: non_neg_integer(),
          latest_doc_ms: non_neg_integer() | nil,
          backlog_saturated: boolean()
        }

  @default_max_docs 50

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Run the synthesis pipeline for a given scope and scope key.

  ## Parameters

  - `scope` — one of `:agent`, `:session`, `:workspace`
  - `scope_key` — the agent_id, session_key, or workspace_key to query

  ## Options

  - `:max_docs` — maximum memory documents to consider (default: 50)
  - `:global` — write drafts to global draft dir (default: `true`)
  - `:cwd` — project directory for project-scoped drafts
  - `:force` — overwrite existing drafts (default: `false`)
  - `:opt_in` — also accept the `"opt-in"` feature state (default: `false`).
    Legacy compatibility for pre-promotion configs; `"off"` still disables the
    pipeline either way.
  - `:since_ms` — only consider documents whose `ingested_at_ms` is strictly
    greater than this watermark (default: `nil`, meaning no filtering). Pushed
    down into the store query, which then returns the oldest unseen window
  - `:store_mod` — memory store module (default: `LemonMemory.Store`); injection
    seam for tests
  - `:audit_mod` — bundle audit module (default: `LemonSkills.Audit.BundleAudit`);
    injection seam for tests
  """
  @spec run(scope(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, :feature_disabled} | {:error, term()}
  def run(scope, scope_key, opts \\ []) do
    if synthesis_enabled?(opts) do
      do_run(scope, scope_key, opts)
    else
      {:error, :feature_disabled}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp do_run(scope, scope_key, opts) do
    max_docs = Keyword.get(opts, :max_docs, @default_max_docs)
    store_mod = Keyword.get(opts, :store_mod, Store)
    audit_mod = Keyword.get(opts, :audit_mod, BundleAudit)
    since_ms = Keyword.get(opts, :since_ms)

    fetch_opts = [limit: max_docs, since_ms: since_ms]

    with {:ok, all_docs} <- fetch_documents(scope, scope_key, fetch_opts, store_mod) do
      # Belt and braces: the store applies `since_ms` in SQL, but an injected
      # store module may ignore the option.
      docs = filter_since(all_docs, since_ms)
      saturated? = length(all_docs) >= max_docs
      candidates = CandidateSelector.select(docs)
      Logger.info("[Synthesis] #{length(docs)} docs → #{length(candidates)} candidates")

      if saturated? do
        Logger.info(
          "[Synthesis] backlog saturated: fetch returned the full #{max_docs}-document " <>
            "window, more documents are likely pending for the next pass"
        )
      end

      results = Enum.map(candidates, fn doc -> process_candidate(doc, opts, audit_mod) end)

      generated = for {:ok, key} <- results, do: key

      skipped =
        for {:skip, key, reason} <- results do
          {key, reason}
        end

      {:ok,
       %{
         generated: generated,
         skipped: skipped,
         total_candidates: length(candidates),
         latest_doc_ms: latest_doc_ms(docs),
         backlog_saturated: saturated?
       }}
    end
  end

  # The watermark covers every document the pass looked at, not only the ones
  # that qualified — otherwise unqualified documents would be re-fetched and
  # re-rejected on every subsequent pass.
  defp latest_doc_ms(docs) do
    docs
    |> Enum.map(& &1.ingested_at_ms)
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp filter_since(docs, since_ms) when is_integer(since_ms) do
    Enum.filter(docs, &(is_integer(&1.ingested_at_ms) and &1.ingested_at_ms > since_ms))
  end

  defp filter_since(docs, _since_ms), do: docs

  defp process_candidate(doc, opts, audit_mod) do
    key_hint = DraftGenerator.derive_key_hint(doc.prompt_summary)
    scope = draft_scope(opts)

    with {:ok, draft} <- DraftGenerator.generate(doc),
         :ok <- DraftStore.put(draft, opts),
         {:ok, audit} <-
           audit_mod.audit(DraftStore.draft_dir(draft.key, opts), scope, draft.key, kind: :draft),
         :ok <- DraftStore.record_audit(draft.key, audit, opts),
         :ok <- check_audit(draft.key, audit, opts, audit_mod) do
      {:ok, draft.key}
    else
      {:error, :blocked_by_audit} ->
        {:skip, key_hint, :blocked_by_audit}

      {:error, :already_exists} ->
        {:skip, key_hint, :already_exists}

      {:error, reason} ->
        Logger.warning("[Synthesis] Skipping candidate #{key_hint}: #{inspect(reason)}")
        {:skip, key_hint, reason}
    end
  end

  defp check_audit(key, audit_record, opts, audit_mod) do
    case audit_mod.audit_status(audit_record) do
      :block ->
        Logger.info(
          "[Synthesis] Draft blocked by audit: #{inspect(audit_record["combined_findings"] || [])}"
        )

        DraftStore.delete(key, opts)
        {:error, :blocked_by_audit}

      _verdict ->
        :ok
    end
  end

  defp draft_scope(opts) do
    if Keyword.get(opts, :global, true) or is_nil(Keyword.get(opts, :cwd)) do
      :global
    else
      {:project, Keyword.fetch!(opts, :cwd)}
    end
  end

  defp fetch_documents(:agent, agent_id, fetch_opts, store_mod) do
    docs = store_mod.get_by_agent(agent_id, fetch_opts)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp fetch_documents(:session, session_key, fetch_opts, store_mod) do
    docs = store_mod.get_by_session(session_key, fetch_opts)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp fetch_documents(:workspace, workspace_key, fetch_opts, store_mod) do
    docs = store_mod.get_by_workspace(workspace_key, fetch_opts)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp synthesis_enabled?(opts) do
    config = LemonCore.Config.Modular.load()

    LemonCore.Config.Features.enabled?(config.features, :skill_synthesis_drafts,
      opt_in: Keyword.get(opts, :opt_in, false)
    )
  rescue
    _ -> false
  end
end
