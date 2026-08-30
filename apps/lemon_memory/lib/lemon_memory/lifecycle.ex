defmodule LemonMemory.Lifecycle do
  @moduledoc """
  Bounded, redacted operator lifecycle for canonical durable memory.

  This is the only boundary Web management should use. It reads and deletes
  records in `LemonMemory.Store`; it never builds a second index or exposes raw
  store rows. Lists and searches are bounded, workspace identity is one-way
  hashed, learned-source provenance is digest-only, and every text preview is
  passed through `LemonMemory.Safety.redact_for_operator/2`.

  Deletion is preview-first. Confirmation binds the exact document ID and a
  deterministic revision over every persisted field. The Store compares that
  revision in constant time inside the same SQLite transaction that deletes
  the document and its FTS row, so stale or forged confirmations do not mutate.
  """

  alias LemonMemory.{Document, Safety, Store}

  @max_results 50
  @max_scan 200
  @max_query_bytes 256
  @max_filter_bytes 96
  @doc_id_regex ~r/^mem_[A-Za-z0-9_-]{1,120}$/
  @digest_regex ~r/^[a-f0-9]{64}$/
  @workspace_digest_regex ~r/^[a-f0-9]{12}(?:[a-f0-9]{52})?$/
  @safe_agent_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$/
  @allowed_scopes ~w(all session workspace agent global)
  @allowed_kinds ~w(all run learned_source)
  @allowed_source_types ~w(file folder url git_diff session document notebook pdf office unknown)

  @type result :: {:ok, map()} | {:error, atom()}

  @doc "List or full-text search a bounded recent window using safe filters."
  @spec list(map() | keyword(), keyword()) :: result()
  def list(filters \\ %{}, opts \\ []) do
    with {:ok, normalized} <- normalize_filters(filters),
         {:ok, docs} <- load_documents(normalized, opts),
         {:ok, summaries} <- summarize_many(docs),
         filtered <- Enum.filter(summaries, &matches?(&1, normalized)) do
      items = Enum.take(filtered, normalized.limit)

      {:ok,
       %{
         items: items,
         count: length(items),
         truncated: length(filtered) > normalized.limit or length(docs) == @max_scan,
         filters: public_filters(normalized),
         limits: %{items: normalized.limit, scanned: @max_scan}
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :memory_unavailable}
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  @doc "Return one exact, bounded, redacted document preview."
  @spec inspect_document(String.t(), keyword()) :: result()
  def inspect_document(doc_id, opts \\ []) do
    with :ok <- validate_doc_id(doc_id),
         {:ok, doc} <- store(opts).get_document(server(opts), doc_id),
         {:ok, summary} <- summarize(doc, preview: true) do
      {:ok, summary}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} when reason in [:invalid_document_id, :unsafe_record] -> {:error, reason}
      _ -> {:error, :memory_unavailable}
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  @doc "Preview exact single-record deletion without mutating memory."
  @spec preview_delete(String.t(), keyword()) :: result()
  def preview_delete(doc_id, opts \\ []) do
    with :ok <- validate_doc_id(doc_id),
         {:ok, doc} <- store(opts).get_document(server(opts), doc_id),
         {:ok, summary} <- summarize(doc, preview: true) do
      revision = store(opts).document_revision(doc)

      {:ok,
       %{
         document: summary,
         revision: revision,
         confirmation_digest: delete_confirmation(doc_id, revision),
         dry_run: true
       }}
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} when reason in [:invalid_document_id, :unsafe_record] -> {:error, reason}
      _ -> {:error, :memory_unavailable}
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  @doc "Delete one exact record after a fresh, matching preview digest."
  @spec delete(String.t(), String.t(), keyword()) :: result()
  def delete(doc_id, confirmation_digest, opts \\ []) do
    with :ok <- validate_doc_id(doc_id),
         :ok <- validate_digest(confirmation_digest) do
      lock = {__MODULE__, doc_id}

      :global.trans(lock, fn ->
        with {:ok, doc} <- store(opts).get_document(server(opts), doc_id),
             revision = store(opts).document_revision(doc),
             expected = delete_confirmation(doc_id, revision),
             true <- secure_equal?(expected, confirmation_digest),
             {:ok, status} <-
               store(opts).delete_document_if_unchanged(server(opts), doc_id, revision) do
          case status do
            :deleted -> {:ok, %{status: :deleted, document_id: doc_id}}
            :not_found -> {:error, :not_found}
            :stale -> {:error, :stale}
          end
        else
          false -> {:error, :confirmation_mismatch}
          {:error, :not_found} -> {:error, :not_found}
          {:error, _} -> {:error, :memory_unavailable}
          _ -> {:error, :memory_unavailable}
        end
      end)
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end

  defp load_documents(%{query: ""}, opts) do
    store(opts).list_recent(server(opts), limit: @max_scan)
  end

  defp load_documents(%{query: query}, opts) do
    {:ok, store(opts).search(server(opts), query, scope: :all, limit: @max_scan)}
  end

  defp summarize_many(docs) when is_list(docs) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, acc} ->
      case summarize(doc, preview: false) do
        {:ok, summary} -> {:cont, {:ok, [summary | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summaries} -> {:ok, Enum.reverse(summaries)}
      error -> error
    end
  end

  defp summarize(%Document{} = doc, opts) do
    case validate_doc_id(doc.doc_id) do
      :ok ->
        kind = kind(doc)
        {prompt, prompt_redactions} = Safety.redact_for_operator(doc.prompt_summary, max_bytes: 480)

        {answer, answer_redactions} =
          if doc.outcome == :failure do
            {"Preview withheld for a failed run.", 0}
          else
            Safety.redact_for_operator(doc.answer_summary, max_bytes: 1_200)
          end

        base = %{
          id: doc.doc_id,
          scope: Atom.to_string(doc.scope),
          kind: kind,
          agent: safe_agent(doc.agent_id),
          workspace_digest: workspace_digest(doc.workspace_key),
          ingested_at_ms: doc.ingested_at_ms,
          outcome: safe_outcome(doc.outcome),
          record_digest: Store.document_revision(doc),
          redaction_count: prompt_redactions + answer_redactions,
          excerpt: excerpt(if(answer == "", do: prompt, else: answer)),
          provenance: provenance(doc)
        }

        if Keyword.get(opts, :preview, false) do
          {:ok, Map.merge(base, %{prompt_preview: prompt, answer_preview: answer})}
        else
          {:ok, base}
        end

      _ -> {:error, :unsafe_record}
    end
  end

  defp kind(%Document{meta: meta}) when is_map(meta) do
    if map_value(meta, "kind") == "learned_source", do: "learned_source", else: "run"
  end

  defp kind(_), do: "run"

  defp provenance(%Document{} = doc) do
    if kind(doc) == "learned_source" do
      meta = if is_map(doc.meta), do: doc.meta, else: %{}
      source_digest = valid_digest_or_nil(map_value(meta, "source_digest"))
      entries = map_value(meta, "source_provenance")

      %{
        source_digest: source_digest,
        source_count: bounded_integer(map_value(meta, "source_count"), 0, 16),
        source_text_redacted: map_value(meta, "source_text_redacted") == true,
        sources: sanitize_provenance(entries)
      }
    else
      nil
    end
  end

  defp sanitize_provenance(entries) when is_list(entries) do
    entries
    |> Enum.take(16)
    |> Enum.map(fn entry ->
      %{
        type: safe_source_type(map_value(entry, "type")),
        reference_digest: valid_digest_or_nil(map_value(entry, "referenceDigest")),
        content_digest: valid_digest_or_nil(map_value(entry, "contentDigest")),
        selected_items: bounded_integer(map_value(entry, "selectedItems"), 0, 10_000),
        selected_bytes: bounded_integer(map_value(entry, "selectedBytes"), 0, 1_000_000),
        redaction_count: bounded_integer(map_value(entry, "redactionCount"), 0, 10_000)
      }
    end)
  end

  defp sanitize_provenance(_), do: []

  defp normalize_filters(filters) when is_list(filters), do: normalize_filters(Map.new(filters))

  defp normalize_filters(filters) when is_map(filters) do
    with {:ok, query} <- normalize_query(value(filters, :query, "")),
         {:ok, scope} <- enum_filter(value(filters, :scope, "all"), @allowed_scopes),
         {:ok, kind} <- enum_filter(value(filters, :kind, "all"), @allowed_kinds),
         {:ok, agent} <- optional_filter(value(filters, :agent, ""), :agent),
         {:ok, workspace_digest} <-
           optional_filter(value(filters, :workspace_digest, ""), :workspace),
         {:ok, limit} <- normalize_limit(value(filters, :limit, 25)) do
      {:ok,
       %{
         query: query,
         scope: scope,
         kind: kind,
         agent: agent,
         workspace_digest: workspace_digest,
         limit: limit
       }}
    end
  end

  defp normalize_filters(_), do: {:error, :invalid_filters}

  defp normalize_query(query) when is_binary(query) and byte_size(query) <= @max_query_bytes do
    {redacted, _count} = Safety.redact_for_operator(query, max_bytes: @max_query_bytes)
    trimmed = String.trim(redacted)

    normalized =
      trimmed
      |> String.replace(~r/["*():.,!?;]+/u, " ")
      |> String.split()
      |> Enum.join(" ")

    cond do
      trimmed == "" -> {:ok, ""}
      normalized == "" -> {:error, :invalid_query}
      true -> {:ok, normalized}
    end
  end

  defp normalize_query(_), do: {:error, :invalid_query}

  defp enum_filter(value, allowed) when is_binary(value) do
    value = String.downcase(String.trim(value))
    if value in allowed, do: {:ok, value}, else: {:error, :invalid_filter}
  end

  defp enum_filter(_, _), do: {:error, :invalid_filter}

  defp optional_filter(value, type)
       when is_binary(value) and byte_size(value) <= @max_filter_bytes do
    value = String.trim(value)

    case {value, type} do
      {"", _} ->
        {:ok, ""}

      {agent, :agent} ->
        if safe_agent?(agent), do: {:ok, agent}, else: {:error, :invalid_filter}

      {digest, :workspace} ->
        if Regex.match?(@workspace_digest_regex, digest),
          do: {:ok, digest},
          else: {:error, :invalid_filter}
    end
  end

  defp optional_filter(_, _), do: {:error, :invalid_filter}

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> normalize_limit(parsed)
      _ -> {:error, :invalid_limit}
    end
  end

  defp normalize_limit(value) when is_integer(value) and value in 1..@max_results,
    do: {:ok, value}

  defp normalize_limit(_), do: {:error, :invalid_limit}

  defp matches?(summary, filters) do
    (filters.scope == "all" or summary.scope == filters.scope) and
      (filters.kind == "all" or summary.kind == filters.kind) and
      (filters.agent == "" or summary.agent == filters.agent) and
      (filters.workspace_digest == "" or
         String.starts_with?(summary.workspace_digest || "", filters.workspace_digest))
  end

  defp public_filters(filters),
    do: Map.take(filters, [:query, :scope, :kind, :agent, :workspace_digest])

  defp safe_agent(agent) when is_binary(agent) do
    if safe_agent?(agent), do: agent, else: "agent-" <> String.slice(sha256(agent), 0, 12)
  end

  defp safe_agent(_), do: "agent-unknown"
  defp safe_agent?(agent), do: Regex.match?(@safe_agent_regex, agent)

  defp workspace_digest(nil), do: nil
  defp workspace_digest(value) when is_binary(value), do: String.slice(sha256(value), 0, 12)
  defp workspace_digest(value), do: String.slice(sha256(inspect(value)), 0, 12)

  defp safe_outcome(value) when value in [:success, :partial, :failure, :aborted, :unknown],
    do: Atom.to_string(value)

  defp safe_outcome(_), do: "unknown"

  defp excerpt(text) when is_binary(text) do
    if byte_size(text) <= 180,
      do: text,
      else: binary_part(text, 0, utf8_boundary(text, 180)) <> "…"
  end

  defp validate_doc_id(doc_id)
       when is_binary(doc_id) and byte_size(doc_id) <= 124 do
    if Regex.match?(@doc_id_regex, doc_id), do: :ok, else: {:error, :invalid_document_id}
  end

  defp validate_doc_id(_), do: {:error, :invalid_document_id}

  defp validate_digest(digest) when is_binary(digest) do
    if Regex.match?(@digest_regex, digest), do: :ok, else: {:error, :invalid_confirmation}
  end

  defp validate_digest(_), do: {:error, :invalid_confirmation}

  defp delete_confirmation(doc_id, revision),
    do: sha256("memory-delete-v1\0" <> doc_id <> "\0" <> revision)

  defp valid_digest_or_nil(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: value, else: nil
  end

  defp valid_digest_or_nil(_), do: nil

  defp safe_source_type(value) when is_atom(value), do: safe_source_type(Atom.to_string(value))

  defp safe_source_type(value) when is_binary(value) do
    if value in @allowed_source_types, do: value, else: "unknown"
  end

  defp safe_source_type(_), do: "unknown"

  defp bounded_integer(value, lower, upper) when is_integer(value),
    do: value |> Kernel.max(lower) |> Kernel.min(upper)

  defp bounded_integer(_, lower, _upper), do: lower

  defp map_value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_atom_key(key))
    end
  end

  defp map_value(_, _), do: nil

  defp known_atom_key("kind"), do: :kind
  defp known_atom_key("source_digest"), do: :source_digest
  defp known_atom_key("source_count"), do: :source_count
  defp known_atom_key("source_provenance"), do: :source_provenance
  defp known_atom_key("source_text_redacted"), do: :source_text_redacted
  defp known_atom_key("type"), do: :type
  defp known_atom_key("referenceDigest"), do: :referenceDigest
  defp known_atom_key("contentDigest"), do: :contentDigest
  defp known_atom_key("selectedItems"), do: :selectedItems
  defp known_atom_key("selectedBytes"), do: :selectedBytes
  defp known_atom_key("redactionCount"), do: :redactionCount
  defp known_atom_key(_), do: nil

  defp value(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: :crypto.hash_equals(left, right)

  defp secure_equal?(_, _), do: false

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp utf8_boundary(text, position) when position > 0 do
    if String.valid?(binary_part(text, 0, position)),
      do: position,
      else: utf8_boundary(text, position - 1)
  end

  defp utf8_boundary(_text, 0), do: 0

  defp store(opts), do: Keyword.get(opts, :store, Store)
  defp server(opts), do: Keyword.get(opts, :server, Store)
end
