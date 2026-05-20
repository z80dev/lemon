defmodule LemonCore.Browser.Artifacts do
  @moduledoc """
  Metadata helpers for local browser automation artifacts.
  """

  @default_limit 20
  @default_retention_days 14
  @default_max_files 100

  @spec default_dir(String.t()) :: String.t()
  def default_dir(project_dir \\ File.cwd!()) do
    Path.expand(Path.join([project_dir, ".lemon", "browser-artifacts"]))
  end

  @spec recent(keyword()) :: [map()]
  def recent(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()
    limit = opts |> Keyword.get(:limit, @default_limit) |> normalize_limit()

    dir
    |> artifacts()
    |> Enum.sort_by(& &1.modified_at_unix, :desc)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :modified_at_unix))
  end

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()
    artifacts = artifacts(dir)

    %{
      dir: dir,
      exists: File.dir?(dir),
      count: length(artifacts),
      total_bytes: Enum.reduce(artifacts, 0, &(&1.bytes + &2)),
      oldest_modified_at: modified_boundary(artifacts, :oldest),
      newest_modified_at: modified_boundary(artifacts, :newest),
      cleanup: %{
        managed: true,
        policy: cleanup_policy(default_max_age_seconds(), @default_max_files),
        max_age_days: @default_retention_days,
        max_files: @default_max_files,
        safe_to_delete: true,
        embeds_artifact_bytes_in_support_bundle: false
      }
    }
  end

  @spec cleanup(keyword()) :: map()
  def cleanup(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    dir = opts |> Keyword.get(:dir, default_dir(project_dir)) |> Path.expand()

    max_age_seconds =
      opts |> Keyword.get(:max_age_seconds, default_max_age_seconds()) |> normalize_age()

    max_files = opts |> Keyword.get(:max_files, @default_max_files) |> normalize_max_files()
    now = opts |> Keyword.get(:now, System.system_time(:second)) |> normalize_now()

    artifacts = artifacts(dir)
    cutoff = now - max_age_seconds

    by_age =
      artifacts
      |> Enum.filter(&(&1.modified_at_unix < cutoff))
      |> MapSet.new()

    by_count =
      artifacts
      |> Enum.sort_by(& &1.modified_at_unix, :desc)
      |> Enum.drop(max_files)
      |> MapSet.new()

    deleted =
      by_age
      |> MapSet.union(by_count)
      |> Enum.filter(&delete_artifact/1)

    %{
      dir: dir,
      exists: File.dir?(dir),
      deleted_count: length(deleted),
      deleted_bytes: Enum.reduce(deleted, 0, &(&1.bytes + &2)),
      retained_count: length(artifacts) - length(deleted),
      cleanup: %{
        managed: true,
        policy: cleanup_policy(max_age_seconds, max_files),
        max_age_days: div(max_age_seconds, 24 * 60 * 60),
        max_files: max_files,
        safe_to_delete: true,
        embeds_artifact_bytes_in_support_bundle: false
      }
    }
  end

  defp delete_artifact(%{path: path}) do
    case File.rm(path) do
      :ok -> true
      {:error, :enoent} -> true
      {:error, _reason} -> false
    end
  end

  defp artifacts(dir) do
    case File.ls(dir) do
      {:ok, names} -> names |> Enum.map(&artifact_info(dir, &1)) |> Enum.reject(&is_nil/1)
      {:error, _reason} -> []
    end
  end

  defp artifact_info(dir, name) do
    path = Path.join(dir, name)

    with true <- File.regular?(path),
         {:ok, stat} <- File.stat(path, time: :posix) do
      %{
        name: name,
        path: path,
        bytes: stat.size,
        modified_at: DateTime.from_unix!(stat.mtime) |> DateTime.to_iso8601(),
        modified_at_unix: stat.mtime
      }
    else
      _ -> nil
    end
  end

  defp modified_boundary([], _boundary), do: nil

  defp modified_boundary(artifacts, :oldest) do
    artifacts
    |> Enum.min_by(& &1.modified_at_unix)
    |> Map.fetch!(:modified_at)
  end

  defp modified_boundary(artifacts, :newest) do
    artifacts
    |> Enum.max_by(& &1.modified_at_unix)
    |> Map.fetch!(:modified_at)
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(0) |> min(100)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_limit), do: @default_limit

  defp default_max_age_seconds, do: @default_retention_days * 24 * 60 * 60

  defp cleanup_policy(max_age_seconds, max_files) do
    days = div(max_age_seconds, 24 * 60 * 60)
    "managed: #{days}d or #{max_files} files"
  end

  defp normalize_age(age) when is_integer(age), do: max(age, 0)

  defp normalize_age(age) when is_binary(age),
    do: age |> parse_int(default_max_age_seconds()) |> normalize_age()

  defp normalize_age(_age), do: default_max_age_seconds()

  defp normalize_max_files(count) when is_integer(count), do: count |> max(0) |> min(10_000)

  defp normalize_max_files(count) when is_binary(count),
    do: count |> parse_int(@default_max_files) |> normalize_max_files()

  defp normalize_max_files(_count), do: @default_max_files

  defp normalize_now(now) when is_integer(now), do: now
  defp normalize_now(_now), do: System.system_time(:second)

  defp parse_int(value, fallback) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> fallback
    end
  end
end
