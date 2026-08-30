defmodule LemonSkills.Learn do
  @moduledoc """
  Review and explicitly confirm bounded learning from local or remote sources.

  This service composes `LemonCore.Context`, `LemonMemory.Store`, and the
  existing synthesized-skill draft store. Review is always non-mutating and
  returns only counts, digests, provenance hashes, audit rule identifiers, and
  conflict state. It never returns source text, prompts, paths, URLs, secret
  values, or generated skill bodies.

  Confirmation recomputes the complete source selection and destination state
  under a lock. The exact digest from a fresh review is therefore invalid after
  a source or destination change. Confirmed content is redacted a second time
  at the durable boundary before one deterministic memory document and one
  audited skill draft are written to their canonical stores.
  """

  alias LemonMemory.{Document, Safety, Store}
  alias LemonSkills.Audit.Engine
  alias LemonSkills.Synthesis.{DraftGenerator, DraftStore}

  @max_references 16
  @max_digest_bytes 64
  @digest_regex ~r/^[a-f0-9]{64}$/
  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @type result :: {:ok, map()} | {:error, {atom(), String.t()}}

  @doc "Review bounded sources without writing memory or skill state."
  @spec review([String.t()], keyword()) :: result()
  def review(references, opts \\ []) do
    with :ok <- validate_inputs(references, opts),
         {:ok, public, _internal} <- build_plan(references, opts) do
      {:ok, public}
    end
  end

  @doc "Confirm a freshly reviewed plan and write it to the canonical stores."
  @spec confirm([String.t()], String.t(), keyword()) :: result()
  def confirm(references, confirmation_digest, opts \\ []) do
    with :ok <- validate_inputs(references, opts),
         :ok <- validate_digest(confirmation_digest) do
      lock = {__MODULE__, session_key(opts) <> "\0" <> draft_scope_key(opts)}

      :global.trans(lock, fn ->
        with {:ok, public, internal} <- build_plan(references, opts),
             :ok <- require_digest(public, confirmation_digest),
             :ok <- require_committable(public),
             {:ok, skill_status, created_draft?} <- write_draft(internal, opts),
             :ok <- write_memory(internal, created_draft?, opts) do
          {:ok,
           public
           |> Map.put("status", "confirmed")
           |> put_in(["memory", "status"], action_status(public["memory"]["action"]))
           |> put_in(["skill", "status"], skill_status)}
        else
          {:memory_error, reason, true, draft_key} ->
            _ = safe_draft_call(fn -> draft_store(opts).delete(draft_key, draft_opts(opts)) end)
            safe_error(:memory_write_failed, reason)

          {:memory_error, reason, false, _draft_key} ->
            safe_error(:memory_write_failed, reason)

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  defp build_plan(references, opts) do
    with {:ok, context} <- context_mod(opts).resolve(references, context_opts(opts)),
         {:ok, source_text, redaction_count} <- sanitized_source_text(context),
         {:ok, doc, draft} <- proposals(source_text, context, opts),
         {audit_verdict, findings} <-
           audit_mod(opts).audit_content(draft.content, llm: [enabled: false]),
         {:ok, memory_action} <- memory_action(doc, opts),
         {:ok, skill_action} <- skill_action(draft, opts) do
      source_digest = sha256(source_text)
      audit_codes = findings |> Enum.map(& &1.rule) |> Enum.uniq() |> Enum.sort()
      conflicts = conflicts(memory_action, skill_action, audit_verdict)

      digest_input = %{
        version: 1,
        source_digest: source_digest,
        source_count: length(context.sources),
        selected_bytes: byte_size(source_text),
        memory: %{id: doc.doc_id, action: memory_action, content: memory_hash(doc)},
        skill: %{key: draft.key, action: skill_action, content: sha256(draft.content)},
        audit: %{verdict: audit_verdict, codes: audit_codes},
        target: %{session: sha256(doc.session_key), scope: doc.scope}
      }

      confirmation_digest = digest(digest_input)
      can_confirm = conflicts == [] and audit_verdict != :block

      public = %{
        "version" => 1,
        "status" => "review",
        "canConfirm" => can_confirm,
        "confirmationDigest" => confirmation_digest,
        "sources" => %{
          "count" => length(context.sources),
          "selectedItems" => context.summary.selected_items,
          "selectedBytes" => byte_size(source_text),
          "omissionCount" => context.summary.omitted_count,
          "redactionCount" => context.summary.redaction_count + redaction_count,
          "contentDigest" => source_digest,
          "provenance" => source_provenance(context.sources)
        },
        "memory" => %{
          "id" => doc.doc_id,
          "scope" => Atom.to_string(doc.scope),
          "action" => Atom.to_string(memory_action),
          "summaryBytes" => byte_size(doc.answer_summary),
          "summaryDigest" => sha256(doc.answer_summary),
          "contentReturned" => false
        },
        "skill" => %{
          "key" => draft.key,
          "action" => Atom.to_string(skill_action),
          "bundleBytes" => byte_size(draft.content),
          "bundleDigest" => sha256(draft.content),
          "auditVerdict" => Atom.to_string(audit_verdict),
          "auditCodes" => audit_codes,
          "approvalRequired" => audit_verdict == :warn,
          "contentReturned" => false
        },
        "conflicts" => conflicts,
        "cleanup" => %{
          "sourceTextReturned" => false,
          "promptTextReturned" => false,
          "pathsReturned" => false,
          "urlsReturned" => false,
          "secretValuesReturned" => false,
          "secretNamesReturned" => false
        }
      }

      internal = %{doc: doc, draft: draft, audit: {audit_verdict, audit_codes}}
      {:ok, public, internal}
    else
      {:error, {_, _}} = error -> error
      {:error, reason} -> safe_error(:source_unavailable, safe_reason(reason))
    end
  end

  defp sanitized_source_text(context) do
    text =
      context.sources
      |> Enum.map(&Map.get(&1, :content, ""))
      |> Enum.join("\n\n")

    {redacted, count} = Safety.redact(text)

    if String.trim(redacted) == "",
      do: safe_error(:empty_source, "No learnable text was selected"),
      else: {:ok, redacted, count}
  end

  defp proposals(source_text, context, opts) do
    source_digest = sha256(source_text)
    short = String.slice(source_digest, 0, 12)
    now = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    agent_id = Keyword.get(opts, :agent_id, "default")
    session_key = session_key(opts)

    doc =
      Document.new(%{
        doc_id: "mem_learn_#{source_digest}",
        run_id: "learn_#{source_digest}",
        session_key: session_key,
        agent_id: agent_id,
        workspace_key: "sha256:#{sha256(Path.expand(Keyword.get(opts, :root, File.cwd!())))}",
        scope: Keyword.get(opts, :memory_scope, :agent),
        started_at_ms: now,
        ingested_at_ms: now,
        prompt_summary:
          "Source #{short} contains a reviewed reusable procedure captured through Lemon's bounded learning workflow.",
        answer_summary: source_text,
        outcome: :success,
        meta: %{
          "kind" => "learned_source",
          "source_digest" => source_digest,
          "source_count" => length(context.sources),
          "source_provenance" => source_provenance(context.sources),
          "source_text_redacted" => true
        }
      })

    # Source learning is not a finalized run. Keep the shared generator's
    # content deterministic across wall-clock dates so an unchanged source can
    # be reviewed and confirmed idempotently after midnight.
    draft_doc = %{doc | started_at_ms: 0, ingested_at_ms: 0}

    with {:ok, generated} <- DraftGenerator.generate(draft_doc) do
      draft =
        Map.merge(generated, %{
          key: "learned-source-#{short}",
          name: "Learned source #{short}",
          source_digest: source_digest,
          source_provenance: source_provenance(context.sources),
          source_text_redacted: true
        })

      {:ok, doc, draft}
    end
  rescue
    _ -> safe_error(:proposal_failed, "The bounded source could not be converted into proposals")
  end

  defp memory_action(doc, opts) do
    case safe_memory_call(fn ->
           memory_store(opts).get_document(memory_server(opts), doc.doc_id)
         end) do
      {:ok, {:error, :not_found}} ->
        {:ok, :create}

      {:ok, {:ok, existing}} ->
        {:ok, if(memory_hash(existing) == memory_hash(doc), do: :unchanged, else: :conflict)}

      _ ->
        safe_error(:memory_unavailable, "The durable memory store is unavailable")
    end
  end

  defp skill_action(draft, opts) do
    case safe_draft_call(fn -> draft_store(opts).get(draft.key, draft_opts(opts)) end) do
      {:ok, {:error, :not_found}} ->
        {:ok, :create}

      {:ok, {:ok, existing}} ->
        {:ok,
         if(sha256(existing.content) == sha256(draft.content), do: :unchanged, else: :conflict)}

      _ ->
        safe_error(:draft_unavailable, "The skill draft store is unavailable")
    end
  end

  defp write_draft(%{draft: draft, audit: {_verdict, audit_codes}}, opts) do
    case safe_draft_call(fn -> draft_store(opts).put_new(draft, draft_opts(opts)) end) do
      {:ok, :ok} ->
        case safe_draft_call(fn ->
               draft_store(opts).record_audit(
                 draft.key,
                 audit_record(draft.content, audit_codes),
                 draft_opts(opts)
               )
             end) do
          {:ok, :ok} ->
            {:ok, "created", true}

          _ ->
            _ = safe_draft_call(fn -> draft_store(opts).delete(draft.key, draft_opts(opts)) end)
            safe_error(:skill_write_failed, "The reviewed skill draft could not be written")
        end

      {:ok, {:error, :already_exists}} ->
        case skill_action(draft, opts) do
          {:ok, :unchanged} ->
            {:ok, "unchanged", false}

          _ ->
            safe_error(:skill_collision, "The skill draft destination changed")
        end

      _ ->
        safe_error(:skill_write_failed, "The reviewed skill draft could not be written")
    end
  end

  defp write_memory(%{doc: doc, draft: draft}, created_draft?, opts) do
    result =
      safe_memory_call(fn ->
        memory_store(opts).put_new_sync(memory_server(opts), doc)
      end)

    case result do
      {:ok, {:ok, :created}} ->
        :ok

      {:ok, {:ok, :exists}} ->
        case memory_action(doc, opts) do
          {:ok, :unchanged} -> :ok
          _ -> {:memory_error, "The memory destination changed", created_draft?, draft.key}
        end

      _ ->
        {:memory_error, "The operation failed safely", created_draft?, draft.key}
    end
  end

  defp safe_memory_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp safe_draft_call(fun) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp conflicts(memory_action, skill_action, audit_verdict) do
    []
    |> maybe_conflict(memory_action == :conflict, "memory_collision")
    |> maybe_conflict(skill_action == :conflict, "skill_collision")
    |> maybe_conflict(audit_verdict == :block, "skill_audit_blocked")
  end

  defp maybe_conflict(list, true, conflict), do: list ++ [conflict]
  defp maybe_conflict(list, false, _), do: list

  defp audit_record(content, audit_codes) do
    %{
      "final_verdict" => if(audit_codes == [], do: "pass", else: "warn"),
      "combined_findings" => audit_codes,
      "approval_required" => audit_codes != [],
      "bundle_hash" => sha256(content),
      "audit_fingerprint" => "learn-source-v1",
      "scanned_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp require_digest(%{"confirmationDigest" => expected}, supplied)
       when is_binary(expected) and is_binary(supplied) and
              byte_size(expected) == byte_size(supplied) do
    if :crypto.hash_equals(expected, supplied),
      do: :ok,
      else:
        safe_error(
          :confirmation_mismatch,
          "Confirmation digest is missing, stale, or incorrect"
        )
  end

  defp require_digest(_, _),
    do: safe_error(:confirmation_mismatch, "Confirmation digest is missing, stale, or incorrect")

  defp require_committable(%{"canConfirm" => true}), do: :ok

  defp require_committable(_),
    do: safe_error(:conflict, "The reviewed plan contains a blocking conflict")

  defp validate_inputs(references, opts) when is_list(references) do
    cond do
      references == [] ->
        safe_error(:invalid_references, "At least one source reference is required")

      length(references) > @max_references ->
        safe_error(:invalid_references, "Too many source references")

      not Enum.all?(references, &(is_binary(&1) and byte_size(&1) <= 2_048)) ->
        safe_error(:invalid_references, "Source references are invalid")

      not Regex.match?(@id_regex, Keyword.get(opts, :agent_id, "default")) ->
        safe_error(:invalid_agent, "Agent ID is invalid")

      true ->
        :ok
    end
  end

  defp validate_inputs(_, _), do: safe_error(:invalid_references, "Source references are invalid")

  defp validate_digest(value) when is_binary(value) and byte_size(value) == @max_digest_bytes do
    if Regex.match?(@digest_regex, value),
      do: :ok,
      else: safe_error(:invalid_confirmation, "Confirmation digest is invalid")
  end

  defp validate_digest(_), do: safe_error(:invalid_confirmation, "Confirmation digest is invalid")

  defp context_opts(opts) do
    opts
    |> Keyword.take([
      :root,
      :max_output_bytes,
      :max_input_bytes,
      :max_items,
      :max_pages,
      :max_depth,
      :timeout_ms
    ])
  end

  defp draft_opts(opts) do
    [global: Keyword.get(opts, :global, true), cwd: Keyword.get(opts, :root, File.cwd!())]
  end

  defp session_key(opts),
    do: Keyword.get(opts, :session_key, "agent:#{Keyword.get(opts, :agent_id, "default")}:learn")

  defp draft_scope_key(opts),
    do:
      if(Keyword.get(opts, :global, true),
        do: "global",
        else: sha256(Keyword.get(opts, :root, File.cwd!()))
      )

  defp source_provenance(sources) do
    Enum.map(sources, fn source ->
      %{
        "type" => source.type,
        "referenceDigest" => sha256(source.reference),
        "contentDigest" => sha256(Map.get(source, :content, "")),
        "selectedItems" => source.selected_items,
        "selectedBytes" => byte_size(Map.get(source, :content, "")),
        "redactionCount" => source.redaction_count
      }
    end)
  end

  defp memory_hash(doc),
    do: digest(%{prompt: doc.prompt_summary, answer: doc.answer_summary, meta: doc.meta})

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp sha256(text) when is_binary(text),
    do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  defp action_status("create"), do: "created"
  defp action_status("unchanged"), do: "unchanged"
  defp action_status(other), do: other

  defp context_mod(opts), do: Keyword.get(opts, :context_mod, LemonCore.Context)
  defp memory_store(opts), do: Keyword.get(opts, :memory_store, Store)
  defp memory_server(opts), do: Keyword.get(opts, :memory_server, Store)
  defp draft_store(opts), do: Keyword.get(opts, :draft_store, DraftStore)
  defp audit_mod(opts), do: Keyword.get(opts, :audit_mod, Engine)

  defp safe_reason(reason)
       when reason in [:path_traversal, :symlink, :ssrf_blocked, :invalid_url],
       do: Atom.to_string(reason)

  defp safe_reason(_), do: "The operation failed safely"
  defp safe_error(code, message), do: {:error, {code, message}}
end
