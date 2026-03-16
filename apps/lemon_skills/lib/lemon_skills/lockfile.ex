defmodule LemonSkills.Lockfile do
  @moduledoc """
  Reads and writes skill lockfiles that record exact provenance.

  Two lockfiles are maintained:

  - **Global**: `~/.lemon/agent/skills.lock.json` — provenance for globally
    installed skills.
  - **Project**: `<cwd>/.lemon/skills.lock.json` — provenance for
    project-specific installs.

  Each lockfile is a JSON object with a `"version"` integer and a `"skills"`
  map from skill key to a provenance record (see
  `LemonSkills.Entry.to_lockfile_record/1`).

  ## Usage

      # Read the full global lockfile
      {:ok, skills_map} = LemonSkills.Lockfile.read(:global)

      # Fetch a single record
      {:ok, record} = LemonSkills.Lockfile.get(:global, "k8s-rollout")

      # Persist a record
      :ok = LemonSkills.Lockfile.put(:global, Entry.to_lockfile_record(entry))

      # Remove a record
      :ok = LemonSkills.Lockfile.delete(:global, "k8s-rollout")

  ## Lockfile format

      {
        "version": 1,
        "skills": {
          "k8s-rollout": {
            "key": "k8s-rollout",
            "source_kind": "git",
            "source_id": "https://github.com/acme/k8s-rollout",
            "trust_level": "community",
            "content_hash": "abc123...",
            "upstream_hash": "def456...",
            "installed_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:00:00Z",
            "audit_status": "pass",
            "audit_findings": []
          }
        }
      }
  """

  alias LemonSkills.Config

  @lockfile_name "skills.lock.json"
  @current_version 1
  @lock_retries 100
  @lock_sleep_ms 10

  @type scope :: :global | {:project, String.t()}
  @type record :: %{String.t() => term()}
  @type skills_map :: %{String.t() => record()}

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  @doc "Return the lockfile path for the given scope."
  @spec path(scope()) :: String.t()
  def path(:global), do: Path.join(Config.agent_dir(), @lockfile_name)

  def path({:project, cwd}) when is_binary(cwd),
    do: Path.join([cwd, ".lemon", @lockfile_name])

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
    path = path(scope)

    case File.read(path) do
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
  @spec get(scope(), String.t()) :: {:ok, record()} | :not_found
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
  @spec put(scope(), record()) :: :ok | {:error, term()}
  def put(scope, %{"key" => key} = record) when is_binary(key) do
    with_file_lock(scope, fn ->
      with {:ok, skills} <- read(scope) do
        write(scope, Map.put(skills, key, record))
      end
    end)
  end

  @doc """
  Remove a skill's record from the lockfile.

  Returns `:ok` even when the key does not exist.
  """
  @spec delete(scope(), String.t()) :: :ok | {:error, term()}
  def delete(scope, key) when is_binary(key) do
    with_file_lock(scope, fn ->
      with {:ok, skills} <- read(scope) do
        write(scope, Map.delete(skills, key))
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp write(scope, skills) do
    path = path(scope)
    File.mkdir_p!(Path.dirname(path))

    payload = %{"version" => @current_version, "skills" => skills}

    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> File.write(path, json)
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp with_file_lock(scope, fun) do
    lock_path = path(scope) <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))
    acquire_lock(to_charlist(lock_path), fun, @lock_retries)
  end

  defp acquire_lock(_lock_path, _fun, 0), do: {:error, :lock_timeout}

  defp acquire_lock(lock_path, fun, retries) do
    case :file.open(lock_path, [:write, :exclusive]) do
      {:ok, fd} ->
        try do
          fun.()
        after
          :file.close(fd)
          :file.delete(lock_path)
        end

      {:error, :eexist} ->
        Process.sleep(@lock_sleep_ms)
        acquire_lock(lock_path, fun, retries - 1)

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end
end
