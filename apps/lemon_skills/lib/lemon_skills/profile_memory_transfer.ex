defmodule LemonSkills.ProfileMemoryTransfer do
  @moduledoc """
  Private, destination-local full memory transfer. Paths come exclusively from
  ProfileStore. Frozen source snapshots and target intents/previews/receipts live
  in the selected memory Store, never in management projections or run history.

  Create-only is the default. Overwrite requires a persisted opaque preview token
  and an unchanged destination digest. A pending operation is never replayed;
  status only reads its journal. SQLite rows and receipt commit together after
  staged preferences publish under their owning lock. The Store process owns
  that lock through commit and known rollback, even if the requesting caller dies.
  Uncertain publication/commit retains private backups and returns transfer_pending.

  opts: profile_opts, store (Store server), and optional node_id. Portable records
  retain complete summary/fact bytes and explicitly allowed scoped metadata, not
  raw run metadata. Non-home repositories retain opaque workspace identities;
  no source filesystem path is transported. validate checks the full source
  revision, including excluded metadata, before the controller's first apply.
  """
  alias LemonCore.{JSONPayload, ProfileStore}
  alias LemonMemory.{ContextScope, Document, Project, Safety, Store}
  alias LemonSkills.WorkspacePreferences, as: Preferences

  @envelope ~w(profileId mutationId sourceNodeId nodeId snapshotDigest snapshot)
  @snapshot ~w(version profileId mutationId sourceNodeId nodeId homeDigest documents preferences)
  @record ~w(id agentId homeDigest workspace scope runId sessionKey startedAtMs ingestedAtMs promptSummary answerSummary toolsUsed provider model outcome metadata revision)
  @ownership ~w(memory_scope memory_context_key memory_context_verified memory_shared_verified)
  @metadata ~w(kind home_digest source_digest source_count source_provenance source_text_redacted preference_facts) ++ @ownership
  @scopes ~w(session workspace agent global)
  @outcomes ~w(unknown success partial failure aborted)
  @max_bytes 2 * 1024 * 1024

  def prepare(profile, mutation, source, destination, opts \\ []) do
    protect(fn ->
      with {:ok, context} <- context(profile, mutation, source, destination, opts) do
        case Store.transfer_get(context.store, key("source", profile, mutation)) do
          {:ok, envelope} -> bound(envelope, context)
          {:error, :not_found} ->
            with {:ok, snapshot} <- capture(context),
                 envelope = envelope(context, snapshot),
                 {:ok, frozen} <- Store.transfer_put_new(context.store, key("source", profile, mutation), envelope) do
              bound(frozen, context)
            end
          _ -> {:error, :memory_unavailable}
        end
      end
    end)
  end

  def snapshot(profile, mutation, source, destination, opts \\ []) do
    protect(fn ->
      with {:ok, context} <- context(profile, mutation, source, destination, opts),
           {:ok, envelope} <- Store.transfer_get(context.store, key("source", profile, mutation)) do
        bound(envelope, context)
      end
    end)
  end

  def validate(envelope, opts \\ []) do
    protect(fn ->
      with {:ok, context, base} <- decode(envelope, opts),
           {:ok, frozen} <- snapshot(context.profile, context.mutation, context.source, context.destination, opts),
           true <- frozen == base do
        with {:ok, current} <- capture(context) do
          if digest(current) == base["snapshotDigest"], do: :ok, else: {:error, :stale_source}
        end
      else
        false -> {:error, :transfer_conflict}
        error -> error
      end
    end)
  end

  def preview(envelope, opts \\ []) do
    protect(fn ->
      with {:ok, context, base} <- decode(envelope, opts, true),
           :ok <- destination(context, opts),
           :ok <- available_operation(context, base) do
        with {:ok, target, _} <- capture_target(context),
             target_digest = digest(target),
             preview = Map.merge(receipt(base), %{
               "destinationDigest" => target_digest,
               "confirmationToken" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
               "sourceCounts" => counts(base["snapshot"]),
               "destinationCounts" => counts(target),
               "overwrite" => occupied?(target)
             }) |> Map.delete("copied"),
             entry = %{"binding" => binding(base), "preview" => preview},
             {:ok, saved} <- Store.transfer_put_new(context.store, preview_key(context, target_digest), entry),
             true <- saved["binding"] == binding(base) do
          {:ok, saved["preview"]}
        else
          false -> {:error, :transfer_conflict}
          error -> error
        end
      end
    end)
  end

  def apply_transfer(envelope, opts \\ []) do
    protect(fn ->
      with {:ok, context, base} <- decode(envelope, opts, true),
           :ok <- destination(context, opts) do
        case operation(context, base) do
          {:ok, receipt} -> {:ok, receipt}
          {:error, :not_found} -> apply_new(context, base, envelope)
          error -> error
        end
      end
    end)
  end

  def status(profile, mutation, source, destination, opts \\ []) do
    protect(fn ->
      with {:ok, context} <- context(profile, mutation, source, destination, opts),
           :ok <- destination(context, opts),
           {:ok, entry} <- Store.transfer_get(context.store, key("destination", profile, mutation)) do
        if identifiers(entry["binding"], context) and entry["destinationHomeDigest"] == context.home do
          if entry["receipt"], do: {:ok, entry["receipt"]}, else: {:error, :transfer_pending}
        else
          {:error, :transfer_conflict}
        end
      end
    end)
  end

  @doc "Read destination journal state without preparing, applying, replaying or writing."
  def inspect_status(profile, mutation, node_id, opts \\ []) do
    protect(fn ->
      with {:ok, context} <- context(profile, mutation, "local", node_id, opts),
           :ok <- destination(context, opts) do
        case Store.transfer_get(context.store, key("destination", profile, mutation)) do
          {:error, :not_found} -> {:ok, inspection(context, nil, "unknown", nil)}
          {:ok, entry} -> inspect_entry(entry, context)
          error -> error
        end
      end
    end)
  end

  defp inspect_entry(entry, context) when is_map(entry) do
    binding = entry["binding"]
    cond do
      not is_map(binding) -> {:error, :memory_unavailable}
      binding["profileId"] != context.profile or binding["mutationId"] != context.mutation or
        binding["nodeId"] != context.destination or entry["destinationHomeDigest"] != context.home ->
          {:error, :transfer_conflict}
      Enum.sort(Map.keys(binding)) != Enum.sort(@envelope -- ["snapshot"]) or
        not identifier?(binding["sourceNodeId"], 128) or not valid_digest?(binding["snapshotDigest"]) ->
          {:error, :memory_unavailable}
      entry["state"] == "pending" and entry["receipt"] == nil ->
        {:ok, inspection(context, binding, "pending", nil)}
      entry["state"] == "complete" and entry["receipt"] == Map.put(binding, "copied", true) ->
        {:ok, inspection(context, binding, "completed", entry["receipt"])}
      true -> {:error, :memory_unavailable}
    end
  end
  defp inspect_entry(_, _), do: {:error, :memory_unavailable}

  defp inspection(context, binding, status, receipt) do
    %{"profileId" => context.profile, "mutationId" => context.mutation,
      "nodeId" => context.destination, "sourceNodeId" => if(binding, do: binding["sourceNodeId"], else: nil),
      "snapshotDigest" => if(binding, do: binding["snapshotDigest"], else: nil),
      "status" => status, "receipt" => receipt}
  end

  defp apply_new(context, base, controls) do
    with {:ok, target, revisions} <- capture_target(context),
         :ok <- authorize_target(context, base, controls, target),
         {:ok, docs} <- import_documents(base["snapshot"]["documents"], context),
         {:ok, stage} <- Preferences.transfer_stage(context.workspace, base["snapshot"]["preferences"], target["preferences"]) do
      intent = %{"binding" => binding(base), "state" => "pending",
        "destinationHomeDigest" => context.home, "stagingId" => Path.basename(stage.dir)}
      case Store.transfer_put_new(context.store, key("destination", context.profile, context.mutation), intent) do
        {:ok, ^intent} ->
          commit_import(context, base, target, revisions, docs, stage, intent)
        {:ok, _} -> Preferences.transfer_cleanup(stage); operation(context, base)
        _ -> Preferences.transfer_cleanup(stage); {:error, :memory_unavailable}
      end
    end
  end
  defp commit_import(context, base, target, revisions, docs, stage, intent) do
    publication = :atomics.new(1, [])
    completed = Map.put(intent, "receipt", receipt(base)) |> Map.put("state", "complete")
    result = Store.transfer_import(context.store, context.profile, context.home, revisions, docs,
      key("destination", context.profile, context.mutation), completed, fn ->
        with {:ok, current} <- Preferences.transfer_snapshot(context.workspace, screen: false),
             true <- current == target["preferences"] do
          :atomics.put(publication, 1, 1)
          Preferences.transfer_publish(stage)
        else
          false -> {:error, :stale_destination}
          error -> error
        end
      end,
      boundary: fn run ->
        Preferences.transfer_locked(context.workspace, fn ->
          case run.() do
            {:ok, _} = result -> Preferences.transfer_cleanup(stage); result
            error -> error
          end
        end)
      end,
      rollback: fn ->
        if :atomics.get(publication, 1) == 1, do: Preferences.transfer_restore(stage), else: :ok
      end)
    case result do
      {:ok, _} -> {:ok, receipt(base)}
      {:error, :transfer_pending} -> {:error, :transfer_pending}
      _ -> {:error, :transfer_pending}
    end
  rescue
    _ -> {:error, :transfer_pending}
  catch
    _, _ -> {:error, :transfer_pending}
  end

  defp capture_target(context) do
    Store.transfer_snapshot(context.store, context.profile, context.home, fn docs ->
      Preferences.transfer_locked(context.workspace, fn ->
        with {:ok, files} <- Preferences.transfer_snapshot(context.workspace, screen: false) do
          revisions = Store.transfer_revisions(docs)
          target = %{"profileId" => context.profile, "homeDigest" => context.home,
            "documents" => Enum.map(revisions, fn {id, revision} -> [id, revision] end),
            "preferences" => files}
          {:ok, {target, revisions}}
        end
      end)
    end)
    |> case do
      {:ok, {target, revisions}} -> {:ok, target, revisions}
      error -> error
    end
  end


  defp authorize_target(context, base, controls, target) do
    token = controls["confirmationToken"]
    destination_digest = controls["destinationDigest"]
    cond do
      token == nil and destination_digest == nil and not occupied?(target) -> :ok
      token == nil and destination_digest == nil -> {:error, :destination_conflict}
      not is_binary(token) or not valid_digest?(destination_digest) -> {:error, :confirmation_mismatch}
      destination_digest != digest(target) -> {:error, :stale_destination}
      true ->
        case Store.transfer_get(context.store, preview_key(context, destination_digest)) do
          {:ok, %{"binding" => saved, "preview" => preview}} ->
            if saved == binding(base) and preview["confirmationToken"] == token,
              do: :ok, else: {:error, :confirmation_mismatch}
          {:error, :not_found} -> {:error, :confirmation_mismatch}
          _ -> {:error, :memory_unavailable}
        end
    end
  end

  defp operation(context, base) do
    case Store.transfer_get(context.store, key("destination", context.profile, context.mutation)) do
      {:ok, entry} ->
        cond do
          entry["binding"] != binding(base) or entry["destinationHomeDigest"] != context.home -> {:error, :transfer_conflict}
          entry["receipt"] != nil -> {:ok, entry["receipt"]}
          true -> {:error, :transfer_pending}
        end
      error -> error
    end
  end

  defp available_operation(context, base) do
    case operation(context, base) do
      {:error, :not_found} -> :ok
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp capture(context) do
    with {:ok, snapshot, _} <- capture_with_revisions(context), do: {:ok, snapshot}
  end

  defp capture_with_revisions(context) do
    Store.transfer_snapshot(context.store, context.profile, context.home, fn docs ->
      Preferences.transfer_locked(context.workspace, fn ->
        with {:ok, files} <- Preferences.transfer_snapshot(context.workspace),
             {:ok, records} <- export_documents(docs, context) do
          snapshot = %{"version" => 1, "profileId" => context.profile, "mutationId" => context.mutation,
            "sourceNodeId" => context.source, "nodeId" => context.destination, "homeDigest" => context.home,
            "documents" => records, "preferences" => files}
          with :ok <- snapshot_payload(snapshot) do
            {:ok, {snapshot, Store.transfer_revisions(docs)}}
          end
        end
      end)
    end)
    |> case do
      {:ok, {snapshot, revisions}} -> {:ok, snapshot, revisions}
      error -> error
    end
  end

  defp export_documents(docs, context) do
    Enum.reduce_while(docs, {:ok, []}, fn doc, {:ok, records} ->
      with {:ok, metadata} <- normalize_metadata(portable_metadata(doc)) do
        record = %{"id" => doc.doc_id, "agentId" => doc.agent_id, "homeDigest" => context.home,
          "workspace" => workspace(doc.workspace_key, context), "scope" => to_string(doc.scope),
          "runId" => doc.run_id, "sessionKey" => doc.session_key, "startedAtMs" => doc.started_at_ms,
          "ingestedAtMs" => doc.ingested_at_ms, "promptSummary" => doc.prompt_summary,
          "answerSummary" => doc.answer_summary, "toolsUsed" => doc.tools_used, "provider" => doc.provider,
          "model" => doc.model, "outcome" => to_string(doc.outcome), "metadata" => metadata,
          "revision" => Store.document_revision(doc)}
        with true <- not secret_term?(doc.meta),
             :ok <- validate_record(record, context.profile, context.home) do
          {:cont, {:ok, [record | records]}}
        else
          false -> {:halt, {:error, :unsafe_snapshot}}
          error -> {:halt, error}
        end
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.sort_by(records, & &1["id"])}
      error -> error
    end
  end

  defp portable_metadata(doc) do
    metadata =
      doc.meta
      |> Enum.reject(fn {key, _value} -> memory_key(key) in @ownership end)
      |> Map.new()

    owner =
      case Store.document_ownership(doc) do
        :legacy -> ContextScope.metadata(:legacy)
        :shared -> ContextScope.metadata(:shared)
        {:private, key} -> ContextScope.metadata({:private, key})
        :unproven -> %{"memory_scope" => "unproven"}
      end

    Map.merge(metadata, owner)
  end

  defp normalize_metadata(meta) do
    Enum.reduce_while(meta, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      key = memory_key(key)
      if key in @metadata do
        with {:ok, value} <- metadata_value(key, value),
             {:ok, normalized} <- put_unique(normalized, key, value) do
          {:cont, {:ok, normalized}}
        else
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, normalized}}
      end
    end)
  end

  defp metadata_value("kind", value) when is_atom(value) and not is_nil(value),
    do: {:ok, Atom.to_string(value)}
  defp metadata_value("source_provenance", entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, normalized} ->
      case normalize_provenance(entry) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end
  defp metadata_value(_, value), do: {:ok, value}

  defp normalize_provenance(entry) when is_map(entry) do
    Enum.reduce_while(entry, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      key = memory_key(key)
      value = if key == "type" and is_atom(value) and value != nil,
        do: Atom.to_string(value), else: value
      if is_binary(key) do
        case put_unique(normalized, key, value) do
          {:ok, normalized} -> {:cont, {:ok, normalized}}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :invalid_snapshot}}
      end
    end)
  end
  defp normalize_provenance(_), do: {:error, :invalid_snapshot}
  defp memory_key(key) when is_binary(key), do: key
  defp memory_key(key) when is_atom(key), do: Atom.to_string(key)
  defp memory_key(_), do: nil

  defp put_unique(map, key, value) do
    case Map.fetch(map, key) do
      :error -> {:ok, Map.put(map, key, value)}
      {:ok, ^value} -> {:ok, map}
      {:ok, _} -> {:error, :invalid_snapshot}
    end
  end

  defp workspace(nil, _), do: nil
  defp workspace("sha256:" <> digest = value, context) do
    if valid_digest?(digest), do: value, else: workspace_digest(value, context)
  end
  defp workspace(value, context), do: workspace_digest(value, context)
  defp workspace_digest(value, context) do
    if Path.expand(value) in [Path.expand(context.workspace), context.root],
      do: "home", else: "sha256:" <> sha(value)
  end

  defp import_documents(records, context) do
    docs = Enum.map(records, fn record ->
      metadata = Map.put(record["metadata"], "home_digest", context.home)
      workspace = if record["workspace"] == "home" do
        if metadata["kind"] == "project_learning", do: context.root, else: context.workspace
      else
        record["workspace"]
      end
      fallback_id = "mem_transfer_" <> sha(context.profile <> "\0" <> context.home <> "\0" <> record["id"])
      id =
        if metadata["kind"] == "project_learning" and record["workspace"] == "home" do
          destination = %{session_scope: :main, agent_id: context.profile,
            workspace_dir: context.workspace, cwd: context.workspace}
          case Project.transfer_document_id(destination, metadata) do
            {:ok, id} -> id
            _ -> fallback_id
          end
        else
          fallback_id
        end
      %Document{doc_id: id, agent_id: context.profile, workspace_key: workspace,
        run_id: record["runId"], session_key: record["sessionKey"],
        scope: String.to_existing_atom(record["scope"]), started_at_ms: record["startedAtMs"],
        ingested_at_ms: record["ingestedAtMs"], prompt_summary: record["promptSummary"],
        answer_summary: record["answerSummary"], tools_used: record["toolsUsed"],
        provider: record["provider"], model: record["model"], outcome: String.to_existing_atom(record["outcome"]), meta: metadata}
      |> Document.with_index()
    end)
    if length(Enum.uniq_by(docs, & &1.doc_id)) == length(docs), do: {:ok, docs}, else: {:error, :invalid_snapshot}
  end

  defp decode(value, opts, allow_controls \\ false) do
    with true <- is_map(value) and Enum.all?(Map.keys(value), &is_binary/1),
         true <- Enum.sort(Map.keys(value)) == Enum.sort(@envelope) or
           (allow_controls and Enum.sort(Map.keys(value)) == Enum.sort(@envelope ++ ~w(confirmationToken destinationDigest))),
         true <- not Map.has_key?(value, "confirmationToken") or
           (is_binary(value["confirmationToken"]) and byte_size(value["confirmationToken"]) in 1..512 and
             Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value["confirmationToken"]) and valid_digest?(value["destinationDigest"])),
         {:ok, context} <- context(value["profileId"], value["mutationId"], value["sourceNodeId"], value["nodeId"], opts),
         :ok <- validate_snapshot(value["snapshot"], context),
         true <- valid_digest?(value["snapshotDigest"]) and digest(value["snapshot"]) == value["snapshotDigest"] do
      {:ok, context, Map.take(value, @envelope)}
    else
      false -> {:error, :invalid_snapshot}
      error -> error
    end
  end

  defp validate_snapshot(snapshot, context) do
    cond do
      not is_map(snapshot) or Enum.sort(Map.keys(snapshot)) != Enum.sort(@snapshot) -> {:error, :invalid_snapshot}
      snapshot["version"] != 1 or not identifiers(snapshot, context) -> {:error, :profile_mismatch}
      not valid_digest?(snapshot["homeDigest"]) -> {:error, :invalid_snapshot}
      not is_list(snapshot["documents"]) -> {:error, :invalid_snapshot}
      length(snapshot["documents"]) > 500 -> {:error, :snapshot_too_large}
      not is_map(snapshot["preferences"]) or Enum.sort(Map.keys(snapshot["preferences"])) != ["MEMORY.md", "USER.md"] -> {:error, :invalid_snapshot}
      true ->
        with :ok <- snapshot_payload(snapshot),
             true <- json?(snapshot),
             :ok <- Preferences.transfer_text(snapshot["preferences"]["USER.md"]),
             :ok <- Preferences.transfer_text(snapshot["preferences"]["MEMORY.md"]),
             true <- Enum.all?(snapshot["documents"], &is_map/1),
             true <- length(Enum.uniq_by(snapshot["documents"], & &1["id"])) == length(snapshot["documents"]) do
          Enum.reduce_while(snapshot["documents"], :ok, fn record, :ok ->
            case validate_record(record, context.profile, snapshot["homeDigest"]) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        else
          false -> {:error, :invalid_snapshot}
          error -> error
        end
    end
  end

  # Reserve container/item headroom for envelope, invocation, result and frame.
  # Use the node protocol's actual policy rather than a second traversal counter.
  defp snapshot_payload(snapshot) do
    case JSONPayload.validate(snapshot,
           max_bytes: @max_bytes,
           max_items: JSONPayload.default_max_items() - 64,
           max_depth: JSONPayload.default_max_depth() - 8) do
      {:ok, _} -> :ok
      {:error, {limit, _}} when limit in [:max_bytes, :max_items, :max_depth] ->
        {:error, :snapshot_too_large}
      {:error, _} -> {:error, :invalid_snapshot}
    end
  end

  defp validate_record(record, profile, home) do
    cond do
      not is_map(record) or Enum.sort(Map.keys(record)) != Enum.sort(@record) -> {:error, :invalid_snapshot}
      not is_map(record["metadata"]) or not Enum.all?(Map.keys(record["metadata"]), &(&1 in @metadata)) -> {:error, :invalid_snapshot}
      record["agentId"] != profile or record["homeDigest"] != home or record["metadata"]["home_digest"] != home -> {:error, :profile_mismatch}
      not json?(record) -> {:error, :invalid_snapshot}
      secret_term?(record) -> {:error, :unsafe_snapshot}
      not identifier?(record["id"], 256) or
        not Enum.all?(~w(runId sessionKey), &label?(record[&1], 256)) -> {:error, :invalid_snapshot}
      not valid_digest?(record["revision"]) -> {:error, :invalid_snapshot}
      record["scope"] not in @scopes or record["outcome"] not in @outcomes -> {:error, :invalid_snapshot}
      not Enum.all?(~w(startedAtMs ingestedAtMs), &(is_integer(record[&1]) and record[&1] >= 0)) -> {:error, :invalid_snapshot}
      not Enum.all?(~w(promptSummary answerSummary), &(is_binary(record[&1]) and String.valid?(record[&1]) and not String.contains?(record[&1], <<0>>))) -> {:error, :invalid_snapshot}
      not is_list(record["toolsUsed"]) or not Enum.all?(record["toolsUsed"], &label?(&1, 128)) -> {:error, :invalid_snapshot}
      not Enum.all?(~w(provider model), &(record[&1] == nil or label?(record[&1], 128))) -> {:error, :invalid_snapshot}
      record["workspace"] != nil and record["workspace"] != "home" and not workspace_digest?(record["workspace"]) -> {:error, :invalid_snapshot}
      not safe_metadata?(record["metadata"]) -> {:error, :invalid_snapshot}
      true -> :ok
    end
  end

  defp safe_metadata?(meta) do
    Enum.all?(meta, fn
      {"kind", kind} -> kind in ["run", "learned_source", "project_learning", "user", "memory"]
      {key, value} when key in ["home_digest", "source_digest"] -> valid_digest?(value)
      {"source_count", value} -> is_integer(value) and value >= 0
      {"source_text_redacted", value} -> is_boolean(value)
      {"memory_scope", value} -> value in ["legacy", "unproven", "private", "shared"]
      {"memory_context_key", value} -> ContextScope.valid_key?(value)
      {key, value} when key in ["memory_context_verified", "memory_shared_verified"] -> value == true
      {"preference_facts", facts} when is_list(facts) ->
        length(facts) in 1..50 and Enum.all?(facts, fn fact ->
          is_binary(fact) and byte_size(fact) <= 4096 and Safety.validate_note(fact) == :ok
        end)
      {"source_provenance", list} when is_list(list) -> Enum.all?(list, fn item ->
        is_map(item) and Enum.sort(Map.keys(item)) == Enum.sort(~w(type referenceDigest contentDigest selectedItems selectedBytes redactionCount)) and
          identifier?(item["type"], 64) and valid_digest?(item["referenceDigest"]) and valid_digest?(item["contentDigest"]) and
          Enum.all?(~w(selectedItems selectedBytes redactionCount), &(is_integer(item[&1]) and item[&1] >= 0))
      end)
      _ -> false
    end) and valid_ownership_metadata?(meta)
  end

  defp valid_ownership_metadata?(meta) do
    ownership = Map.take(meta, @ownership)
    case meta["memory_scope"] do
      nil -> ownership == %{}
      "legacy" -> ownership == ContextScope.metadata(:legacy)
      "unproven" -> ownership == %{"memory_scope" => "unproven"}
      "shared" -> ownership == ContextScope.metadata(:shared)
      "private" ->
        ContextScope.valid_key?(meta["memory_context_key"]) and
          ownership == ContextScope.metadata({:private, meta["memory_context_key"]})
      _ -> false
    end
  end

  defp context(profile, mutation, source, target, opts) do
    with true <- Keyword.keyword?(opts) and Keyword.keyword?(Keyword.get(opts, :profile_opts, [])),
         true <- is_binary(profile) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/, profile),
         true <- identifier?(mutation, 128) and identifier?(source, 128) and identifier?(target, 128) and target != "local",
         {:ok, paths} <- ProfileStore.paths(profile, Keyword.get(opts, :profile_opts, [])),
         {:ok, identity} <- Project.scope(%{session_scope: :main, agent_id: profile,
           workspace_dir: paths["workspace"], cwd: paths["workspace"]}) do
      {:ok, %{profile: profile, mutation: mutation, source: source, destination: target,
        workspace: paths["workspace"], home: identity.home_digest, root: identity.root,
        store: Keyword.get(opts, :store, Store)}}
    else
      false -> {:error, :invalid_id}
      error -> error
    end
  end

  defp destination(context, opts) do
    if Keyword.get(opts, :node_id, context.destination) == context.destination,
      do: :ok, else: {:error, :node_mismatch}
  end
  defp bound(envelope, context) do
    if identifiers(envelope, context) and envelope["snapshot"]["homeDigest"] == context.home,
      do: {:ok, envelope}, else: {:error, :transfer_conflict}
  end
  defp identifiers(value, context) when is_map(value),
    do: value["profileId"] == context.profile and value["mutationId"] == context.mutation and value["sourceNodeId"] == context.source and value["nodeId"] == context.destination
  defp identifiers(_, _), do: false
  defp envelope(context, snapshot), do: %{"profileId" => context.profile, "mutationId" => context.mutation,
    "sourceNodeId" => context.source, "nodeId" => context.destination, "snapshotDigest" => digest(snapshot), "snapshot" => snapshot}
  defp binding(envelope), do: Map.drop(envelope, ["snapshot"])
  defp receipt(envelope), do: Map.put(binding(envelope), "copied", true)
  defp counts(snapshot), do: %{"documents" => length(snapshot["documents"]), "preferences" => Enum.count(snapshot["preferences"], fn {_, text} -> text != nil end)}
  defp occupied?(snapshot), do: snapshot["documents"] != [] or Enum.any?(snapshot["preferences"], fn {_, text} -> text != nil end)
  defp key(role, profile, mutation), do: role <> ":" <> sha(profile <> "\0" <> mutation)
  defp preview_key(context, destination_digest), do: key("preview", context.profile, context.mutation) <> ":" <> destination_digest
  defp identifier?(value, max), do: is_binary(value) and byte_size(value) in 1..max and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, value)
  defp label?(value, max) do
    is_binary(value) and byte_size(value) in 1..max and String.valid?(value) and
      String.trim(value) != "" and
      not Regex.match?(~r/[\x00-\x1F\x7F-\x9F\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}\x{FEFF}]/u, value)
  end
  defp valid_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)
  defp workspace_digest?("sha256:" <> value), do: valid_digest?(value)
  defp workspace_digest?(_), do: false
  defp secret_term?(value) when is_binary(value), do: Safety.contains_secret?(value)
  defp secret_term?(value) when is_atom(value), do: Safety.contains_secret?(Atom.to_string(value))
  defp secret_term?(value) when is_map(value), do: Enum.any?(value, fn {k, v} -> secret_term?(k) or secret_term?(v) end)
  defp secret_term?(value) when is_list(value), do: Enum.any?(value, &secret_term?/1)
  defp secret_term?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&secret_term?/1)
  defp secret_term?(_), do: false
  defp json?(nil), do: true
  defp json?(value) when is_boolean(value) or is_integer(value), do: true
  defp json?(value) when is_binary(value), do: String.valid?(value)
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)
  defp json?(value) when is_map(value), do: Enum.all?(value, fn {k, v} -> is_binary(k) and json?(k) and json?(v) end)
  defp json?(_), do: false
  defp canonical(value) when is_map(value), do: "{" <> (value |> Enum.sort_by(&elem(&1, 0)) |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"
  defp canonical(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"
  defp canonical(value), do: Jason.encode!(value)
  defp digest(value), do: sha(canonical(value))
  defp sha(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp protect(fun) do
    case fun.() do
      :ok -> :ok
      {:ok, _} = result -> result
      {:error, reason} = error when is_atom(reason) -> error
      _ -> {:error, :memory_unavailable}
    end
  rescue
    _ -> {:error, :memory_unavailable}
  catch
    _, _ -> {:error, :memory_unavailable}
  end
end
