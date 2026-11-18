defmodule LemonSkills.Lockfile do
  @moduledoc false

  # Reads and writes skill lockfiles that record exact provenance.
  #
  # Two lockfiles are maintained:
  #
  # - **Global**: `~/.lemon/agent/skills.lock.json` — provenance for globally
  #   installed skills.
  # - **Project**: `<cwd>/.lemon/skills.lock.json` — provenance for
  #   project-specific installs.
  #
  # Lockfile provenance is descriptive. A project lockfile is repository
  # content: it never authorizes loading or skips an audit (authorizations are
  # operator-side, see `LemonSkills.Audit.State`). Reads and writes are
  # contained by `LemonSkills.MetadataFile`: the project directory or the
  # agent directory is the trusted anchor, symlinked components and
  # non-regular or hard-linked lockfiles are refused, and writes replace the
  # file atomically (0600) without following the destination.
  #
  # Each lockfile is a JSON object with a `"version"` integer and a `"skills"`
  # map from skill key to a provenance record (see
  # `LemonSkills.Entry.to_lockfile_record/1`).
  #
  # Usage
  #
  #     # Read the full global lockfile
  #     {:ok, skills_map} = LemonSkills.Lockfile.read(:global)
  #
  #     # Fetch a single record
  #     {:ok, record} = LemonSkills.Lockfile.get(:global, "k8s-rollout")
  #
  #     # Persist a record
  #     :ok = LemonSkills.Lockfile.put(:global, Entry.to_lockfile_record(entry))
  #
  #     # Remove a record
  #     :ok = LemonSkills.Lockfile.delete(:global, "k8s-rollout")
  #
  # Lockfile format
  #
  #     {
  #       "version": 1,
  #       "skills": {
  #         "k8s-rollout": {
  #           "key": "k8s-rollout",
  #           "source_kind": "git",
  #           "source_id": "https://github.com/acme/k8s-rollout",
  #           "trust_level": "community",
  #           "content_hash": "abc123...",
  #           "upstream_hash": "def456...",
  #           "installed_at": "2026-01-01T00:00:00Z",
  #           "updated_at": "2026-01-01T00:00:00Z",
  #           "audit_status": "pass",
  #           "audit_findings": []
  #         }
  #       }
  #     }

  alias LemonSkills.{Config, MetadataFile, SkillRoot}

  @lockfile_name "skills.lock.json"
  @current_version 1

  @type scope :: :global | {:project, String.t()} | {:agent_dir, String.t()}
  @type skill_record :: %{String.t() => term()}
  @type skills_map :: %{String.t() => skill_record()}

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  @doc "Return the lockfile path for the given scope."
  @spec path(scope()) :: String.t()
  def path(:global), do: Path.join(Config.agent_dir(), @lockfile_name)

  def path({:project, cwd}) when is_binary(cwd),
    do: Path.join([cwd, ".lemon", @lockfile_name])

  # An explicit agent directory, for offline imports into a target other than
  # the configured one (e.g. `lemon migrate hermes --target`).
  def path({:agent_dir, dir}) when is_binary(dir), do: Path.join(dir, @lockfile_name)

  # ---------------------------------------------------------------------------
  # Read
  # ---------------------------------------------------------------------------

  @doc """
  Read the lockfile for the given scope.

  Returns `{:ok, skills_map}` where `skills_map` maps skill keys to lockfile
  records, or `{:ok, %{}}` when no lockfile exists yet.
  """
  @spec read(scope()) :: {:ok, skills_map()} | {:error, term()}
  def read(scope) do
    case MetadataFile.read(read_anchor(scope), path(scope)) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"skills" => skills}} when is_map(skills) ->
            {:ok, skills}

          {:ok, _} ->
            {:ok, %{}}

          {:error, reason} ->
            {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Single-record helpers
  # ---------------------------------------------------------------------------

  @doc """
  Get a single skill's provenance record from the lockfile.

  Returns `{:ok, record}` or `:not_found`.
  """
  @spec get(scope(), String.t()) :: {:ok, skill_record()} | :not_found
  def get(scope, key) when is_binary(key) do
    case read(scope) do
      {:ok, skills} ->
        case Map.fetch(skills, key) do
          {:ok, record} -> {:ok, record}
          :error -> :not_found
        end

      {:error, _} ->
        :not_found
    end
  end

  @doc """
  Write or update a skill's provenance record in the lockfile.

  `record` must include a `"key"` string field (as returned by
  `LemonSkills.Entry.to_lockfile_record/1`).
  """
  @spec put(scope(), skill_record()) :: :ok | {:error, term()}
  def put(scope, %{"key" => key} = record) when is_binary(key) do
    with_file_lock(scope, fn anchor ->
      with {:ok, skills} <- read(scope) do
        write(anchor, scope, Map.put(skills, key, record))
      end
    end)
  end

  @doc """
  Remove a skill's record from the lockfile.

  Returns `:ok` even when the key does not exist.
  """
  @spec delete(scope(), String.t()) :: :ok | {:error, term()}
  def delete(scope, key) when is_binary(key) do
    with_file_lock(scope, fn anchor ->
      with {:ok, skills} <- read(scope) do
        write(anchor, scope, Map.delete(skills, key))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp write(anchor, scope, skills) do
    payload = %{"version" => @current_version, "skills" => skills}

    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> MetadataFile.write(anchor, path(scope), json)
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp with_file_lock(scope, fun) do
    with {:ok, anchor} <- write_anchor(scope) do
      MetadataFile.with_lock(anchor, path(scope), fn -> fun.(anchor) end)
    end
  end

  defp read_anchor(:global), do: Path.expand(Config.agent_dir())
  defp read_anchor({:project, cwd}), do: Path.expand(cwd)
  defp read_anchor({:agent_dir, dir}), do: Path.expand(dir)

  # Agent directories are validated as independently trusted before a write;
  # the project directory is the anchor of its own `.lemon/` metadata.
  defp write_anchor(:global), do: SkillRoot.trusted_dir(Config.agent_dir())
  defp write_anchor({:project, cwd}), do: {:ok, Path.expand(cwd)}
  defp write_anchor({:agent_dir, dir}), do: SkillRoot.trusted_dir(dir)
end
