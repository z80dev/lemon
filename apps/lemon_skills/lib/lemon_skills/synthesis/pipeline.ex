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

  ## Return value

  `{:ok, %{generated: [key], skipped: [{key, reason}], total_candidates: n}}`

  or `{:error, :feature_disabled}` when the flag is off.
  """

  require Logger

  alias LemonCore.MemoryStore
  alias LemonSkills.Audit.Engine, as: AuditEngine
  alias LemonSkills.Synthesis.{CandidateSelector, DraftGenerator, DraftStore}

  @type scope :: :agent | :session | :workspace
  @type run_result :: %{
          generated: [String.t()],
          skipped: [{String.t(), term()}],
          total_candidates: non_neg_integer()
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
  """
  @spec run(scope(), String.t(), keyword()) ::
          {:ok, run_result()} | {:error, :feature_disabled} | {:error, term()}
  def run(scope, scope_key, opts \\ []) do
    if synthesis_enabled?() do
      do_run(scope, scope_key, opts)
    else
      {:error, :feature_disabled}
    end
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp do_run(scope, scope_key, opts) do
    max_docs = Keyword.get(opts, :max_docs, @default_max_docs)

    with {:ok, docs} <- fetch_documents(scope, scope_key, max_docs) do
      candidates = CandidateSelector.select(docs)
      Logger.info("[Synthesis] #{length(docs)} docs → #{length(candidates)} candidates")

      results = Enum.map(candidates, fn doc -> process_candidate(doc, opts) end)

      generated = for {:ok, key} <- results, do: key

      skipped =
        for {:skip, key, reason} <- results do
          {key, reason}
        end

      {:ok,
       %{
         generated: generated,
         skipped: skipped,
         total_candidates: length(candidates)
       }}
    end
  end

  defp process_candidate(doc, opts) do
    key_hint = DraftGenerator.derive_key_hint(doc.prompt_summary)

    with {:ok, draft} <- DraftGenerator.generate(doc),
         :ok <- check_audit(draft),
         :ok <- DraftStore.put(draft, opts) do
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

  defp check_audit(%{content: content}) do
    case AuditEngine.audit_content(content) do
      {:block, findings} ->
        Logger.info("[Synthesis] Draft blocked by audit: #{inspect(Enum.map(findings, & &1.rule))}")
        {:error, :blocked_by_audit}

      {_verdict, _findings} ->
        # pass or warn — warn is acceptable for drafts (human review required anyway)
        :ok
    end
  end

  defp fetch_documents(:agent, agent_id, limit) do
    docs = MemoryStore.get_by_agent(agent_id, limit: limit)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp fetch_documents(:session, session_key, limit) do
    docs = MemoryStore.get_by_session(session_key, limit: limit)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp fetch_documents(:workspace, workspace_key, limit) do
    docs = MemoryStore.get_by_workspace(workspace_key, limit: limit)
    {:ok, docs}
  catch
    :exit, _ -> {:ok, []}
  end

  defp synthesis_enabled? do
    config = LemonCore.Config.Modular.load()
    LemonCore.Config.Features.enabled?(config.features, :skill_synthesis_drafts)
  rescue
    _ -> false
  end
end
