defmodule LemonSkills.Timeline do
  @moduledoc """
  Bounded, read-only learning timeline for one agent and assistant home.

  Memory projections come from the owning lifecycle service. Skill timestamps
  come from the existing usage, draft, install and audit sidecars, never mtimes.
  Only home-local skills are implicit owners; global sidecars belong exclusively
  to the canonical default assistant. Explicit foreign skill writers are omitted.
  This is a current-state projection, not a complete historical event log: deleted
  records and superseded edits cannot be reconstructed, and previews show current
  redacted text even for an earlier creation timestamp.
  """

  alias LemonMemory.{Lifecycle, Project, Safety}
  alias LemonSkills.Audit.State
  alias LemonSkills.{Config, Lockfile}
  alias LemonSkills.Synthesis.DraftStore
  alias LemonSkills.{Usage, WorkspacePreferences}

  @kinds ~w(memory user project skill)
  @max_records 200
  @max_file_bytes 1_048_576

  @doc "Resolve local operator paths without accepting arbitrary assistant homes."
  def for_profile(profile_id \\ "default", opts \\ []) do
    with {:ok, home} <- profile_home(profile_id, opts) do
      list(%{agent_id: profile_id, workspace_dir: home, cwd: home, session_scope: :main}, opts)
    end
  end

  @doc "List newest first, with deterministic ties; at most 100 events (default 50)."
  def list(context, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    kind = Keyword.get(opts, :kind, "all")

    with true <- is_integer(limit) and limit in 1..100,
         true <- kind in ["all" | @kinds],
         {:ok, _identity} <- Project.scope(context),
         {:ok, memory} <- Lifecycle.profile_list(context, "", opts),
         {:ok, workspace} <- workspace_items(context, opts),
         {:ok, skills} <- skill_events(context, opts, memory.items) do
      items =
        (Enum.flat_map(memory.items ++ workspace, &memory_events/1) ++ skills)
        |> Enum.filter(&(kind == "all" or &1["kind"] == kind))
        |> Enum.uniq()
        |> Enum.sort_by(&{-&1["at"], &1["kind"], &1["id"], &1["action"]})
        |> Enum.take(limit)

      {:ok, %{"items" => items, "limit" => limit, "history" => "current_state"}}
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  rescue
    _ -> {:error, :timeline_unavailable}
  catch
    _, _ -> {:error, :timeline_unavailable}
  end

  defp profile_home("default", _opts), do: {:ok, Path.join(Config.agent_dir(), "workspace")}

  defp profile_home(id, opts) do
    with {:ok, paths} <- LemonCore.ProfileStore.paths(id, Keyword.get(opts, :profile_opts, [])),
         do: {:ok, paths["workspace"]}
  end

  defp workspace_items(context, opts) do
    if Keyword.get(opts, :memory_scope, :operator) == :operator,
      do: WorkspacePreferences.list(context.workspace_dir, ""),
      else: {:ok, []}
  end

  defp memory_events(item) do
    kind =
      case item["kind"] do
        "project_learning" -> "project"
        "learned_source" -> "memory"
        value when value in @kinds -> value
        _ -> nil
      end

    if kind do
      timestamps = [{item["createdAtMs"], "added"}]

      timestamps =
        if item["updatedAtMs"] > item["createdAtMs"],
          do: [{item["updatedAtMs"], "updated"} | timestamps],
          else: timestamps

      Enum.flat_map(timestamps, fn {at, action} ->
        event(at, kind, action, item["id"], item["text"])
      end)
    else
      []
    end
  end

  defp skill_events(context, opts, memory_items) do
    # Private/shared memory selectors must not widen into unproven skill state.
    if Keyword.get(opts, :memory_scope, :operator) != :operator do
      {:ok, []}
    else
      home = Path.expand(context.workspace_dir)
      scopes = [{:project, home}]

      scopes =
        if context.agent_id == "default" and
             home == Path.expand(Path.join(Config.agent_dir(), "workspace")),
           do: [:global | scopes],
           else: scopes

      Enum.reduce_while(scopes, {:ok, []}, fn scope, {:ok, acc} ->
        boundary = scope_home(scope)

        with {:ok, usage} <- read_map(Usage.usage_file(usage_opts(scope)), "skills", boundary),
             {:ok, installs} <- read_map(Lockfile.path(scope), "skills", boundary),
             {:ok, audits} <- read_map(State.path(scope), "records", boundary),
             {:ok, drafts} <- draft_events(scope, memory_items) do
          events =
            Enum.flat_map(usage, fn {key, record} ->
              usage_events(key, record, context.agent_id, scope != :global)
            end)

          owned_key? = fn key ->
            scope != :global or
              case Map.get(usage, key) do
                record when is_map(record) ->
                  record["created_by_agent_id"] == context.agent_id or
                    record["last_writer_agent_id"] == context.agent_id

                _ ->
                  false
              end
          end

          installs =
            Enum.flat_map(installs, fn {key, record} ->
              if owned_key?.(key), do: install_events(key, record), else: []
            end)

          draft_ids = MapSet.new(drafts, & &1["id"])

          audits =
            Enum.flat_map(audits, fn {key, record} ->
              allowed? =
                case String.split(key, ":", parts: 2) do
                  ["skill", name] -> owned_key?.(name)
                  ["draft", _] -> scope != :global or MapSet.member?(draft_ids, key)
                  _ -> false
                end

              if allowed?, do: audit_events(key, record), else: []
            end)

          {:cont, {:ok, acc ++ events ++ installs ++ audits ++ drafts}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp scope_home(:global), do: Path.expand(Config.agent_dir())
  defp scope_home({:project, home}), do: home

  defp usage_opts(:global), do: [scope: :global]
  defp usage_opts({:project, home}), do: [scope: :project, cwd: home]
  defp draft_opts(:global), do: [global: true]
  defp draft_opts({:project, home}), do: [global: false, cwd: home]

  defp usage_events(key, record, agent, local?) when is_map(record) do
    created =
      if owner?(record["created_by_agent_id"], agent, local?),
        do: event(record["created_at"], "skill", "created", key, key),
        else: []

    written =
      if owner?(record["last_writer_agent_id"], agent, local?) and
           record["last_write_result"] == "ok",
         do:
           event(record["last_write_at"], "skill", write_action(record["last_action"]), key, key),
         else: []

    state =
      if owner?(record["state_updated_by_agent_id"], agent, local?),
        do:
          event(
            record["state_updated_at"],
            "skill",
            state_action(record["lifecycle_state"]),
            key,
            key
          ),
        else: []

    loaded =
      if record["last_loaded_by_agent_id"] == agent,
        do: event(record["last_loaded_at"], "skill", "loaded", key, key),
        else: []

    created ++ written ++ state ++ loaded
  end

  defp usage_events(_, _, _, _), do: []

  defp owner?(nil, _, local?), do: local?
  defp owner?(agent, agent, _), do: true
  defp owner?(_, _, _), do: false

  defp write_action("create"), do: "created"
  defp write_action("patch"), do: "patched"
  defp write_action("pin"), do: "pinned"
  defp write_action("archive"), do: "archived"
  defp write_action("delete"), do: "deleted"
  defp write_action("unpin"), do: "unpinned"
  defp write_action("restore"), do: "restored"
  defp write_action(_), do: "updated"
  defp state_action(state) when state in ~w(pinned archived stale active), do: state
  defp state_action(_), do: "updated"

  defp install_events(key, record) when is_map(record) do
    event(record["installed_at"], "skill", "installed", key, key) ++
      event(record["updated_at"], "skill", "updated", key, key)
  end

  defp install_events(_, _), do: []

  defp audit_events("skill:" <> key, record) when is_map(record),
    do: event(record["scanned_at"], "skill", "audited", key, key)

  defp audit_events("draft:" <> key, record) when is_map(record),
    do: event(record["scanned_at"], "skill", "audited", "draft:" <> key, key)

  defp audit_events(_, _), do: []

  defp draft_events(scope, memory_items) do
    root = DraftStore.drafts_root(draft_opts(scope))

    case if(safe_path?(root, scope_home(scope)), do: File.ls(root), else: {:error, :unsafe_path}) do
      {:ok, entries} when length(entries) <= @max_records ->
        Enum.reduce_while(Enum.sort(entries), {:ok, []}, fn key, {:ok, acc} ->
          if Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,127}\z/, key) do
            case read_map(Path.join([root, key, ".draft_meta.json"]), nil, scope_home(scope)) do
              {:ok, meta} ->
                source = meta["source_doc_id"]

                owned? =
                  scope != :global or
                    (is_binary(source) and
                       Enum.any?(memory_items, fn item ->
                         String.starts_with?(
                           item["id"],
                           "durable_" <> Base.url_encode64(source, padding: false) <> "."
                         )
                       end))

                events =
                  if owned?,
                    do: event(meta["created_at"], "skill", "drafted", "draft:" <> key, key),
                    else: []

                {:cont, {:ok, acc ++ events}}

              error ->
                {:halt, error}
            end
          else
            {:cont, {:ok, acc}}
          end
        end)

      {:error, :enoent} ->
        {:ok, []}

      _ ->
        {:error, :timeline_unavailable}
    end
  end

  defp read_map(path, field, boundary) do
    result =
      if safe_path?(path, boundary),
        do: File.open(path, [:read, :binary], fn io -> IO.binread(io, @max_file_bytes + 1) end),
        else: {:error, :unsafe_path}

    case result do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= @max_file_bytes ->
        with {:ok, map} when is_map(map) <- Jason.decode(bytes),
             records when is_map(records) <- if(field, do: Map.get(map, field, %{}), else: map),
             true <- map_size(records) <= @max_records do
          {:ok, records}
        else
          _ -> {:error, :timeline_unavailable}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      _ ->
        {:error, :timeline_unavailable}
    end
  end

  defp safe_path?(path, boundary) do
    path = Path.expand(path)
    boundary = Path.expand(boundary)

    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:regular, :directory] ->
        path == boundary or
          (Path.dirname(path) != path and safe_path?(Path.dirname(path), boundary))

      {:error, :enoent} ->
        path == boundary or
          (Path.dirname(path) != path and safe_path?(Path.dirname(path), boundary))

      _ ->
        false
    end
  end

  defp event(at, kind, action, id, text) do
    with at when is_integer(at) and at > 0 <- timestamp(at),
         {:ok, _date} <- DateTime.from_unix(at, :millisecond),
         true <- is_binary(id) and byte_size(id) <= 256 and String.valid?(id),
         true <- String.valid?(text || "") do
      {preview, _} = Safety.redact_for_operator(text, max_bytes: 317)
      {safe_id, _} = Safety.redact_for_operator(id, max_bytes: 256)
      # IDs are management references, never arbitrary text or terminal controls.
      if safe_id == id and
           not Regex.match?(~r/[\s\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}<>]/u, id) do
        preview =
          String.replace(
            preview,
            ~r/[\s\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2066}-\x{2069}]+/u,
            " "
          )

        [
          %{
            "at" => at,
            "kind" => kind,
            "action" => action,
            "id" => id,
            "title" => String.slice(preview, 0, 80),
            "preview" => preview
          }
        ]
      else
        []
      end
    else
      _ -> []
    end
  end

  defp timestamp(value) when is_integer(value), do: value

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> DateTime.to_unix(date, :millisecond)
      _ -> nil
    end
  end

  defp timestamp(_), do: nil
end
