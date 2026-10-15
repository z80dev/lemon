defmodule LemonMemory.Preferences do
  @moduledoc """
  Private and explicitly shared user/memory notes in Store, never workspace files.

  Each note is one revision-bound lifecycle item. Full accepted text lives in
  `preference_facts` metadata; the Document summary is only an index/preview.
  Native reads and remember require admitted context proof. `add/4` also accepts
  an explicit private or shared `:memory_scope` from the trusted management owner.
  """
  alias LemonMemory.{ContextScope, Document, Lifecycle, Project, Safety, Store}
  @caps %{"user" => 1_375, "memory" => 2_200}
  @max_notes 200

  def validate_text(text), do: Safety.validate_note(text)

  def read(context, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, owner} <- native_owner(context),
         {:ok, private} <- load(context, identity, owner, opts),
         {:ok, shared} <- load(context, identity, :shared, opts) do
      {:ok, Enum.flat_map(private ++ shared, &facts/1) |> Enum.uniq()}
    end
  end

  @doc "Return scoped per-kind character usage and the full safe entries."
  def usage(context, kind, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, owner} <- native_owner(context),
         {:ok, kind} <- normalize_kind(kind),
         {:ok, private} <- load(context, identity, owner, opts),
         {:ok, shared} <- load(context, identity, :shared, opts) do
      facts =
        (private ++ shared)
        |> Enum.filter(&(document_kind(&1) == kind))
        |> Enum.flat_map(&facts/1)
        |> Enum.uniq()

      {:ok, %{used: Enum.sum(Enum.map(facts, &String.length/1)), cap: @caps[kind], facts: facts}}
    end
  end

  def read_shared(context, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, _} <- native_owner(context),
         {:ok, docs} <- load(context, identity, :shared, opts) do
      {:ok, Enum.flat_map(docs, &facts/1)}
    end
  end

  @doc "Only canonical, explicitly shared preferences may enter a private bootstrap."
  def shared_bootstrap(context, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, _} <- native_owner(context),
         {:ok, docs} <- load(context, identity, :shared, opts) do
      files =
        for {kind, name, heading} <- [
              {"user", "USER.md", "## Context"},
              {"memory", "MEMORY.md", "## Quick Facts"}
            ],
            into: %{} do
          notes = docs |> Enum.filter(&(document_kind(&1) == kind)) |> Enum.flat_map(&facts/1)

          text =
            if notes == [],
              do: "",
              else:
                LemonMemory.Usage.preferences(kind, Enum.sum(Enum.map(notes, &String.length/1))) <>
                  "\n\n" <> heading <> "\n\n" <> Enum.map_join(notes, "\n", &("- " <> &1))

          {name, text}
        end

      {:ok, files}
    end
  end

  def remember(context, kind, text, replaces \\ nil, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, owner} <- native_owner(context),
         {:ok, kind} <- normalize_kind(kind),
         :ok <- optional_text(text),
         :ok <- optional_stored_text(replaces),
         true <- text != nil or replaces != nil do
      owner = if ContextScope.shared_grant?(context), do: :shared, else: owner

      case mutate(context, identity, owner, kind, text, replaces, opts) do
        {:ok, result} -> {:ok, Map.delete(result, :document)}
        error -> error
      end
    else
      false -> {:error, :empty_text}
      error -> error
    end
  end

  def add(context, kind, text, opts \\ []) do
    with {:ok, identity} <- Project.scope(context),
         {:ok, owner} <- add_owner(context, opts),
         {:ok, kind} <- normalize_kind(kind),
         :ok <- validate_text(text),
         {:ok, result} <- mutate(context, identity, owner, kind, text, nil, opts),
         %Document{} = doc <- result.document do
      Lifecycle.profile_projection(doc)
    end
  end

  @doc "Full safe facts for scoped recall and lexical management search."
  def facts(%Document{meta: meta} = doc) when is_map(meta) do
    kind = document_kind(doc)

    case meta["preference_facts"] || meta[:preference_facts] do
      [text] when kind in ["user", "memory"] and is_binary(text) ->
        if Safety.validate_note(text, screen_exfiltration: false) == :ok and
             String.length(text) <= @caps[kind], do: [text], else: []

      _ ->
        []
    end
  end

  def facts(_), do: []

  defp native_owner(context) do
    case ContextScope.scope(context) do
      {:ok, {:private, _}} = owner -> owner
      _ -> {:error, :unproven_context}
    end
  end

  defp add_owner(context, opts) do
    case Keyword.fetch(opts, :memory_scope) do
      :error ->
        native_owner(context)

      {:ok, :shared} ->
        {:ok, :shared}

      {:ok, {:private, key}} ->
        if ContextScope.valid_key?(key),
          do: {:ok, {:private, key}},
          else: {:error, :invalid_memory_scope}

      _ ->
        {:error, :invalid_memory_scope}
    end
  end

  defp normalize_kind(kind) when kind in [:user, :memory], do: {:ok, Atom.to_string(kind)}
  defp normalize_kind(kind) when kind in ["user", "memory"], do: {:ok, kind}
  defp normalize_kind(_), do: {:error, :invalid_kind}

  defp document_kind(doc) do
    case normalize_kind(doc.meta["kind"] || doc.meta[:kind]) do
      {:ok, kind} -> kind
      _ -> nil
    end
  end

  defp optional_text(nil), do: :ok
  defp optional_text(text), do: validate_text(text)

  defp optional_stored_text(nil), do: :ok
  defp optional_stored_text(text), do: Safety.validate_note(text, screen_exfiltration: false)

  defp load(context, identity, owner, opts) do
    case Store.list_owned_recent(server(opts), identity.agent_id, identity.home_digest, owner,
           preferences_only: true,
           limit: @max_notes + 1
         ) do
      {:ok, docs} ->
        selected =
          Enum.filter(docs, fn doc ->
            Project.profile_document?(doc, context, owner) and
              document_kind(doc) in ["user", "memory"]
          end)

        if length(selected) <= @max_notes and Enum.all?(selected, &(facts(&1) != [])) and
             Enum.all?(Map.keys(@caps), fn kind ->
               selected
               |> Enum.filter(&(document_kind(&1) == kind))
               |> Enum.flat_map(&facts/1)
               |> fits?(kind)
             end), do: {:ok, selected}, else: {:error, :invalid_document}

      _ ->
        {:error, :store_unavailable}
    end
  end

  defp validate_patch(nil, _kind), do: :ok

  defp validate_patch(text, kind) do
    if String.length(text) > @caps[kind],
      do: {:error, :capacity_exceeded},
      else: validate_text(text)
  end

  defp mutate(context, identity, owner, kind, text, replaces, opts) do
    server = server(opts)

    lock =
      {__MODULE__, GenServer.whereis(server) || server, identity.agent_id, identity.home_digest,
       owner}

    :global.trans({lock, self()}, fn ->
      with {:ok, all} <- load(context, identity, owner, opts),
           docs = Enum.filter(all, &(document_kind(&1) == kind)),
           {:ok, _matched, replaces, text} <-
             LemonMemory.NoteMatch.resolve(Enum.flat_map(docs, &facts/1), replaces, text),
           :ok <- validate_patch(text, kind) do
        matches = Enum.filter(docs, &(facts(&1) == [replaces]))
        duplicate = Enum.find(docs, &(facts(&1) == [text]))

        cond do
          replaces != nil and length(matches) != 1 ->
            {:error, :not_found}

          replaces == nil and duplicate != nil ->
            result(false, docs, duplicate)

          replaces != nil and duplicate != nil and text != replaces ->
            save(
              context,
              identity,
              owner,
              kind,
              nil,
              List.first(matches),
              List.delete(docs, List.first(matches)),
              opts
            )

          text == replaces ->
            result(false, docs, List.first(matches))

          true ->
            previous = List.first(matches)
            remaining = if previous, do: List.delete(docs, previous), else: docs

            selected =
              if text,
                do: Enum.flat_map(remaining, &facts/1) ++ [text],
                else: Enum.flat_map(remaining, &facts/1)

            count = length(all) - if(previous, do: 1, else: 0) + if(text, do: 1, else: 0)

            if fits?(selected, kind) and count <= @max_notes do
              save(context, identity, owner, kind, text, previous, remaining, opts)
            else
              {:error, :capacity_exceeded}
            end
        end
      end
    end)
  end

  defp save(_context, _identity, _key, _kind, nil, previous, remaining, opts) do
    case Store.delete_document_if_unchanged(
           server(opts),
           previous.doc_id,
           Store.document_revision(previous)
         ) do
      {:ok, :deleted} -> result(true, remaining, nil)
      {:ok, :stale} -> {:error, :stale}
      _ -> {:error, :store_unavailable}
    end
  end

  defp save(context, identity, owner, kind, text, previous, remaining, opts) do
    doc =
      Document.new(
        doc_id: if(previous, do: previous.doc_id, else: "mem_preference_" <> LemonCore.Id.uuid()),
        run_id: if(previous, do: previous.run_id, else: LemonCore.Id.uuid()),
        session_key:
          if(previous, do: previous.session_key, else: preference_session(identity, owner)),
        agent_id: identity.agent_id,
        workspace_key: Path.expand(context.workspace_dir),
        scope: :agent,
        started_at_ms:
          if(previous, do: previous.started_at_ms, else: System.system_time(:millisecond)),
        prompt_summary: "Durable #{kind} preference",
        answer_summary: text,
        outcome: :success,
        meta:
          Map.merge(
            ContextScope.metadata(owner),
            %{"kind" => kind, "home_digest" => identity.home_digest, "preference_facts" => [text]}
          )
      )

    result =
      if previous do
        Store.put_document_if_unchanged(server(opts), doc, Store.document_revision(previous))
      else
        case Store.put_new_sync(server(opts), doc) do
          {:ok, :created} -> :ok
          _ -> {:error, :store_unavailable}
        end
      end

    case result do
      :ok -> result(true, remaining ++ [doc], doc)
      {:error, :stale} -> {:error, :stale}
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :store_unavailable}
    end
  end

  defp preference_session(identity, owner) do
    value = :erlang.term_to_binary({identity.agent_id, identity.home_digest, owner})
    "memory:preferences:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
  end

  defp result(changed, docs, doc),
    do: {:ok, %{changed: changed, facts: Enum.flat_map(docs, &facts/1), document: doc}}

  defp fits?(facts, kind), do: String.length(Enum.join(facts, "\n")) <= @caps[kind]
  defp server(opts), do: Keyword.get(opts, :store, Store)
end
