defmodule LemonRouter.AgentMessagingSessions do
  @moduledoc false

  alias LemonCore.{
    AgentIdentity,
    ExecutionCommand,
    MapHelpers,
    ResumeToken,
    RunRequest,
    RunStore,
    SessionKey,
    Store
  }

  @table :agent_messaging_sessions
  @context_keys [
    :profile_id,
    :model,
    :model_explicit,
    :thinking_level,
    :system_prompt,
    :invocation_context_key,
    :channel_context,
    :channel_id,
    :account_id,
    :peer,
    :native_managed_context,
    :task_child,
    :session_scope
  ]

  # Called with the actual admitted command, never with model-supplied identity.
  # No prompts, MCP credentials or lineage handles are retained in this snapshot.
  def capture(command) do
    if local_session?(command.session_key), do: capture_local(command), else: :ok
  end

  # A queued human turn must not replace the immutable defaults of the native
  # owner that is still executing tools. The real RunProcess refreshes this
  # snapshot when that turn actually starts.
  def capture_admission(command) do
    if local_session?(command.session_key) do
      case RunStore.ensure_session_incarnation(command.session_key) do
        {:ok, index} ->
          with {:ok, snapshot} <- Store.fetch(@table, command.session_key) do
            case snapshot do
              %{incarnation: incarnation} when incarnation == index.incarnation -> :ok
              _ -> capture(command)
            end
          end

        {:error, :not_found} ->
          capture(command)

        {:error, _} = error ->
          error
      end
    else
      :ok
    end
  end

  defp capture_local(command) do
    context = %{
      session_key: command.session_key,
      agent_id:
        MapHelpers.get_key(command.meta || %{}, :agent_id) ||
          SessionKey.agent_id(command.session_key),
      cwd: command.cwd,
      tool_policy: command.tool_policy,
      meta: project(command.meta || %{}),
      runtime_context_required:
        MapHelpers.get_key(command.meta || %{}, :mcp_servers) not in [nil, []],
      empty_mcp: MapHelpers.get_key(command.meta || %{}, :mcp_servers) == [],
      eligible: eligible_metadata?(command.meta || %{}) and local_session?(command.session_key),
      run_id: command.run_id
    }

    with :ok <- ensure_index(context),
         {:ok, index} <- RunStore.ensure_session_incarnation(command.session_key),
         context <- Map.put(context, :incarnation, index.incarnation),
         :ok <- Store.put(@table, command.session_key, context),
         :ok <- Store.sync() do
      :ok
    else
      _ -> {:error, :outcome_unknown}
    end
  end

  def discover do
    with {:ok, rows} <- Store.fetch_all(:sessions_index) do
      Enum.reduce_while(rows, :ok, fn
        {key, row}, :ok when is_binary(key) and is_map(row) ->
          case ensure("operator", "session://" <> key) do
            {:ok, _} ->
              {:cont, :ok}

            {:error, reason} when reason in [:forbidden, :not_found, :context_unavailable] ->
              {:cont, :ok}

            {:error, _} = error ->
              {:halt, error}
          end

        _, :ok ->
          {:cont, :ok}
      end)
    end
  end

  def ensure("operator", "session://" <> key = id) do
    with {:ok, context} <- context(key),
         true <- context.eligible,
         {:ok, entry} <-
           AgentIdentity.register("operator", id, %{kind: :session, session_key: key}) do
      {:ok, entry}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def ensure(_, _), do: {:error, :not_found}

  def context(key) do
    with true <- local_session?(key),
         {:ok, index} <- RunStore.ensure_session_incarnation(key),
         {:ok, snapshot} <- Store.fetch(@table, key) do
      case snapshot do
        %{incarnation: incarnation, eligible: true} when incarnation == index.incarnation ->
          {:ok, snapshot}

        %{incarnation: incarnation, eligible: false} when incarnation == index.incarnation ->
          {:error, :forbidden}

        _ ->
          legacy_context(key, index)
      end
    else
      false -> {:error, :forbidden}
      {:error, :not_found} -> {:error, :not_found}
      {:error, _} -> {:error, :unavailable}
    end
  end

  def validate_source(id, nil), do: validate_source_identity(id)

  def validate_source("session://" <> key = id, source) when is_map(source) do
    with true <- MapHelpers.get_key(source, :session_key) == key,
         true <- eligible_metadata?(source),
         true <- local_session?(key),
         :ok <- validate_source_identity(id) do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  def validate_source(_, _), do: {:error, :forbidden}

  def request(
        entry,
        run_id,
        prompt,
        extra_meta \\ %{},
        captured_context \\ nil,
        runtime_meta \\ nil
      ) do
    with {:ok, current} <- context(entry.session_key),
         context <- captured_context || current,
         true <-
           context.session_key == entry.session_key and context.eligible and
             Map.get(context, :incarnation) == current.incarnation,
         {:ok, context} <- prepare_context(context, runtime_meta),
         :ok <- bind_recovered_context(current, runtime_meta),
         {:ok, resume} <- continuation_resume(entry.session_key, context) do
      {:ok,
       RunRequest.new(%{
         run_id: run_id,
         origin: :control_plane,
         session_key: entry.session_key,
         agent_id: context.agent_id,
         prompt: prompt,
         cwd: context.cwd,
         tool_policy: context.tool_policy,
         resume: resume,
         queue_mode: :collect,
         meta:
           context.meta
           |> Map.merge(extra_meta)
           |> Map.put(
             :named_agent_require_resume,
             not is_nil(context.run_id) or not is_nil(Map.get(current, :recovered_resume))
           )
       })}
    else
      false -> {:error, :forbidden}
      error -> error
    end
  end

  def eligible_metadata?(meta) do
    not managed?(meta) and
      not child?(meta) and
      MapHelpers.get_key(meta, :node) in [nil, "", "local", :local]
  end

  def local_session?(key) when is_binary(key) do
    SessionKey.valid?(key) and
      case SessionKey.parse(key) do
        %{kind: :main} -> true
        %{kind: :channel_peer, channel_id: channel} -> channel in ["fork", "tui", "local"]
        _ -> false
      end
  end

  def local_session?(_), do: false

  defp child?(meta) do
    case Map.fetch(meta, :task_child) do
      {:ok, flag} when is_boolean(flag) -> flag
      _ -> MapHelpers.get_key(meta, :session_scope) in [:subagent, "subagent"]
    end
  end

  defp validate_source_identity("session://" <> key) do
    case context(key) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp validate_source_identity(_), do: :ok

  defp managed?(meta) do
    # The native runtime's explicit false marker distinguishes ordinary profiles
    # from managed Bot lineage. Verified invocation authority is never borrowed.
    MapHelpers.get_key(meta, :invocation_proof_verified) == true or
      case Map.fetch(meta, :native_managed_context) do
        {:ok, flag} when is_boolean(flag) ->
          flag

        _ ->
          Enum.any?([:memory_context_key, :invocation_proof, :native_lineage_handle], fn key ->
            MapHelpers.get_key(meta, key) not in [nil, false, ""]
          end) or reserved_config?(MapHelpers.get_key(meta, :mcp_servers))
      end
  end

  defp reserved_config?(value) when is_binary(value),
    do: String.contains?(value, "lemon_bot/invocations/")

  defp reserved_config?(value) when is_list(value), do: Enum.any?(value, &reserved_config?/1)

  defp reserved_config?(value) when is_map(value),
    do: Enum.any?(value, fn {_, item} -> reserved_config?(item) end)

  defp reserved_config?(_), do: false

  defp project(meta) do
    Map.new(@context_keys, &{&1, get(meta, &1)})
    |> Map.reject(fn {_, value} -> is_nil(value) end)
  end

  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp ensure_index(context) do
    case RunStore.create_session_index(context.session_key, context.agent_id, :control_plane) do
      :ok -> :ok
      {:error, :exists} -> :ok
      error -> error
    end
  end

  defp legacy_context(key, index) do
    with {:ok, record} <- latest_record(key, index) do
      summary = MapHelpers.get_key(record || %{}, :summary) || %{}
      meta = MapHelpers.get_key(summary, :meta) || %{}

      runtime = legacy_runtime_context(key)

      with {:ok, native} <- runtime,
           native_meta <- Map.merge(meta, Map.get(native, :meta, %{})),
           native_meta <-
             Map.merge(
               native_meta,
               Map.take(native, [:profile_id, :task_child, :native_managed_context])
             ),
           true <- eligible_metadata?(native_meta) do
        {:ok,
         %{
           session_key: key,
           incarnation: index.incarnation,
           recovered_resume: Map.get(native, :resume),
           agent_id: MapHelpers.get_key(index, :agent_id) || SessionKey.agent_id(key),
           cwd: native.cwd,
           tool_policy: Map.get(native, :tool_policy, MapHelpers.get_key(summary, :tool_policy)),
           meta: project(native_meta),
           runtime_context_required:
             MapHelpers.get_key(native_meta, :mcp_servers) not in [nil, []],
           empty_mcp: MapHelpers.get_key(native_meta, :mcp_servers) == [],
           eligible: true,
           run_id: if(MapHelpers.get_key(index, :run_count) == 0, do: nil, else: "existing")
         }}
      else
        false -> {:error, :forbidden}
        error -> error
      end
    end
  end

  defp prepare_context(context, runtime_meta) do
    meta = context.meta

    cond do
      Map.get(context, :runtime_context_required, false) and is_map(runtime_meta) and
          Map.has_key?(runtime_meta, :mcp_servers) ->
        {:ok, %{context | meta: Map.merge(meta, Map.take(runtime_meta, [:mcp_servers]))}}

      Map.get(context, :runtime_context_required, false) ->
        case LemonCore.AgentRuntime.call(
               :session_addressing_context,
               [context.session_key],
               {:error, :context_unavailable}
             ) do
          {:ok, %{cwd: cwd, task_child: false, meta: native_meta}}
          when cwd == context.cwd and is_map(native_meta) ->
            {:ok, %{context | meta: Map.merge(meta, Map.take(native_meta, [:mcp_servers]))}}

          _ ->
            {:error, :context_unavailable}
        end

      Map.get(context, :empty_mcp, false) ->
        {:ok, %{context | meta: Map.put(meta, :mcp_servers, [])}}

      true ->
        {:ok, %{context | meta: meta}}
    end
  end

  defp legacy_runtime_context(key) do
    result =
      LemonCore.AgentRuntime.call(
        :session_addressing_context,
        [key],
        {:error, :context_unavailable}
      )

    case result do
      {:ok, %{cwd: native_cwd, task_child: child, resume: %ResumeToken{engine: "lemon"}} = native}
      when is_binary(native_cwd) and native_cwd != "" and is_boolean(child) ->
        {:ok, native}

      {:error, _} = error ->
        error

      _ ->
        {:error, :context_unavailable}
    end
  end

  defp latest_record(key, index) do
    case MapHelpers.get_key(index, :__recent_run_ids__) do
      [run_id | _] ->
        RunStore.fetch(run_id)

      _ ->
        if MapHelpers.get_key(index, :run_count) == 0 do
          {:ok, nil}
        else
          case LemonCore.RunHistoryStore.fetch(key, limit: 1) do
            {:ok, [{_, record}]} -> {:ok, record}
            {:ok, []} -> {:error, :context_unavailable}
            _ -> {:error, :unavailable}
          end
        end
    end
  end

  # Only the native owner/journal callback can establish inherited authority.
  # bind/2 inserts once and refuses a different existing digest; a historical
  # cwd or a caller's explicit policy is never enough to rebind a journal.
  defp bind_recovered_context(
         %{recovered_resume: %ResumeToken{} = resume, tool_policy: policy} = current,
         runtime_meta
       )
       when is_map(policy) do
    with {:ok, context} <- prepare_context(current, runtime_meta),
         :ok <-
           LemonRouter.ResumeResolver.bind(resume, %ExecutionCommand{
             run_id: context.run_id,
             session_key: context.session_key,
             prompt: "",
             tool_policy: context.tool_policy,
             meta: context.meta
           }) do
      :ok
    else
      _ -> {:error, :context_unavailable}
    end
  end

  # Legacy journals without recorded policy keep the resolver's existing
  # unscoped-legacy rule; do not bind nil instead of the router's default policy.
  defp bind_recovered_context(_context, _runtime_meta), do: :ok

  defp continuation_resume(key, context) do
    # Automatic resume is resolved again when the queue drains. Verify that a
    # known journal is compatible now instead of silently creating a new agent.
    with {:ok, state} <- Store.fetch(:chat, key) do
      token = MapHelpers.get_key(state || %{}, :last_resume_token)
      engine = MapHelpers.get_key(state || %{}, :last_engine)

      case LemonRouter.ResumeResolver.resolve(nil, key, context.meta, context.tool_policy) do
        {:ok, nil, _} when is_binary(token) and engine == "lemon" ->
          {:error, :context_unavailable}

        {:ok, _resume, _} ->
          {:ok, nil}

        {:error, _} ->
          {:error, :context_unavailable}
      end
    end
  end
end
