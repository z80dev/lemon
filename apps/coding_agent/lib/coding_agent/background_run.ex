defmodule CodingAgent.BackgroundRun do
  @moduledoc """
  Durable lifecycle API for Hermes-compatible `/bg` work.

  Every accepted prompt runs in a new supervised `CodingAgent.Session` with the
  normal coding toolset. A parent session key is lineage metadata only: no
  transcript is copied and no completion is appended to the parent history.
  Status and terminal results are persisted through `CodingAgent.TaskStore`.
  """

  alias CodingAgent.BackgroundRun.{Registry, Supervisor, Worker}
  alias CodingAgent.{Session, SessionRegistry, TaskStore}

  @kind :background_command
  @default_timeout_ms 30 * 60 * 1_000
  @max_timeout_ms 24 * 60 * 60 * 1_000
  @terminal_statuses [:completed, :error, :lost, :killed, :cancelled]

  @type id :: String.t()

  @doc "Start an isolated full-tool background session and return its durable id immediately."
  @spec start(String.t(), keyword()) :: {:ok, %{id: id(), status: :queued}} | {:error, term()}
  def start(prompt, opts \\ [])

  def start(prompt, opts) when is_binary(prompt) and is_list(opts) do
    prompt = String.trim(prompt)

    if prompt == "" do
      {:error, :empty_prompt}
    else
      do_start(prompt, opts)
    end
  end

  def start(_prompt, _opts), do: {:error, :invalid_prompt}

  @doc "List background-command runs, newest first, optionally filtered by `:status`."
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    status = Keyword.get(opts, :status, :all)

    TaskStore.list(status)
    |> Enum.map(fn {_id, record} -> record end)
    |> Enum.filter(&(Map.get(&1, :kind) == @kind))
    |> Enum.sort_by(&Map.get(&1, :inserted_at, 0), :desc)
    |> Enum.map(&summary/1)
  end

  @doc "Return a sanitized lifecycle summary for one background run."
  @spec status(id()) :: {:ok, map()} | {:error, :not_found}
  def status(id) when is_binary(id) do
    case get_record(id) do
      {:ok, record} -> {:ok, summary(record)}
      error -> error
    end
  end

  @doc "Return the completed visible answer without internal events or reasoning."
  @spec result(id()) ::
          {:ok, String.t()}
          | {:error, :not_found | :not_ready | :cancelled | :lost | {:failed, term()}}
  def result(id) when is_binary(id) do
    case get_record(id) do
      {:ok, %{status: :completed, result: %{answer: answer}}} when is_binary(answer) ->
        {:ok, answer}

      {:ok, %{status: status}} when status in [:queued, :running, :tracking_lost] ->
        {:error, :not_ready}

      {:ok, %{status: :cancelled}} ->
        {:error, :cancelled}

      {:ok, %{status: :lost}} ->
        {:error, :lost}

      {:ok, record} ->
        {:error, {:failed, Map.get(record, :error, :unknown)}}

      {:error, :not_found} = error ->
        error
    end
  end

  @doc "Cooperatively cancel a queued or running background session."
  @spec cancel(id(), term()) :: :ok | {:error, :not_found | :already_terminal}
  def cancel(id, reason \\ :user_cancelled) when is_binary(id) do
    case get_record(id) do
      {:ok, %{status: status}} when status in @terminal_statuses ->
        {:error, :already_terminal}

      {:ok, _record} ->
        case Registry.lookup(id) do
          {:ok, worker} -> Worker.cancel(worker, reason)
          :error -> TaskStore.cancel(id, reason)
        end

        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  defp do_start(prompt, opts) do
    source = resolve_parent(Keyword.get(opts, :parent_session))
    session_id = generate_session_id()
    parent_session_key = normalize_string(Keyword.get(opts, :session_key))

    attrs = %{
      kind: @kind,
      description: "Background command",
      prompt_sha256: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
      session_id: session_id,
      parent_session_id: source[:session_id],
      parent_session_key: parent_session_key
    }

    id = TaskStore.new_task(attrs)
    session_opts = build_session_opts(id, session_id, source, opts)

    worker_opts = [
      id: id,
      prompt: prompt,
      session_id: session_id,
      session_opts: session_opts,
      timeout_ms: timeout_ms(opts),
      runner: Keyword.get(opts, :runner),
      task_supervisor: Keyword.get(opts, :task_supervisor, CodingAgent.TaskSupervisor)
    ]

    worker_opts = Enum.reject(worker_opts, fn {_key, value} -> is_nil(value) end)

    case Supervisor.start_run(worker_opts) do
      {:ok, _pid} ->
        {:ok, %{id: id, status: :queued}}

      {:error, reason} ->
        TaskStore.fail(id, {:start_failed, reason})
        {:error, {:start_failed, reason}}
    end
  end

  defp build_session_opts(id, session_id, source, opts) do
    cwd = Keyword.get(opts, :cwd) || source[:cwd] || LemonCore.Cwd.default_cwd()
    model = Keyword.get(opts, :model) || source[:model]
    thinking_level = Keyword.get(opts, :thinking_level) || source[:thinking_level]
    system_prompt = Keyword.get(opts, :system_prompt) || source[:explicit_system_prompt]

    [
      cwd: cwd,
      model: model,
      thinking_level: thinking_level,
      system_prompt: system_prompt,
      settings_manager: source[:settings_manager],
      workspace_dir: source[:workspace_dir],
      tool_policy: Keyword.get(opts, :tool_policy) || source[:tool_policy],
      stream_fn: Keyword.get(opts, :stream_fn),
      get_api_key: Keyword.get(opts, :get_api_key),
      session_id: session_id,
      session_key: "background:#{id}",
      agent_id: Keyword.get(opts, :agent_id) || source[:agent_id] || "default",
      run_id: id,
      session_scope: :main,
      register: true
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp resolve_parent(pid) when is_pid(pid), do: snapshot_parent(pid)

  defp resolve_parent(session_id) when is_binary(session_id) do
    case SessionRegistry.lookup(session_id) do
      {:ok, pid} -> snapshot_parent(pid)
      :error -> %{}
    end
  end

  defp resolve_parent(_), do: %{}

  defp snapshot_parent(pid) do
    state = Session.get_state(pid)

    %{
      session_id: state.session_manager.header.id,
      cwd: state.cwd,
      model: state.model,
      thinking_level: state.thinking_level,
      explicit_system_prompt: state.explicit_system_prompt,
      settings_manager: state.settings_manager,
      workspace_dir: state.workspace_dir,
      tool_policy: state.tool_policy,
      agent_id: state.agent_id
    }
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp get_record(id) do
    case TaskStore.get(id) do
      {:ok, %{kind: @kind} = record, _events} -> {:ok, record}
      _ -> {:error, :not_found}
    end
  end

  defp summary(record) do
    %{
      id: record.id,
      status: record.status,
      session_id: record.session_id,
      parent_session_key: Map.get(record, :parent_session_key),
      inserted_at: record.inserted_at,
      updated_at: record.updated_at,
      started_at: Map.get(record, :started_at),
      completed_at: Map.get(record, :completed_at),
      result_available: record.status == :completed,
      error: if(record.status in [:error, :lost, :cancelled], do: safe_error(record[:error]))
    }
  end

  defp safe_error(error) when is_atom(error), do: error
  defp safe_error(error) when is_binary(error), do: String.slice(error, 0, 500)
  defp safe_error(nil), do: nil
  defp safe_error(_), do: :internal_error

  defp timeout_ms(opts) do
    case Keyword.get(opts, :timeout_ms, @default_timeout_ms) do
      value when is_integer(value) and value > 0 -> min(value, @max_timeout_ms)
      _ -> @default_timeout_ms
    end
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_), do: nil

  defp generate_session_id do
    "bg_" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end
