defmodule LemonSkills.Audit.State do
  @moduledoc false

  # Persists bundle-audit results separately from install provenance lockfiles.

  alias LemonSkills.Config

  @state_filename "skills.audit.json"
  @current_version 1

  @type scope :: :global | {:project, String.t()}
  @type entity_kind :: :skill | :draft

  @spec path(scope()) :: String.t()
  def path(:global), do: Path.join(Config.agent_dir(), @state_filename)
  def path({:project, cwd}) when is_binary(cwd), do: Path.join([cwd, ".lemon", @state_filename])

  @spec read(scope()) :: {:ok, map()} | {:error, term()}
  def read(scope) do
    case File.read(path(scope)) do
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
    with_file_lock(scope, fn ->
      with {:ok, records} <- read(scope) do
        write(scope, Map.put(records, record_key(kind, key), record))
      end
    end)
  end

  @spec delete(scope(), entity_kind(), String.t()) :: :ok | {:error, term()}
  def delete(scope, kind, key) when is_binary(key) do
    with_file_lock(scope, fn ->
      with {:ok, records} <- read(scope) do
        write(scope, Map.delete(records, record_key(kind, key)))
      end
    end)
  end

  defp record_key(kind, key), do: "#{kind}:#{key}"

  defp write(scope, records) do
    state_path = path(scope)
    File.mkdir_p!(Path.dirname(state_path))

    payload = %{"version" => @current_version, "records" => records}

    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> File.write(state_path, json)
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp with_file_lock(scope, fun) do
    lock_path = path(scope) <> ".lock"
    File.mkdir_p!(Path.dirname(lock_path))
    LemonCore.Service.Lock.with_lock_path(lock_path, [timeout: 1_000], fun)
  end
end
