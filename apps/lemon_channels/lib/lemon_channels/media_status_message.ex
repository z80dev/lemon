defmodule LemonChannels.MediaStatusMessage do
  @moduledoc false

  alias LemonMedia.MediaJobs

  @spec handle(binary() | nil, keyword()) :: String.t()
  def handle(args, opts \\ [])

  def handle(args, opts) when args in [nil, ""] do
    text(opts)
  end

  def handle(args, opts) when is_binary(args) do
    case String.split(args, ~r/\s+/, trim: true) do
      [] ->
        text(opts)

      ["status" | _] ->
        text(opts)

      _ ->
        "Usage: /media status"
    end
  end

  @spec text(keyword()) :: String.t()
  def text(opts \\ []) do
    summary = MediaJobs.summary(opts)
    recent = MediaJobs.recent(Keyword.put(opts, :limit, Keyword.get(opts, :limit, 5)))
    cleanup = Map.get(summary, :cleanup, %{})

    [
      "Media Status",
      "Jobs: #{Map.get(summary, :count, 0)}",
      "Artifacts: #{Map.get(summary, :artifact_count, 0)} (#{format_bytes(Map.get(summary, :artifact_total_bytes, 0))})",
      "Types: #{counts_line(Map.get(summary, :type_counts, %{}))}",
      "Statuses: #{counts_line(Map.get(summary, :status_counts, %{}))}",
      "Newest: #{Map.get(summary, :newest_created_at) || "none"}",
      "Recent: #{recent_line(recent)}",
      "Cleanup: #{cleanup_line(cleanup)}",
      "Redaction: prompts, artifact paths, bytes, provider responses, and chat content are omitted."
    ]
    |> Enum.join("\n")
  end

  defp recent_line([]), do: "none"

  defp recent_line(recent) do
    recent
    |> Enum.take(5)
    |> Enum.map(fn job ->
      [
        job_value(job, :job_id),
        job_value(job, :type),
        job_value(job, :status),
        artifact_summary(job)
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    end)
    |> Enum.join(", ")
  end

  defp artifact_summary(job) do
    artifact = job_value(job, :artifact) || %{}
    name = job_value(artifact, :name)
    bytes = job_value(artifact, :bytes)

    cond do
      name && is_integer(bytes) -> "#{name} (#{format_bytes(bytes)})"
      name -> name
      is_integer(bytes) -> format_bytes(bytes)
      true -> nil
    end
  end

  defp cleanup_line(cleanup) when is_map(cleanup) do
    days = job_value(cleanup, :max_age_days)
    max_jobs = job_value(cleanup, :max_jobs)
    max_artifacts = job_value(cleanup, :max_artifacts)

    [
      days && "#{days}d",
      max_jobs && "#{max_jobs} jobs",
      max_artifacts && "#{max_artifacts} artifacts"
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "default"
      parts -> Enum.join(parts, ", ")
    end
  end

  defp cleanup_line(_), do: "default"

  defp counts_line(counts) when is_map(counts) and map_size(counts) > 0 do
    counts
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> "#{key} #{value}" end)
    |> Enum.join(", ")
  end

  defp counts_line(_), do: "none"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp format_bytes(_), do: "0 B"

  defp job_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp job_value(_, _), do: nil

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
