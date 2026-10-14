defmodule CodingAgent.ControlPlaneProvider do
  @moduledoc """
  Exposes this agent's internals through the shared core runtime contract.

  Runtime consumers report on tasks, sessions, extensions, the run graph and
  progress without depending on this app; they call the provider registered with
  `LemonCore.AgentRuntime`. `CodingAgent.Application` registers this module at boot.

  Each function is a thin adapter over the agent's own modules. Shapes match
  what the control plane used to read directly, so method payloads are
  unchanged.

  Implements `LemonCore.AgentRuntime.Provider` through the app's core dependency.
  """

  @behaviour LemonCore.AgentRuntime.Provider

  def list_tasks, do: CodingAgent.TaskStore.list(:all)

  def get_task(task_id), do: CodingAgent.TaskStore.get(task_id)

  def todo_progress(session_key) do
    progress = CodingAgent.Tools.TodoStore.get_progress(session_key)
    actionable_count = session_key |> CodingAgent.Tools.TodoStore.get_actionable() |> length()
    Map.put(progress, :actionable_count, actionable_count)
  end

  def feature_progress(cwd), do: CodingAgent.Tools.FeatureRequirements.get_progress(cwd)

  def compact_session(session_key, opts) do
    case live_session(session_key) do
      nil ->
        with cwd when is_binary(cwd) <- Keyword.get(opts, :cwd),
             {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, pid} <-
               CodingAgent.Session.start_link(native_session_opts(session_key, cwd, path)) do
          try do
            CodingAgent.Session.compact(pid, opts)
          after
            GenServer.stop(pid, :normal)
          end
        else
          nil -> {:error, :session_not_found}
          {:error, _} = error -> error
        end

      pid ->
        CodingAgent.Session.compact(pid, opts)
    end
  end

  @doc "Return durable native branch entries for history replay through the runtime seam."
  def session_history(session_key, cwd) do
    with {:ok, path} <- native_session_path(session_key, cwd),
         {:ok, session} <- CodingAgent.SessionManager.load_from_file(path) do
      {:ok, CodingAgent.SessionManager.get_branch(session)}
    end
  end

  @doc "Read the current native branch, including offline rewind, without starting a session."
  def session_recovery_snapshot(session_key, cwd) do
    case live_session(session_key) do
      nil ->
        with cwd when is_binary(cwd) <- recovery_cwd(session_key, cwd),
             {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, session} <- CodingAgent.SessionManager.load_from_file(path),
             :ok <- recovery_owner(session_key, session.header.id) do
          {:ok, CodingAgent.Session.Recovery.snapshot(session)}
        else
          nil -> {:error, :unavailable}
          {:error, _} = error -> error
        end

      pid ->
        with {:ok, snapshot} <- CodingAgent.Session.recovery_snapshot(pid) do
          attempt =
            {pid, snapshot.run_id}
            |> :erlang.term_to_binary()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          {:ok, Map.put(snapshot, :attempt, attempt)}
        end
    end
  end

  defp recovery_owner(key, native_id) do
    case LemonCore.ChatStateStore.get(key) do
      state when is_map(state) ->
        token = Map.get(state, :last_resume_token) || Map.get(state, "last_resume_token")
        if token == native_id, do: :ok, else: {:error, :unavailable}

      _ ->
        {:error, :unavailable}
    end
  end

  defp recovery_cwd(key, cwd) do
    case LemonCore.ProfileStore.get(LemonCore.SessionKey.agent_id(key) || "default") do
      {:ok, %{"canonicalSessionKey" => ^key, "paths" => %{"workspace" => workspace}}} ->
        workspace

      {:error, :not_found} ->
        cwd || LemonCore.Cwd.default_cwd()

      {:ok, _other_profile} ->
        cwd || LemonCore.Cwd.default_cwd()

      _ ->
        # A profile-store failure cannot authorize a caller workspace override.
        nil
    end
  end

  @doc "Return process admission receipts only for an exact native session owner."
  def session_process_receipts(owner) when is_binary(owner) and owner != "" do
    manager = CodingAgent.ProcessManager

    if Code.ensure_loaded?(manager) and function_exported?(manager, :receipt, 2) do
      CodingAgent.ProcessStore.list(:all)
      |> Enum.filter(fn {_id, record} -> record.owner == owner end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, []}, fn {id, _record}, {:ok, receipts} ->
        case apply(manager, :receipt, [id, owner]) do
          {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
          _ -> {:halt, {:error, :unavailable}}
        end
      end)
      |> case do
        {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
        error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  def session_process_receipts(_owner), do: {:error, :unavailable}

  def session_tree(session_key, cwd, opts) do
    case live_session(session_key) do
      nil ->
        with {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, session} <- CodingAgent.SessionManager.load_from_file(path) do
          {:ok, CodingAgent.Session.Rewind.tree(session, opts)}
        end

      pid ->
        CodingAgent.Session.tree(pid, opts)
    end
  end

  def session_rewind(session_key, cwd, entry_id, opts) do
    case live_session(session_key) do
      nil ->
        with {:ok, path} <- native_session_path(session_key, cwd) do
          :global.trans({{__MODULE__, path}, self()}, fn ->
            with {:ok, session} <- CodingAgent.SessionManager.load_from_file(path),
                 {:ok, result, _session} <-
                   CodingAgent.Session.Rewind.run(%{session | file_path: path}, entry_id, opts) do
              {:ok, result}
            end
          end)
        end

      pid ->
        CodingAgent.Session.rewind(pid, entry_id, opts)
    end
  end

  @doc "Fork native history and bind the independent resume token to a new logical session."
  def session_fork(source_key, cwd, destination_key) do
    with :ok <- ensure_idle(source_key),
         nil <- LemonCore.ChatStateStore.get(destination_key),
         {:ok, source_path} <- native_session_path(source_key, cwd) do
      id = LemonCore.Id.uuid()
      destination_path = CodingAgent.Session.Presentation.session_file_path(id, cwd)

      with {:ok, _session} <-
             CodingAgent.SessionManager.fork_file(source_path, destination_path, id: id) do
        LemonCore.ChatStateStore.put(destination_key, %LemonCore.ChatState{
          last_engine: "lemon",
          last_resume_token: id,
          updated_at: System.system_time(:millisecond)
        })
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :destination_exists}
    end
  end

  @doc """
  Per-category context-window usage for a live or durable native session. A
  stopped session combines its durable history with the overhead profile its
  last save recorded (see `CodingAgent.Session.ContextUsage`).
  """
  def session_context_usage(session_key, cwd) do
    case live_session(session_key) do
      nil ->
        with {:ok, path} <- native_session_path(session_key, cwd),
             {:ok, session} <- load_native_session(path) do
          settings = CodingAgent.SettingsManager.load(session.header.cwd)
          context = CodingAgent.SessionManager.build_session_context(session)
          model = durable_model(context.model, settings)
          messages = CodingAgent.Session.Persistence.restore_messages_from_session(session)

          CodingAgent.Session.ContextUsage.measure_durable(
            %{session_manager: session, model: model, settings_manager: settings},
            messages,
            CodingAgent.Session.ContextUsage.stored_overhead(session.header.id)
          )
        end

      pid ->
        CodingAgent.Session.context_usage(pid)
    end
  end

  defp load_native_session(path) do
    case CodingAgent.SessionManager.load_from_file(path) do
      {:error, :enoent} -> {:error, :session_not_found}
      result -> result
    end
  end

  # A model that is no longer registered still has history worth measuring;
  # its window is then reported as unknown.
  defp durable_model(model, settings) do
    CodingAgent.Session.ModelResolver.resolve_session_model(model, settings)
  rescue
    ArgumentError -> nil
  end

  @doc "Explicitly allocate a durable empty native session without entering a mode or sending a prompt."
  def session_create(session_key, cwd) do
    if LemonCore.SessionKey.agent_id(session_key) in [nil, ""] do
      {:error, :invalid_session_key}
    else
      :global.trans({{__MODULE__, :native_session, session_key}, self()}, fn ->
        case native_session_path(session_key, cwd) do
          {:ok, path} ->
            with {:ok, session} <- CodingAgent.SessionManager.load_from_file(path),
                 result when result in [:ok, {:error, :exists}] <-
                   register_native_index(session_key) do
              {:ok, %{"sessionId" => session.header.id, "created" => false}}
            end

          {:error, :session_not_found} ->
            cond do
              live_session(session_key) != nil ->
                {:error, :busy}

              LemonCore.SessionLifecycle.get(session_key) != nil ->
                {:error, :unsupported_session}

              true ->
                with {:ok, session} <- create_native_session(session_key, cwd) do
                  {:ok, %{"sessionId" => session.header.id, "created" => true}}
                end
            end

          {:error, _} = error ->
            error
        end
      end)
    end
  end

  @doc "Inspect, enter, or exit branch-aware native plan mode."
  def session_plan(session_key, cwd, action, opts) do
    case live_session(session_key) do
      nil ->
        :global.trans({{__MODULE__, :native_session, session_key}, self()}, fn ->
          case native_session_path(session_key, cwd) do
            {:ok, path} ->
              :global.trans({{__MODULE__, path}, self()}, fn ->
                with {:ok, session} <- CodingAgent.SessionManager.load_from_file(path),
                     {:ok, plan, _} <-
                       CodingAgent.Session.Planning.transition(
                         %{session | file_path: path},
                         action,
                         opts
                       ) do
                  {:ok, plan}
                end
              end)

            {:error, :session_not_found} when action in [:status, :exit] ->
              {:ok, CodingAgent.Session.Planning.status(nil)}

            {:error, :session_not_found} when action == :enter ->
              with {:ok, session} <- create_native_session(session_key, cwd),
                   {:ok, plan, _} <- CodingAgent.Session.Planning.transition(session, :enter, []) do
                {:ok, plan}
              end

            {:error, _} = error ->
              error
          end
        end)

      pid ->
        CodingAgent.Session.plan(pid, action, opts)
    end
  end

  defp create_native_session(session_key, cwd) do
    session = CodingAgent.SessionManager.new(cwd)
    path = CodingAgent.SessionManager.session_file_path(cwd, session.header.id)
    session = CodingAgent.SessionManager.persist(session, path)

    with :ok <-
           LemonCore.ChatStateStore.put(session_key, %LemonCore.ChatState{
             last_engine: "lemon",
             last_resume_token: session.header.id,
             updated_at: System.system_time(:millisecond)
           }),
         :ok <- register_native_index(session_key) do
      {:ok, session}
    end
  end

  defp register_native_index(session_key) do
    LemonCore.RunStore.create_session_index(
      session_key,
      LemonCore.SessionKey.agent_id(session_key) || "default",
      :control_plane
    )
  end

  defp native_session_opts(session_key, cwd, path) do
    agent_id = LemonCore.SessionKey.agent_id(session_key) || "default"
    opts = [cwd: cwd, session_file: path, session_key: session_key, agent_id: agent_id]

    case LemonCore.ProfileStore.get(agent_id) do
      {:ok, %{"canonicalSessionKey" => ^session_key, "paths" => %{"workspace" => workspace}}} ->
        Keyword.put(opts, :workspace_dir, workspace)

      _ ->
        opts
    end
  end

  def tool_policy(profile), do: CodingAgent.ToolPolicy.from_profile(profile)

  @doc "Resolve canonical persona instructions and policy without exposing product dependencies."
  def resolve_subagent(cwd, id) do
    case CodingAgent.Subagents.fetch(cwd, id) do
      {:ok, persona} ->
        {:ok,
         persona
         |> Map.take([:prompt, :model, :role])
         |> Map.put(:tool_policy, CodingAgent.Subagents.tool_policy(persona, nil))}

      {:error, _reason} ->
        {:error, :persona_unavailable}
    end
  end

  defp ensure_idle(session_key) do
    case live_session(session_key) do
      nil ->
        :ok

      pid ->
        if CodingAgent.Session.get_state(pid).is_streaming, do: {:error, :busy}, else: :ok
    end
  end

  defp native_session_path(session_key, cwd) do
    case LemonCore.ChatStateStore.get(session_key) do
      state when is_map(state) ->
        engine = Map.get(state, :last_engine) || Map.get(state, "last_engine")
        token = Map.get(state, :last_resume_token) || Map.get(state, "last_resume_token")

        if engine == "lemon" and is_binary(token) and token != "" and
             Path.basename(token) == token do
          {:ok, CodingAgent.Session.Presentation.session_file_path(token, cwd)}
        else
          {:error, :unsupported_session}
        end

      nil ->
        {:error, :session_not_found}

      {:error, _} = error ->
        error
    end
  end

  defp live_session(session_key) do
    if Process.whereis(CodingAgent.SessionRegistry) do
      case Registry.lookup(CodingAgent.SessionRegistry, session_key) do
        [{pid, _}] ->
          pid

        [] ->
          CodingAgent.SessionRegistry
          |> Registry.select([{{:_, :"$1", %{session_key: session_key}}, [], [:"$1"]}])
          |> List.first()
      end
    end
  end

  def background_start(prompt, opts), do: CodingAgent.BackgroundRun.start(prompt, opts)

  def background_list(opts) do
    opts
    |> normalize_background_list_opts()
    |> CodingAgent.BackgroundRun.list()
  end

  def background_list_scoped(session_key, opts) do
    opts
    |> normalize_background_list_opts()
    |> then(&CodingAgent.BackgroundRun.list_scoped(session_key, &1))
  end

  def background_status(id), do: CodingAgent.BackgroundRun.status(id)

  def background_status_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.status_scoped(id, session_key)

  def background_result(id), do: CodingAgent.BackgroundRun.result(id)

  def background_result_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.result_scoped(id, session_key)

  def background_cancel(id), do: CodingAgent.BackgroundRun.cancel(id)

  def background_cancel_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.cancel_scoped(id, session_key)

  def side_query(source, question, opts), do: CodingAgent.SideQuery.ask(source, question, opts)

  def run_graph(run_id), do: CodingAgent.RunGraph.get(run_id)

  def progress_snapshot(session_id, cwd), do: CodingAgent.Progress.snapshot(session_id, cwd)

  def load_extensions(paths), do: CodingAgent.Extensions.load_extensions_with_errors(paths)

  def extension_providers(extensions), do: CodingAgent.Extensions.get_providers(extensions)

  def extension_info(extensions), do: CodingAgent.Extensions.get_info(extensions)

  def tool_conflicts(cwd, opts), do: CodingAgent.ToolRegistry.tool_conflict_report(cwd, opts)

  def extension_dirs(cwd) do
    [CodingAgent.Config.extensions_dir(), CodingAgent.Config.project_extensions_dir(cwd)]
  end

  def wasm_sidecar_running? do
    is_pid(Process.whereis(CodingAgent.Wasm.SidecarSupervisor))
  end

  defp normalize_background_list_opts(opts) do
    case Keyword.get(opts, :status) do
      status
      when status in ~w(queued running completed error lost killed cancelled tracking_lost) ->
        Keyword.put(opts, :status, String.to_existing_atom(status))

      _ ->
        Keyword.delete(opts, :status)
    end
  end
end
