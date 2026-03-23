defmodule LemonRouter.RunProcess.ArtifactTracker do
  @moduledoc """
  Tracks file-like outputs on router run state.

  This module owns generated-image tracking, explicit file-send requests, and
  completion-time file metadata enrichment. It does not emit channel payloads
  or dispatch directly; channels receive file semantics through answer metadata
  such as `:auto_send_files`.
  """

  alias LemonCore.MapHelpers

  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))

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
  def finalize_meta(state) do
    cwd = request_cwd(state)
    root = normalize_root(cwd)

    files =
      merge_files(
        resolve_explicit_send_files(requested_send_files(state), root),
        resolve_generated_files(generated_image_paths(state), root)
      )

    if files == [] do
      %{}
    else
      %{auto_send_files: files}
    end
  end

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

      not image_path?(path) ->
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

    if is_binary(path) and path != "" do
      %{
        path: path,
        filename: normalize_filename(filename, path),
        caption: normalize_caption(caption)
      }
    end
  end

  defp normalize_requested_send_file(_), do: nil

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

  defp resolve_generated_files(_, _), do: []

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

    with path when is_binary(path) and path != "" <- path,
         resolved when is_binary(resolved) <- resolve_explicit_path(path, root),
         {:ok, %{path: valid_path}} <- existing_file(resolved, root) do
      %{
        path: valid_path,
        filename: normalize_filename(filename, valid_path),
        caption: normalize_caption(caption),
        source: :explicit
      }
    else
      _ -> nil
    end
  end

  defp resolve_explicit_send_file(_, _), do: nil

  defp resolve_explicit_path(path, root) when is_binary(root) and root != "" do
    resolve_generated_path(path, root)
  end

  defp resolve_explicit_path(path, _cwd) do
    if is_binary(path) and Path.type(path) == :absolute, do: Path.expand(path)
  end

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

  defp request_cwd(%{execution_request: %LemonGateway.ExecutionRequest{cwd: cwd}})
       when is_binary(cwd) and cwd != "",
       do: cwd

  defp request_cwd(%{execution_request: %{cwd: cwd}}) when is_binary(cwd) and cwd != "", do: cwd

  defp request_cwd(_), do: nil

  defp existing_file(path, root) when is_binary(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, real_path} <- real_path(path),
         true <- path_allowed?(real_path, root) do
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

  defp image_path?(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&MapSet.member?(@image_extensions, &1))
  end

  defp image_path?(_), do: false

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

  defp path_allowed?(path, root) when is_binary(root), do: path_within_root?(path, root)
  defp path_allowed?(path, nil), do: is_binary(path) and Path.type(path) == :absolute
  defp path_allowed?(_, _), do: false

  defp real_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> resolve_absolute_path()
  end

  defp real_path(_), do: :error

  defp resolve_absolute_path(path) when is_binary(path) do
    case Path.split(path) do
      [root | segments] -> resolve_absolute_segments(root, segments)
      _ -> :error
    end
  end

  defp resolve_absolute_path(_), do: :error

  defp resolve_absolute_segments(current, []), do: {:ok, current}

  defp resolve_absolute_segments(current, [segment | rest]) do
    next = Path.join(current, segment)

    case File.lstat(next) do
      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(next) do
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

          resolve_absolute_path(combined)
        else
          _ -> :error
        end

      {:ok, _stat} ->
        resolve_absolute_segments(next, rest)

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
