defmodule LemonSkills.Audit.State do
  @moduledoc false

  # Operator-side bundle-audit results and load authorizations, kept apart
  # from install provenance lockfiles.
  #
  # Every record lives under the agent directory, never in repository content:
  #
  # - global: `<agent_dir>/skills.audit.json`
  # - project: `<agent_dir>/skill_audits/project-<sha256(project realpath)>.json`
  #
  # A repository's own `.lemon/skills.audit.json` is never read, so a project
  # cannot supply a cached verdict. Files are read and replaced through
  # `LemonSkills.MetadataFile` (contained, regular, atomic, 0600).
  #
  # Besides the last audit record per entity (`"<kind>:<key>"`), a skill keeps
  # its load authorizations (`"authorization:<key>"`): the exact bundle hashes
  # that passed a trusted audit or that an operator approved (`warn`) or
  # overrode (`overridden`). Loading requires a grant for the live bundle hash.

  alias LemonSkills.{Config, MetadataFile, SkillRoot}

  @state_filename "skills.audit.json"
  @project_dir "skill_audits"
  @current_version 2
  @max_grants 16
  @grant_statuses ~w(pass warn overridden)

  @type scope :: :global | {:project, String.t()}
  @type entity_kind :: :skill | :draft
  @type grant_status :: :pass | :warn | :overridden

  @spec path(scope()) :: String.t()
  def path(:global), do: Path.join(Config.agent_dir(), @state_filename)

  def path({:project, cwd}) when is_binary(cwd),
    do: Path.join([Config.agent_dir(), @project_dir, "project-#{project_id(cwd)}.json"])

  @spec read(scope()) :: {:ok, map()} | {:error, term()}
  def read(scope) do
    case MetadataFile.read(Path.expand(Config.agent_dir()), path(scope)) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"records" => records}} when is_map(records) -> {:ok, records}
          {:ok, _} -> {:ok, %{}}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get(scope(), entity_kind(), String.t()) :: {:ok, map()} | :not_found
  def get(scope, kind, key) when is_binary(key) do
    case read(scope) do
      {:ok, records} ->
        case Map.fetch(records, record_key(kind, key)) do
          {:ok, record} -> {:ok, record}
          :error -> :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  @spec put(scope(), entity_kind(), String.t(), map()) :: :ok | {:error, term()}
  def put(scope, kind, key, record) when is_binary(key) and is_map(record) do
    update(scope, &Map.put(&1, record_key(kind, key), record))
  end

  @doc false
  # Deleting a skill's audit state also revokes its load authorizations.
  @spec delete(scope(), entity_kind(), String.t()) :: :ok | {:error, term()}
  def delete(scope, kind, key) when is_binary(key) do
    update(scope, fn records ->
      records = Map.delete(records, record_key(kind, key))
      if kind == :skill, do: Map.delete(records, grant_key(key)), else: records
    end)
  end

  @doc """
  Atomically stores an audit `record` (unless `store: false`, for a verdict
  served from cache) and, for a skill, reconciles its grants with the verdict
  for exactly `record["bundle_hash"]`: `pass` grants that hash, while an
  adverse verdict (`warn` without approval, `block`) revokes every earlier
  grant for it, so a new approval or override must postdate it.
  """
  @spec record_audit(scope(), entity_kind(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def record_audit(scope, kind, key, record, opts \\ [])
      when is_binary(key) and is_map(record) and is_list(opts) do
    update(scope, fn records ->
      records =
        if Keyword.get(opts, :store, true),
          do: Map.put(records, record_key(kind, key), record),
          else: records

      reconcile(records, kind, key, record)
    end)
  end

  defp reconcile(records, :skill, key, %{"bundle_hash" => hash, "final_verdict" => verdict})
       when is_binary(hash) and hash != "" do
    case verdict do
      "pass" -> put_grant(records, key, hash, :pass)
      _adverse -> drop_grant(records, key, hash)
    end
  end

  defp reconcile(records, _kind, _key, _record), do: records

  @doc """
  Records that the skill `key` may be loaded while its live bundle hash is
  exactly `bundle_hash`: `:pass` for a trusted audit pass, `:warn` for an
  operator-approved warning, `:overridden` for an exact-bundle block override.

  The grant must cover the latest audit verdict recorded for that exact hash:
  after a `block` only `:overridden` is accepted, after a `warn` only `:warn`
  or `:overridden`; anything weaker is `{:error, :superseded_by_verdict}`.
  """
  @spec authorize(scope(), String.t(), String.t(), grant_status()) :: :ok | {:error, term()}
  def authorize(scope, key, bundle_hash, status)
      when is_binary(key) and is_binary(bundle_hash) and bundle_hash != "" and
             status in [:pass, :warn, :overridden] do
    update(scope, fn records ->
      if status in allowed_grants(records, key, bundle_hash),
        do: put_grant(records, key, bundle_hash, status),
        else: {:error, :superseded_by_verdict}
    end)
  end

  def authorize(_scope, _key, _bundle_hash, _status), do: {:error, :not_authorizable}

  @doc """
  Drops the grant of skill `key` for exactly `bundle_hash` (a no-op when there
  is none); other grants and the audit record are kept.
  """
  @spec revoke(scope(), String.t(), String.t()) :: :ok | {:error, term()}
  def revoke(scope, key, bundle_hash) when is_binary(key) and is_binary(bundle_hash) do
    update(scope, &drop_grant(&1, key, bundle_hash))
  end

  defp allowed_grants(records, key, bundle_hash) do
    case Map.get(records, record_key(:skill, key)) do
      %{"bundle_hash" => ^bundle_hash, "final_verdict" => "block"} -> [:overridden]
      %{"bundle_hash" => ^bundle_hash, "final_verdict" => "warn"} -> [:warn, :overridden]
      _ -> [:pass, :warn, :overridden]
    end
  end

  defp put_grant(records, key, bundle_hash, status) do
    grant = %{
      "bundle_hash" => bundle_hash,
      "status" => Atom.to_string(status),
      "authorized_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    previous = records |> grants(key) |> Enum.reject(&(&1["bundle_hash"] == bundle_hash))
    Map.put(records, grant_key(key), %{"grants" => Enum.take([grant | previous], @max_grants)})
  end

  defp drop_grant(records, key, bundle_hash) do
    case grants(records, key) do
      [] ->
        records

      grants ->
        kept = Enum.reject(grants, &(&1["bundle_hash"] == bundle_hash))
        Map.put(records, grant_key(key), %{"grants" => kept})
    end
  end

  @doc """
  Returns the authorization status recorded in `records` (from `read/1`) for
  skill `key` at exactly `bundle_hash`, or `nil`. A grant weaker than the
  latest verdict recorded for that hash (a pass or warning approval under a
  `block`, a pass under a `warn`) never counts.
  """
  @spec grant_status(map(), String.t(), String.t() | nil) :: grant_status() | nil
  def grant_status(records, key, bundle_hash) when is_binary(bundle_hash) do
    allowed = allowed_grants(records, key, bundle_hash)

    Enum.find_value(grants(records, key), fn
      %{"bundle_hash" => ^bundle_hash, "status" => status} when status in @grant_statuses ->
        status = String.to_existing_atom(status)
        if status in allowed, do: status

      _ ->
        nil
    end)
  end

  def grant_status(_records, _key, _bundle_hash), do: nil

  defp grants(records, key) do
    case Map.get(records, grant_key(key)) do
      %{"grants" => grants} when is_list(grants) -> Enum.filter(grants, &is_map/1)
      _ -> []
    end
  end

  defp record_key(kind, key), do: "#{kind}:#{key}"
  defp grant_key(key), do: "authorization:#{key}"

  # `fun` returns the new records map, or `{:error, reason}` to abort unchanged.
  defp update(scope, fun) do
    with {:ok, anchor} <- SkillRoot.trusted_dir(Config.agent_dir()) do
      state_path = path(scope)

      MetadataFile.with_lock(anchor, state_path, fn ->
        with {:ok, records} <- read(scope),
             updated when is_map(updated) <- fun.(records),
             {:ok, json} <- encode(scope, updated) do
          MetadataFile.write(anchor, state_path, json)
        end
      end)
    end
  end

  defp encode(scope, records) do
    payload =
      %{"version" => @current_version, "records" => records}
      |> put_project(scope)

    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp put_project(payload, {:project, cwd}), do: Map.put(payload, "project", real_project(cwd))
  defp put_project(payload, :global), do: payload

  # Project state is keyed by the project's real path, so every spelling of
  # the same directory (symlinked or relative) shares one record file.
  defp project_id(cwd) do
    :crypto.hash(:sha256, real_project(cwd)) |> Base.encode16(case: :lower)
  end

  defp real_project(cwd) do
    case SkillRoot.realpath(cwd) do
      {:ok, real} -> real
      {:error, _} -> Path.expand(cwd)
    end
  end
end
