defmodule LemonRouter.RunProcess.ArtifactTracker do
  @moduledoc """
  Tracks file-like outputs on router run state.

  This module owns generated-image tracking, explicit file-send requests, and
  completion-time file metadata enrichment. It does not emit channel payloads
  or dispatch directly; channels receive file semantics through answer metadata
  such as `:auto_send_files`.

  Only existing regular files whose real path lies under the run's cwd are
  attachable, plus private delivery copies that a tool registered for this
  run's session in `LemonCore.OutboundCopies` (one-shot provenance; a path
  merely named in tool output or the answer is never trusted that way). A run
  without a cwd (for example a remote-node run whose files live on another
  host) attaches only such registered copies; dropped paths are logged.
  """

  require Logger

  alias LemonCore.MapHelpers

  @logged_dropped_paths 5

  @spec track_generated_images(map(), map()) :: map()
  def track_generated_images(state, action_event) do
    paths = extract_generated_image_paths(action_event)

    if paths == [] do
      state
    else
      Map.put(
        state,
        :generated_image_paths,
        merge_paths(generated_image_paths(state), paths)
      )
    end
  end

  @spec track_requested_send_files(map(), map()) :: map()
  def track_requested_send_files(state, action_event) do
    files = extract_requested_send_files(action_event)

    if files == [] do
      state
    else
      Map.put(
        state,
        :requested_send_files,
        merge_files(requested_send_files(state), files)
      )
    end
  end

  @spec finalize_meta(map()) :: map()
  def finalize_meta(state), do: finalize_meta(state, nil)

  @spec finalize_meta(map(), binary() | nil) :: map()
  def finalize_meta(state, answer) do
    {copies, requested} = take_retained_copies(state)

    files =
      case normalize_root(request_cwd(state)) do
        nil -> drop_rootless_files(requested, generated_image_paths(state), answer)
        root -> finalize_files(state, requested, answer, root)
      end

    case merge_files(copies, files) do
      [] -> %{}
      files -> %{auto_send_files: files}
    end
  end

  defp finalize_files(state, requested, answer, root) do
    merge_files(
      merge_files(
        resolve_explicit_send_files(requested, root),
        resolve_explicit_send_files(media_directive_files(answer), root)
      ),
      resolve_generated_files(generated_image_paths(state), root)
    )
  end

  defp drop_rootless_files(requested, generated, answer) do
    dropped =
      (Enum.map(requested ++ media_directive_files(answer), &file_path/1) ++ generated)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if dropped != [] do
      Logger.warning(
        "Dropping #{length(dropped)} attachment(s) for a run with no working directory: " <>
          inspect(Enum.take(dropped, @logged_dropped_paths))
      )
    end

    []
  end

  # Requested files whose path is a copy registered for this session are
  # delivered as is (the copy holds bytes validated when it was made); the
  # rest go through the cwd containment checks.
  defp take_retained_copies(state) do
    session_key = request_session_key(state)

    {copies, rest} =
      Enum.reduce(requested_send_files(state), {[], []}, fn file, {copies, rest} ->
        case retained_copy(file, session_key) do
          nil -> {copies, [file | rest]}
          copy -> {[copy | copies], rest}
        end
      end)

    {Enum.reverse(copies), Enum.reverse(rest)}
  end

  defp retained_copy(file, session_key) when is_map(file) and is_binary(session_key) do
    path = file_path(file)

    with true <- is_binary(path) and Path.type(path) == :absolute,
         true <- LemonCore.OutboundCopies.take(session_key, path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.dirname(path)) do
      %{
        path: path,
        filename: normalize_filename(MapHelpers.get_key(file, :filename), path),
        caption: normalize_caption(MapHelpers.get_key(file, :caption)),
        source: normalize_source(MapHelpers.get_key(file, :source)) || :explicit
      }
      |> maybe_put(:mime_type, normalize_mime_type(MapHelpers.get_key(file, :mime_type)))
    else
      _ -> nil
    end
  end

  defp retained_copy(_file, _session_key), do: nil

  defp file_path(file) when is_map(file), do: MapHelpers.get_key(file, :path)
  defp file_path(_file), do: nil

  @spec strip_media_directives(term()) :: term()
  def strip_media_directives(answer) when is_binary(answer) do
    answer
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.reject(&media_directive_line?/1)
    |> Enum.join("\n")
    |> String.trim_trailing()
  end

  def strip_media_directives(answer), do: answer

  defp extract_generated_image_paths(action_event) do
    action = MapHelpers.get_key(action_event, :action) || %{}
    kind = MapHelpers.get_key(action, :kind)
    phase = MapHelpers.get_key(action_event, :phase)
    ok = MapHelpers.get_key(action_event, :ok)

    cond do
      not file_change_kind?(kind) ->
        []

      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        action
        |> MapHelpers.get_key(:detail)
        |> MapHelpers.get_key(:changes)
        |> case do
          changes when is_list(changes) ->
            Enum.flat_map(changes, fn change ->
              case extract_image_change_path(change) do
                nil -> []
                path -> [path]
              end
            end)

          _ ->
            []
        end
    end
  end

  defp extract_image_change_path(change) when is_map(change) do
    path = MapHelpers.get_key(change, :path)
    kind = MapHelpers.get_key(change, :kind)

    cond do
      not is_binary(path) or path == "" ->
        nil

      deleted_change_kind?(kind) ->
        nil

      not LemonCore.MediaFiles.image_path?(path) ->
        nil

      true ->
        path
    end
  end

  defp extract_image_change_path(_), do: nil

  defp extract_requested_send_files(action_event) do
    action = MapHelpers.get_key(action_event, :action) || %{}
    phase = MapHelpers.get_key(action_event, :phase)
    ok = MapHelpers.get_key(action_event, :ok)

    cond do
      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        action
        |> MapHelpers.get_key(:detail)
        |> MapHelpers.get_key(:result_meta)
        |> MapHelpers.get_key(:auto_send_files)
        |> case do
          files when is_list(files) ->
            files
            |> Enum.map(&normalize_requested_send_file/1)
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
    end
  end

  defp normalize_requested_send_file(file) when is_map(file) do
    path = MapHelpers.get_key(file, :path)
    filename = MapHelpers.get_key(file, :filename)
    caption = MapHelpers.get_key(file, :caption)
    source = normalize_source(MapHelpers.get_key(file, :source))
    mime_type = MapHelpers.get_key(file, :mime_type)

    if is_binary(path) and path != "" do
      base = %{
        path: path,
        filename: normalize_filename(filename, path),
        caption: normalize_caption(caption)
      }

      base
      |> maybe_put(:source, source)
      |> maybe_put(:mime_type, normalize_mime_type(mime_type))
    end
  end

  defp normalize_requested_send_file(_), do: nil

  defp media_directive_files(answer) when is_binary(answer) do
    answer
    |> String.split(["\r\n", "\n", "\r"])
    |> Enum.map(&media_directive_file/1)
    |> Enum.reject(&is_nil/1)
  end

  defp media_directive_files(_), do: []

  defp media_directive_file(line) when is_binary(line) do
    case media_directive_path(line) do
      path when is_binary(path) and path != "" -> %{path: path, source: :explicit}
      _ -> nil
    end
  end

  defp media_directive_file(_), do: nil

  defp media_directive_line?(line) when is_binary(line), do: is_binary(media_directive_path(line))
  defp media_directive_line?(_), do: false

  defp media_directive_path(line) when is_binary(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "MEDIA:") do
      trimmed
      |> String.replace_prefix("MEDIA:", "")
      |> String.trim()
      |> unwrap_media_path()
    end
  end

  defp unwrap_media_path(path) do
    path
    |> unwrap_media_path("`")
    |> unwrap_media_path("\"")
    |> unwrap_media_path("'")
  end

  defp unwrap_media_path(path, wrapper) do
    if String.starts_with?(path, wrapper) and String.ends_with?(path, wrapper) do
      path
      |> String.trim_leading(wrapper)
      |> String.trim_trailing(wrapper)
    else
      path
    end
  end

  defp resolve_generated_files(paths, root) when is_list(paths) do
    paths
    |> Enum.map(&resolve_generated_path(&1, root))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case existing_file(path, root) do
        {:ok, file} -> [Map.put(file, :source, :generated)]
        :error -> []
      end
    end)
  end

  defp resolve_explicit_send_files(files, root) when is_list(files) do
    files
    |> Enum.map(&resolve_explicit_send_file(&1, root))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_explicit_send_files(_, _), do: []

  defp resolve_explicit_send_file(file, root) when is_map(file) do
    path = MapHelpers.get_key(file, :path)
    filename = MapHelpers.get_key(file, :filename)
    caption = MapHelpers.get_key(file, :caption)
    source = normalize_source(MapHelpers.get_key(file, :source)) || :explicit
    mime_type = MapHelpers.get_key(file, :mime_type)

    with path when is_binary(path) and path != "" <- path,
         resolved when is_binary(resolved) <- resolve_generated_path(path, root),
         {:ok, %{path: valid_path}} <- existing_file(resolved, root) do
      %{
        path: valid_path,
        filename: normalize_filename(filename, valid_path),
        caption: normalize_caption(caption),
        source: source
      }
      |> maybe_put(:mime_type, normalize_mime_type(mime_type))
    else
      _ -> nil
    end
  end

  defp resolve_explicit_send_file(_, _), do: nil

  defp resolve_generated_path(path, _cwd) when not is_binary(path), do: nil

  defp resolve_generated_path(path, cwd) when is_binary(cwd) and cwd != "" do
    root = Path.expand(cwd)

    absolute =
      if Path.type(path) == :absolute do
        Path.expand(path)
      else
        Path.expand(path, root)
      end

    if path_within_root?(absolute, root), do: absolute
  end

  defp resolve_generated_path(_path, _cwd), do: nil

  defp request_cwd(%{execution_request: %LemonCore.ExecutionCommand{cwd: cwd}})
       when is_binary(cwd) and cwd != "",
       do: cwd

  defp request_cwd(%{execution_request: %{cwd: cwd}}) when is_binary(cwd) and cwd != "", do: cwd

  defp request_cwd(_), do: nil

  defp request_session_key(%{execution_request: %{session_key: key}})
       when is_binary(key) and key != "",
       do: key

  defp request_session_key(_), do: nil

  defp existing_file(path, root) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, real_path} <- real_path(path),
         true <- path_within_root?(real_path, root) do
      {:ok, %{path: real_path, filename: Path.basename(real_path), caption: nil}}
    else
      _ -> :error
    end
  end

  defp existing_file(_, _), do: :error

  defp merge_paths(existing, new_paths), do: Enum.uniq(existing ++ new_paths)

  defp merge_files(first, second) when is_list(first) and is_list(second) do
    {merged, _seen} =
      Enum.reduce(first ++ second, {[], MapSet.new()}, fn file, {acc, seen} ->
        key = {Map.get(file, :path), Map.get(file, :filename), Map.get(file, :caption)}

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[file | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(merged)
  end

  defp merge_files(first, second) when is_list(first), do: first ++ List.wrap(second)
  defp merge_files(_first, second) when is_list(second), do: second
  defp merge_files(_, _), do: []

  defp normalize_filename(filename, _path) when is_binary(filename) and filename != "",
    do: filename

  defp normalize_filename(_filename, path), do: Path.basename(path)

  defp normalize_caption(caption) when is_binary(caption) and caption != "", do: caption
  defp normalize_caption(_), do: nil

  defp normalize_source(source) when source in [:explicit, :generated], do: source
  defp normalize_source("explicit"), do: :explicit
  defp normalize_source("generated"), do: :generated
  defp normalize_source(_source), do: nil

  defp normalize_mime_type(mime_type) when is_binary(mime_type) and mime_type != "",
    do: mime_type

  defp normalize_mime_type(_mime_type), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generated_image_paths(state) when is_map(state) do
    case Map.get(state, :generated_image_paths) do
      paths when is_list(paths) -> paths
      _ -> []
    end
  end

  defp generated_image_paths(_), do: []

  defp requested_send_files(state) when is_map(state) do
    case Map.get(state, :requested_send_files) do
      files when is_list(files) -> files
      _ -> []
    end
  end

  defp requested_send_files(_), do: []

  defp normalize_root(root) when is_binary(root) and root != "" do
    case real_path(root) do
      {:ok, path} -> path
      :error -> Path.expand(root)
    end
  end

  defp normalize_root(_), do: nil

  defp path_within_root?(absolute, root) when is_binary(absolute) and is_binary(root) do
    rel = Path.relative_to(absolute, root)
    Path.type(rel) != :absolute and (rel == "." or not String.starts_with?(rel, ".."))
  end

  defp path_within_root?(_, _), do: false

  # Symlink hops before giving up, matching the usual POSIX MAXSYMLINKS bound.
  @max_symlink_hops 40

  defp real_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> resolve_absolute_path(0)
  end

  defp resolve_absolute_path(_path, hops) when hops > @max_symlink_hops, do: :error

  defp resolve_absolute_path(path, hops) when is_binary(path) do
    case Path.split(path) do
      [root | segments] -> resolve_absolute_segments(root, segments, hops)
      _ -> :error
    end
  end

  defp resolve_absolute_segments(current, [], _hops), do: {:ok, current}

  defp resolve_absolute_segments(current, [segment | rest], hops) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        case File.read_link(next) do
          {:ok, target} ->
            target_path =
              if Path.type(target) == :absolute do
                Path.expand(target)
              else
                Path.expand(target, Path.dirname(next))
              end

            combined =
              case rest do
                [] -> target_path
                _ -> Path.join([target_path | rest])
              end

            resolve_absolute_path(combined, hops + 1)

          _ ->
            :error
        end

      {:ok, _stat} ->
        resolve_absolute_segments(next, rest, hops)

      _ ->
        :error
    end
  end

  defp file_change_kind?(kind) when kind in [:file_change, "file_change"], do: true
  defp file_change_kind?(_), do: false

  defp phase_completed?(phase) when phase in [:completed, "completed"], do: true
  defp phase_completed?(_), do: false

  defp deleted_change_kind?(kind) when kind in [:deleted, "deleted", :remove, "remove"], do: true
  defp deleted_change_kind?(_), do: false
end
