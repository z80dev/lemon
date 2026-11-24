defmodule LemonMedia.MediaJobWorker do
  @moduledoc """
  Runs one media job and records redacted lifecycle metadata.
  """

  alias LemonMedia.MediaJobs

  @doc false
  @spec run(keyword()) :: {:ok, map()} | {:error, {:failed, map()}}
  def run(opts) do
    attrs = opts |> Keyword.fetch!(:attrs) |> attrs_map()
    job_opts = Keyword.get(opts, :opts, [])
    record_opts = record_opts(job_opts)
    job_id = Map.fetch!(attrs, :job_id)

    running_attrs =
      attrs
      |> Map.put(:job_id, job_id)
      |> Map.put(:status, :running)

    {:ok, _running_job} = MediaJobs.record(running_attrs, record_opts)

    case run_media_job(Keyword.get(job_opts, :runner), running_attrs) do
      {:ok, updates} ->
        completed_attrs =
          running_attrs
          |> Map.merge(attrs_map(updates))
          |> Map.put(:status, :completed)

        MediaJobs.record(completed_attrs, record_opts)

      {:error, reason} ->
        failed_attrs =
          running_attrs
          |> Map.put(:status, :failed)
          |> Map.put(:error, inspect(reason))
          |> Map.put(:error_kind, error_kind(reason))

        {:ok, failed_job} = MediaJobs.record(failed_attrs, record_opts)
        {:error, {:failed, failed_job}}
    end
  end

  defp run_media_job(runner, attrs) when is_function(runner, 1) do
    case runner.(attrs) do
      {:ok, updates} when is_map(updates) or is_list(updates) -> {:ok, updates}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_runner_result, other}}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp run_media_job(_runner, _attrs), do: {:error, :missing_runner}

  defp record_opts(opts) do
    opts
    |> Keyword.take([:project_dir, :dir, :artifacts_dir])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp attrs_map(attrs) when is_map(attrs), do: attrs
  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(_), do: %{}

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(reason) when is_binary(reason), do: safe_error_label(reason)

  defp error_kind({kind, reason}) when is_atom(kind) do
    error_kind_with_detail(kind, reason)
  end

  defp error_kind({kind, _status, reason}) when is_atom(kind) do
    error_kind_with_detail(kind, reason)
  end

  defp error_kind(reason), do: reason |> inspect() |> safe_error_label()

  defp error_kind_with_detail(kind, reason) do
    kind = Atom.to_string(kind)

    case safe_error_detail(reason) do
      nil -> kind
      detail -> "#{kind}:#{detail}"
    end
  end

  defp safe_error_detail({:safe_error_kind, reason}), do: safe_error_label(reason)
  defp safe_error_detail(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_error_detail(_reason), do: nil

  defp safe_error_label(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 80)
    |> case do
      "" -> nil
      label -> label
    end
  end
end
