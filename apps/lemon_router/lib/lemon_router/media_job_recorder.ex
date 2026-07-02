defmodule LemonRouter.MediaJobRecorder do
  @moduledoc """
  Records generated final-answer files into the redacted media job store.
  """

  alias LemonCore.MapHelpers

  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))
  @audio_extensions MapSet.new(~w(.mp3 .wav .ogg .flac .m4a .aac .opus))
  @video_extensions MapSet.new(~w(.mp4 .mov .webm .mkv .avi))

  @spec record_auto_send_files(map(), map(), keyword()) :: map()
  def record_auto_send_files(extra_meta, state, opts \\ []) do
    files = MapHelpers.get_key(extra_meta || %{}, :auto_send_files)

    if is_list(files) do
      files
      |> Enum.map(&record_file(&1, state, opts))
      |> summarize_results()
    else
      %{recorded_count: 0, skipped_count: 0, failed_count: 0}
    end
  end

  defp record_file(file, state, opts) when is_map(file) do
    source = MapHelpers.get_key(file, :source)
    path = MapHelpers.get_key(file, :path)

    cond do
      source not in [:generated, "generated"] ->
        :skipped

      not is_binary(path) or path == "" ->
        :skipped

      not File.regular?(path) ->
        :skipped

      true ->
        attrs = %{
          job_id: job_id(state, path),
          type: media_type(path, MapHelpers.get_key(file, :mime_type)),
          status: :completed,
          channel: channel_id(state),
          artifact_path: path,
          artifact_name: MapHelpers.get_key(file, :filename),
          mime_type: MapHelpers.get_key(file, :mime_type),
          created_at: Keyword.get(opts, :created_at)
        }

        record_opts =
          []
          |> maybe_put(:project_dir, Keyword.get(opts, :project_dir) || request_cwd(state))
          |> maybe_put(:dir, Keyword.get(opts, :dir))

        case LemonMedia.MediaJobs.record(attrs, record_opts) do
          {:ok, _job} -> :recorded
          {:error, _reason} -> :failed
        end
    end
  rescue
    _ -> :failed
  end

  defp record_file(_file, _state, _opts), do: :skipped

  defp summarize_results(results) do
    %{
      recorded_count: Enum.count(results, &(&1 == :recorded)),
      skipped_count: Enum.count(results, &(&1 == :skipped)),
      failed_count: Enum.count(results, &(&1 == :failed))
    }
  end

  defp job_id(state, path) do
    run_id = Map.get(state, :run_id) || "run"

    digest =
      :crypto.hash(:sha256, "#{run_id}:#{path}")
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    "media_#{run_id}_#{digest}"
  end

  defp media_type(_path, mime_type) when is_binary(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> :image
      String.starts_with?(mime_type, "audio/") -> :audio
      String.starts_with?(mime_type, "video/") -> :video
      true -> :media
    end
  end

  defp media_type(path, _mime_type) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      MapSet.member?(@image_extensions, ext) -> :image
      MapSet.member?(@audio_extensions, ext) -> :audio
      MapSet.member?(@video_extensions, ext) -> :video
      true -> :media
    end
  end

  defp request_cwd(%{execution_request: %LemonCore.ExecutionCommand{cwd: cwd}})
       when is_binary(cwd) and cwd != "",
       do: cwd

  defp request_cwd(%{execution_request: %{cwd: cwd}}) when is_binary(cwd) and cwd != "", do: cwd
  defp request_cwd(_state), do: File.cwd!()

  defp channel_id(%{execution_request: request}) do
    route = MapHelpers.get_key(request, :route) || %{}
    MapHelpers.get_key(route, :channel_id) || MapHelpers.get_key(route, :platform)
  end

  defp channel_id(_state), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
