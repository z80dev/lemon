defmodule LemonRouter.RunProcess.OutputTracker do
  @moduledoc """
  Output tracking, stream coalescing, tool-status management, and file
  attachment logic for RunProcess.

  Responsible for ingesting deltas into StreamCoalescer, emitting final
  output when no streaming occurred, finalizing tool-status messages,
  fanout delivery to secondary routes, and tracking generated images /
  requested send-files for automatic attachment.
  """

  require Logger

  alias LemonCore.{DeliveryIntent, DeliveryRoute, SessionKey}
  alias LemonRouter.ChannelContext
  alias LemonRouter.RunProcess.CompactionTrigger

  @image_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff .heic .heif))

  # ---- Delta / stream ingestion ----

  @spec ingest_delta_to_coalescer(map(), map()) :: :ok
  def ingest_delta_to_coalescer(state, delta) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        meta = coalescer_meta(state)

        seq = Map.get(delta, :seq)
        text = Map.get(delta, :text)

        if is_integer(seq) and is_binary(text) do
          LemonRouter.StreamCoalescer.ingest_delta(
            state.session_key,
            channel_id,
            state.run_id,
            seq,
            text,
            meta: meta
          )
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ---- Final output ----

  @spec maybe_emit_final_output(map(), LemonCore.Event.t()) :: :ok
  def maybe_emit_final_output(state, %LemonCore.Event{} = event) do
    with false <- state.saw_delta,
         answer when is_binary(answer) and answer != "" <-
           CompactionTrigger.extract_completed_answer(event),
         {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      meta = coalescer_meta(state)

      LemonRouter.StreamCoalescer.ingest_delta(
        state.session_key,
        channel_id,
        state.run_id,
        1,
        answer,
        meta: meta
      )
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @spec maybe_finalize_stream_output(map(), LemonCore.Event.t()) :: :ok
  def maybe_finalize_stream_output(state, %LemonCore.Event{} = event) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      meta = coalescer_meta(state)

      resume =
        event
        |> CompactionTrigger.extract_completed_resume()
        |> CompactionTrigger.normalize_resume_token()

      final_text =
        case CompactionTrigger.extract_completed_answer(event) do
          answer when is_binary(answer) and answer != "" ->
            answer

          _ ->
            case CompactionTrigger.extract_completed_ok_and_error(event) do
              {false, err} ->
                "Run failed: #{LemonRouter.RunProcess.RetryHandler.format_run_error(err)}"

              _ ->
                nil
            end
        end

      meta = if resume, do: Map.put(meta, :resume, resume), else: meta
      meta = maybe_add_auto_send_generated_files(meta, state, channel_id)

      LemonRouter.StreamCoalescer.finalize_run(
        state.session_key,
        channel_id,
        state.run_id,
        meta: meta,
        final_text: final_text
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # ---- Tool status ----

  @spec finalize_tool_status(map(), LemonCore.Event.t()) :: :ok
  def finalize_tool_status(state, %LemonCore.Event{} = event) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        ok? =
          case event.payload do
            %{completed: %{ok: ok}} -> ok == true
            %{ok: ok} -> ok == true
            _ -> false
          end

        meta = coalescer_meta(state)

        LemonRouter.ToolStatusCoalescer.finalize_run(
          state.session_key,
          channel_id,
          state.run_id,
          ok?,
          meta: meta
        )

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec ingest_action_to_tool_status_coalescer(map(), map()) :: :ok
  def ingest_action_to_tool_status_coalescer(state, action_ev) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        meta = coalescer_meta(state)

        LemonRouter.ToolStatusCoalescer.ingest_action(
          state.session_key,
          channel_id,
          state.run_id,
          action_ev,
          meta: meta
        )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @spec flush_coalescer(map()) :: :ok
  def flush_coalescer(state) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        LemonRouter.StreamCoalescer.flush(state.session_key, channel_id)
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @spec flush_tool_status(map()) :: :ok
  def flush_tool_status(state) do
    case ChannelContext.channel_id(state.session_key) do
      {:ok, channel_id} ->
        LemonRouter.ToolStatusCoalescer.flush(state.session_key, channel_id)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ---- Fanout ----

  @spec maybe_fanout_final_output(map(), LemonCore.Event.t()) :: :ok
  def maybe_fanout_final_output(state, %LemonCore.Event{} = event) do
    with answer when is_binary(answer) <- CompactionTrigger.extract_completed_answer(event),
         true <- String.trim(answer) != "",
         routes when is_list(routes) and routes != [] <- fanout_routes(state) do
      primary_signature = primary_route_signature(state.session_key)

      routes
      |> Enum.map(&normalize_fanout_route/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&fanout_route_signature/1)
      |> Enum.reject(&(fanout_route_signature(&1) == primary_signature))
      |> Enum.with_index()
      |> Enum.each(fn {route, idx} ->
        route = to_delivery_route(route)

        intent = %DeliveryIntent{
          intent_id: "#{state.run_id}:fanout:#{idx + 1}",
          run_id: state.run_id,
          session_key: state.session_key,
          route: route,
          kind: :final_text,
          body: %{text: answer, seq: idx + 1},
          meta: %{surface: :answer, fanout: true, fanout_index: idx + 1}
        }

        case dispatcher().dispatch(intent) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Failed to dispatch fanout output for run_id=#{inspect(state.run_id)} route=#{inspect(route)} reason=#{inspect(reason)}"
            )
        end
      end)
    else
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  # ---- Image / file tracking ----

  @spec maybe_track_generated_images(map(), map()) :: map()
  def maybe_track_generated_images(state, action_ev) do
    paths = extract_generated_image_paths(action_ev)

    if paths == [] do
      state
    else
      existing = state.generated_image_paths || []
      %{state | generated_image_paths: merge_paths(existing, paths)}
    end
  end

  @spec maybe_track_requested_send_files(map(), map()) :: map()
  def maybe_track_requested_send_files(state, action_ev) do
    files = extract_requested_send_files(action_ev)

    if files == [] do
      state
    else
      existing = state.requested_send_files || []
      %{state | requested_send_files: merge_files(existing, files)}
    end
  end

  # ---- Private helpers ----

  defp fanout_routes(%{execution_request: %LemonGateway.ExecutionRequest{meta: meta}})
       when is_map(meta) do
    fetch(meta, :fanout_routes) || []
  rescue
    _ -> []
  end

  defp fanout_routes(_), do: []

  defp coalescer_meta(%{execution_request: %LemonGateway.ExecutionRequest{} = request}),
    do: ChannelContext.coalescer_meta_from_job(request)

  defp coalescer_meta(_), do: %{}

  defp request_cwd(%{execution_request: %LemonGateway.ExecutionRequest{cwd: cwd}})
       when is_binary(cwd) and cwd != "",
       do: cwd

  defp request_cwd(_), do: nil

  defp primary_route_signature(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{
        kind: :channel_peer,
        channel_id: channel_id,
        account_id: account_id,
        peer_kind: peer_kind,
        peer_id: peer_id,
        thread_id: thread_id
      } ->
        {channel_id, account_id, peer_kind, peer_id, thread_id}

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp primary_route_signature(_), do: nil

  defp normalize_fanout_route(route) when is_map(route) do
    channel_id = fetch(route, :channel_id)
    account_id = fetch(route, :account_id) || "default"
    peer_kind = normalize_fanout_peer_kind(fetch(route, :peer_kind))
    peer_id = fetch(route, :peer_id)
    thread_id = fetch(route, :thread_id)

    cond do
      not is_binary(channel_id) or channel_id == "" ->
        nil

      not is_binary(account_id) or account_id == "" ->
        nil

      not is_binary(peer_id) or peer_id == "" ->
        nil

      is_nil(peer_kind) ->
        nil

      true ->
        %{
          channel_id: channel_id,
          account_id: account_id,
          peer_kind: peer_kind,
          peer_id: peer_id,
          thread_id: if(is_binary(thread_id) and thread_id != "", do: thread_id, else: nil)
        }
    end
  rescue
    _ -> nil
  end

  defp normalize_fanout_route(_), do: nil

  defp normalize_fanout_peer_kind(kind) when kind in [:dm, :group, :channel], do: kind

  defp normalize_fanout_peer_kind(kind) when is_binary(kind) do
    case String.downcase(String.trim(kind)) do
      "dm" -> :dm
      "group" -> :group
      "channel" -> :channel
      _ -> nil
    end
  end

  defp normalize_fanout_peer_kind(_), do: nil

  defp fanout_route_signature(route) when is_map(route) do
    {route.channel_id, route.account_id, route.peer_kind, route.peer_id, route.thread_id}
  end

  defp to_delivery_route(route) do
    %DeliveryRoute{
      channel_id: route.channel_id,
      account_id: route.account_id,
      peer_kind: route.peer_kind,
      peer_id: route.peer_id,
      thread_id: route.thread_id
    }
  end

  defp merge_paths(existing, new_paths) do
    Enum.uniq(existing ++ new_paths)
  end

  defp extract_requested_send_files(action_ev) do
    action = fetch(action_ev, :action)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)
        result_meta = fetch(detail, :result_meta)
        auto_send_files = fetch(result_meta, :auto_send_files)

        case auto_send_files do
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
    path = fetch(file, :path)
    filename = fetch(file, :filename)
    caption = fetch(file, :caption)

    if is_binary(path) and path != "" do
      %{
        path: path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end
      }
    else
      nil
    end
  end

  defp normalize_requested_send_file(_), do: nil

  defp extract_generated_image_paths(action_ev) do
    action = fetch(action_ev, :action)
    kind = fetch(action, :kind)
    phase = fetch(action_ev, :phase)
    ok = fetch(action_ev, :ok)

    cond do
      not file_change_kind?(kind) ->
        []

      not phase_completed?(phase) ->
        []

      ok == false ->
        []

      true ->
        detail = fetch(action, :detail)

        case fetch(detail, :changes) do
          changes when is_list(changes) ->
            changes
            |> Enum.flat_map(fn change ->
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

  defp extract_image_change_path(change) do
    path = fetch(change, :path)
    kind = fetch(change, :kind)

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

  defp file_change_kind?(kind) when kind in [:file_change, "file_change"], do: true
  defp file_change_kind?(_), do: false

  defp phase_completed?(phase) when phase in [:completed, "completed"], do: true
  defp phase_completed?(_), do: false

  defp deleted_change_kind?(kind) when kind in [:deleted, "deleted", :remove, "remove"], do: true
  defp deleted_change_kind?(_), do: false

  defp image_path?(path) when is_binary(path),
    do:
      path |> Path.extname() |> String.downcase() |> then(&MapSet.member?(@image_extensions, &1))

  defp image_path?(_), do: false

  defp maybe_add_auto_send_generated_files(meta, state, _channel_id) when is_map(meta) do
    explicit_files =
      state.requested_send_files
      |> resolve_explicit_send_files(request_cwd(state))

    generated_files =
      state.generated_image_paths
      |> resolve_generated_files(request_cwd(state))

    files = merge_files(explicit_files, generated_files)

    if files == [] do
      meta
    else
      Map.put(meta, :auto_send_files, files)
    end
  end

  defp maybe_add_auto_send_generated_files(meta, _state, _channel_id), do: meta

  defp resolve_generated_files(paths, cwd) when is_list(paths) do
    paths
    |> Enum.map(&resolve_generated_path(&1, cwd))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      case existing_file(path) do
        {:ok, file} -> [Map.put(file, :source, :generated)]
        _ -> []
      end
    end)
  end

  defp resolve_generated_files(_, _cwd), do: []

  defp resolve_explicit_send_files(files, cwd) when is_list(files) do
    files
    |> Enum.map(&resolve_explicit_send_file(&1, cwd))
    |> Enum.reject(&is_nil/1)
  end

  defp resolve_explicit_send_files(_, _cwd), do: []

  defp resolve_explicit_send_file(file, cwd) when is_map(file) do
    path = fetch(file, :path)
    caption = fetch(file, :caption)
    filename = fetch(file, :filename)

    resolved_path = resolve_file_path(path, cwd)

    with path when is_binary(path) and path != "" <- path,
         resolved when is_binary(resolved) <- resolved_path,
         {:ok, %{path: valid_path}} <- existing_file(resolved) do
      %{
        path: valid_path,
        filename:
          case filename do
            x when is_binary(x) and x != "" -> x
            _ -> Path.basename(valid_path)
          end,
        caption:
          case caption do
            x when is_binary(x) and x != "" -> x
            _ -> nil
          end,
        source: :explicit
      }
    else
      _ -> nil
    end
  end

  defp resolve_explicit_send_file(_, _cwd), do: nil

  defp resolve_file_path(path, cwd) do
    cond do
      is_binary(cwd) and cwd != "" ->
        resolve_generated_path(path, cwd) || absolute_path_or_nil(path)

      is_binary(path) and Path.type(path) == :absolute ->
        Path.expand(path)

      true ->
        nil
    end
  end

  defp absolute_path_or_nil(path) do
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

    if path_within_root?(absolute, root) do
      absolute
    else
      nil
    end
  end

  defp resolve_generated_path(_path, _cwd), do: nil

  defp merge_files(first, second) when is_list(first) and is_list(second) do
    {merged, _seen} =
      Enum.reduce(first ++ second, {[], MapSet.new()}, fn file, {acc, seen} ->
        key = {Map.get(file, :path), Map.get(file, :caption)}

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

  defp path_within_root?(absolute, root) when is_binary(absolute) and is_binary(root) do
    rel = Path.relative_to(absolute, root)
    rel == "." or not String.starts_with?(rel, "..")
  end

  defp existing_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, %File.Stat{}} <- File.stat(path) do
      {:ok, %{path: path, filename: Path.basename(path), caption: nil}}
    else
      _ -> :error
    end
  end

  defp existing_file(_path), do: :error

  # ---- Shared utility helpers ----

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_, _), do: nil

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, LemonChannels.Dispatcher)
  end
end
