defmodule LemonRouter.SurfaceManager do
  @moduledoc """
  Router-owned semantic output façade for `RunProcess`.

  `RunProcess` uses this module as its output API. Answer streaming still lives
  in `StreamCoalescer`, tool/task status streaming still lives in
  `ToolStatusCoalescer`, and channel-specific presentation remains in
  `lemon_channels`. `SurfaceManager` owns the router-side coordination across
  those surfaces, including answer/status handoff, task-surface bookkeeping,
  and final-answer fanout.
  """

  require Logger

  alias LemonCore.{DeliveryIntent, DeliveryRoute, Event, MapHelpers}
  alias LemonRouter.{ChannelContext, DeliveryRouteResolver, StreamCoalescer, ToolStatusCoalescer}
  alias LemonRouter.RunProcess.{CompactionTrigger, RetryHandler}

  @spec ingest_answer_delta(map(), map()) :: :ok
  def ingest_answer_delta(state, delta) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key),
         seq when is_integer(seq) <- MapHelpers.get_key(delta, :seq),
         text when is_binary(text) <- MapHelpers.get_key(delta, :text) do
      StreamCoalescer.ingest_delta(
        state.session_key,
        channel_id,
        state.run_id,
        seq,
        text,
        meta: coalescer_meta(state)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec prepare_status_action(map(), map()) :: {map(), term(), boolean()}
  def prepare_status_action(state, action_event) do
    task_surfaces = Map.get(state, :task_status_surfaces, %{})
    task_refs = Map.get(state, :task_status_refs, %{})
    action = MapHelpers.get_key(action_event, :action) || %{}
    action_id = MapHelpers.get_key(action, :id)
    parent_id = action_parent_tool_use_id(action)
    mapped_ref = mapped_task_ref(task_refs, action)

    cond do
      is_binary(parent_id) and Map.has_key?(task_surfaces, parent_id) ->
        {state, Map.fetch!(task_surfaces, parent_id), false}

      mapped_ref != nil ->
        {state, mapped_ref.surface, false}

      is_binary(action_id) and Map.has_key?(task_surfaces, action_id) ->
        surface = Map.fetch!(task_surfaces, action_id)
        {track_task_refs(state, action, surface, action_id), surface, false}

      task_root_action?(action) and is_binary(action_id) and action_id != "" ->
        surface = task_surface(action_id)

        next_state =
          state
          |> Map.put(:task_status_surfaces, Map.put(task_surfaces, action_id, surface))
          |> track_task_refs(action, surface, action_id)

        {next_state, surface, true}

      true ->
        {state, :status, true}
    end
  end

  @spec handoff_answer_to_status(map(), term()) :: :ok
  def handoff_answer_to_status(state, surface) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key),
         {:ok, text} <-
           StreamCoalescer.handoff_turn(
             state.session_key,
             channel_id,
             state.run_id,
             surface
           ) do
      ToolStatusCoalescer.anchor_segment(
        state.session_key,
        channel_id,
        state.run_id,
        text,
        meta: coalescer_meta(state),
        surface: surface
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec ingest_status_action(map(), map(), term()) :: :ok
  def ingest_status_action(state, action_event, surface) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      ToolStatusCoalescer.ingest_action(
        state.session_key,
        channel_id,
        state.run_id,
        attach_task_parent(action_event, state),
        meta: coalescer_meta(state),
        surface: surface
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec ingest_projected_child_action(map(), map(), term()) :: :ok
  def ingest_projected_child_action(state, action_event, surface) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      ToolStatusCoalescer.ingest_projected_child_action(
        state.session_key,
        channel_id,
        state.run_id,
        surface,
        action_event,
        meta: coalescer_meta(state)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec commit_status_segment(map(), term()) :: :ok
  def commit_status_segment(state, surface \\ :status) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      ToolStatusCoalescer.commit_segment(
        state.session_key,
        channel_id,
        state.run_id,
        meta: coalescer_meta(state),
        surface: surface
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec finalize_status(map(), Event.t()) :: :ok
  def finalize_status(state, %Event{} = event) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      ok? =
        case event.payload do
          %{completed: %{ok: ok}} -> ok == true
          %{"completed" => %{"ok" => ok}} -> ok == true
          %{ok: ok} -> ok == true
          %{"ok" => ok} -> ok == true
          _ -> false
        end

      Enum.each(active_status_surfaces(state), fn surface ->
        ToolStatusCoalescer.finalize_run(
          state.session_key,
          channel_id,
          state.run_id,
          ok?,
          meta: coalescer_meta(state),
          surface: surface
        )
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec flush_status(map()) :: :ok
  def flush_status(state) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      Enum.each(active_status_surfaces(state), fn surface ->
        ToolStatusCoalescer.flush(state.session_key, channel_id, surface: surface)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec flush_all(map()) :: :ok
  def flush_all(state) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      StreamCoalescer.flush(state.session_key, channel_id)

      Enum.each(active_status_surfaces(state), fn surface ->
        ToolStatusCoalescer.flush(state.session_key, channel_id, surface: surface)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec finalize_answer(map(), Event.t(), map()) :: :ok
  def finalize_answer(state, %Event{} = event, extra_meta) when is_map(extra_meta) do
    with {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
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
              {false, err} -> "Run failed: #{RetryHandler.format_run_error(err)}"
              _ -> nil
            end
        end

      meta =
        state
        |> coalescer_meta()
        |> maybe_put_resume(resume)
        |> Map.merge(extra_meta)

      StreamCoalescer.finalize_run(
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

  @spec maybe_seed_final_answer(map(), Event.t()) :: :ok
  def maybe_seed_final_answer(state, %Event{} = event) do
    with false <- state.saw_delta,
         answer when is_binary(answer) and answer != "" <-
           CompactionTrigger.extract_completed_answer(event),
         {:ok, channel_id} <- ChannelContext.channel_id(state.session_key) do
      StreamCoalescer.ingest_delta(
        state.session_key,
        channel_id,
        state.run_id,
        1,
        answer,
        meta: coalescer_meta(state)
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  @spec fanout_final_answer(map(), Event.t()) :: :ok
  def fanout_final_answer(state, %Event{} = event) do
    with answer when is_binary(answer) <- CompactionTrigger.extract_completed_answer(event),
         true <- String.trim(answer) != "",
         routes when is_list(routes) and routes != [] <- fanout_routes(state) do
      primary_signature = primary_route_signature(state)

      routes
      |> Enum.map(&normalize_fanout_route/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(&fanout_route_signature/1)
      |> Enum.reject(&(fanout_route_signature(&1) == primary_signature))
      |> Enum.with_index(1)
      |> Enum.each(fn {route, index} ->
        intent = %DeliveryIntent{
          intent_id: "#{state.run_id}:fanout:#{index}",
          run_id: state.run_id,
          session_key: state.session_key,
          route: route,
          kind: :final_text,
          body: %{text: answer, seq: index},
          meta: %{surface: :answer, fanout: true, fanout_index: index}
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
    end

    :ok
  rescue
    _ -> :ok
  end

  defp coalescer_meta(%{execution_request: %LemonGateway.ExecutionRequest{} = request}) do
    ChannelContext.coalescer_meta_from_request(request)
  end

  defp coalescer_meta(_), do: %{}

  defp maybe_put_resume(meta, %LemonCore.ResumeToken{} = resume), do: Map.put(meta, :resume, resume)
  defp maybe_put_resume(meta, _), do: meta

  defp active_status_surfaces(state) do
    [:status | Map.values(Map.get(state, :task_status_surfaces, %{}))]
    |> Enum.uniq()
  end

  defp task_surface(task_id), do: {:status_task, task_id}

  defp task_root_action?(action) when is_map(action) do
    detail = MapHelpers.get_key(action, :detail) || %{}
    args = MapHelpers.get_key(detail, :args) || %{}
    kind = MapHelpers.get_key(action, :kind)
    action_name = MapHelpers.get_key(args, :action)
    task_name = MapHelpers.get_key(detail, :name)

    is_map(detail) and task_name == "task" and action_name not in ["poll", "join", :poll, :join] and
      kind in ["subagent", :subagent]
  end

  defp task_root_action?(_), do: false

  defp action_parent_tool_use_id(action) when is_map(action) do
    action
    |> MapHelpers.get_key(:detail)
    |> MapHelpers.get_key(:parent_tool_use_id)
  end

  defp action_parent_tool_use_id(_), do: nil

  defp track_task_refs(state, action, surface, default_root_action_id) do
    task_ids = action_task_ids(action)

    if task_ids == [] do
      state
    else
      updated_refs =
        Enum.reduce(task_ids, Map.get(state, :task_status_refs, %{}), fn task_id, acc ->
          root_action_id =
            case Map.get(acc, task_id) do
              %{root_action_id: existing} when is_binary(existing) and existing != "" -> existing
              _ -> default_root_action_id
            end

          Map.put(acc, task_id, %{surface: surface, root_action_id: root_action_id})
        end)

      Map.put(state, :task_status_refs, updated_refs)
    end
  end

  defp mapped_task_ref(task_refs, action) when is_map(task_refs) do
    action
    |> action_task_ids()
    |> Enum.map(&Map.get(task_refs, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [ref] -> ref
      _ -> nil
    end
  end

  defp mapped_task_ref(_, _), do: nil

  defp action_task_ids(action) when is_map(action) do
    detail = MapHelpers.get_key(action, :detail) || %{}
    args = MapHelpers.get_key(detail, :args) || %{}
    result_meta = MapHelpers.get_key(detail, :result_meta) || %{}

    []
    |> maybe_prepend_task_id(MapHelpers.get_key(result_meta, :task_id))
    |> maybe_prepend_task_ids(MapHelpers.get_key(result_meta, :task_ids))
    |> maybe_prepend_task_id(MapHelpers.get_key(args, :task_id))
    |> maybe_prepend_task_ids(MapHelpers.get_key(args, :task_ids))
    |> Enum.uniq()
  end

  defp action_task_ids(_), do: []

  defp maybe_prepend_task_id(list, task_id)
       when is_list(list) and is_binary(task_id) and task_id != "",
       do: [task_id | list]

  defp maybe_prepend_task_id(list, _), do: list

  defp maybe_prepend_task_ids(list, task_ids) when is_list(list) and is_list(task_ids) do
    task_ids
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Kernel.++(list)
  end

  defp maybe_prepend_task_ids(list, _), do: list

  defp attach_task_parent(action_event, state) when is_map(action_event) do
    action = MapHelpers.get_key(action_event, :action) || %{}

    cond do
      action_parent_tool_use_id(action) ->
        action_event

      true ->
        case mapped_task_ref(Map.get(state, :task_status_refs, %{}), action) do
          %{root_action_id: root_action_id}
          when is_binary(root_action_id) and root_action_id != "" ->
            if root_action_id != MapHelpers.get_key(action, :id) do
              detail = MapHelpers.get_key(action, :detail) || %{}

              next_action =
                Map.put(action, :detail, Map.put(detail, :parent_tool_use_id, root_action_id))

              Map.put(action_event, :action, next_action)
            else
              action_event
            end

          _ ->
            action_event
        end
    end
  end

  defp attach_task_parent(action_event, _), do: action_event

  defp fanout_routes(%{execution_request: %LemonGateway.ExecutionRequest{meta: meta}})
       when is_map(meta) do
    MapHelpers.get_key(meta, :fanout_routes) || []
  end

  defp fanout_routes(_), do: []

  defp normalize_fanout_route(route) when is_map(route) do
    channel_id = MapHelpers.get_key(route, :channel_id)
    account_id = MapHelpers.get_key(route, :account_id) || "default"
    peer_kind = normalize_fanout_peer_kind(MapHelpers.get_key(route, :peer_kind))
    peer_id = MapHelpers.get_key(route, :peer_id)
    thread_id = MapHelpers.get_key(route, :thread_id)

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
        %DeliveryRoute{
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

  defp fanout_route_signature(%DeliveryRoute{} = route) do
    {route.channel_id, route.account_id, route.peer_kind, route.peer_id, route.thread_id}
  end

  defp primary_route_signature(state) do
    fallback_channel_id =
      case ChannelContext.channel_id(state.session_key) do
        {:ok, channel_id} -> channel_id
        :error -> nil
      end

    case DeliveryRouteResolver.resolve(state.session_key, fallback_channel_id, request_meta(state)) do
      {:ok, %DeliveryRoute{} = route} -> fanout_route_signature(route)
      :error -> nil
    end
  end

  defp request_meta(%{execution_request: %LemonGateway.ExecutionRequest{meta: meta}}) when is_map(meta),
    do: meta

  defp request_meta(_), do: %{}

  defp dispatcher do
    Application.get_env(:lemon_router, :dispatcher, LemonChannels.Dispatcher)
  end
end
