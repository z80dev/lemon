defmodule CodingAgent.Tools.Task.Seance do
  @moduledoc false

  # Source resolution, scope proof, forking and cleanup for `agent: "seance"`.
  #
  # A source is a native journal directly inside the caller's project sessions
  # directory whose filename derives from its header id. It is in scope only when
  # it belongs to the caller's own conversation, proven one of these ways:
  #
  #   * lineage: the source is the caller's session or one of its header
  #     ancestors (forks and task parents), whose content the caller already owns;
  #   * task descendant: the caller is a header ancestor of the source and the
  #     source was journaled by a `task` child of the same principal;
  #   * session key: the run that last journaled the source's execution authority
  #     is recorded in `RunStore` under the caller's session key, with the same
  #     principal (the binding `AddressingContext` uses for cold journals).
  #
  # Unscoped callers (no session id or key) are refused. A caller fenced by an
  # unreviewed workspace read may only consult its own lineage.

  alias CodingAgent.{SessionManager, WorkspaceReads}
  alias LemonCore.RunStore

  @max_depth 32
  @scope_error "source_session is not a session of the current conversation"

  @spec resolve(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  def resolve(_cwd, nil, _opts), do: {:ok, nil}

  def resolve(cwd, source, opts) do
    source = String.trim(source)
    session_id = present(Keyword.get(opts, :session_id))
    session_key = present(Keyword.get(opts, :session_key))

    with {:ok, path, id} <- journal(cwd, source),
         true <- is_binary(session_id) and is_binary(session_key) do
      if in_scope?(cwd, path, id, session_id, session_key, opts),
        do: {:ok, path},
        else: {:error, @scope_error}
    else
      false ->
        {:error, "source_session requires a scoped caller session"}

      :error ->
        {:error, "source_session #{inspect(source)} is not a session of the current project"}
    end
  end

  @doc """
  Forks the resolved source into a fresh child journal next to it. The fork
  starts a fresh spend ledger: its spend reports to the parent's budget scope,
  so the source's historical spend must not count against the consult.
  """
  @spec fork(map(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def fork(%{source_session_file: source} = validated, opts) when is_binary(source) do
    id = LemonCore.Id.uuid()
    destination = Path.join(Path.dirname(source), id <> ".jsonl")

    fork_opts =
      [id: id, fresh_budget: true]
      |> then(fn fork_opts ->
        case present(Keyword.get(opts, :session_id)) do
          nil -> fork_opts
          parent -> Keyword.put(fork_opts, :parent_session, parent)
        end
      end)

    case SessionManager.fork_file(source, destination, fork_opts) do
      {:ok, session} ->
        {:ok,
         validated
         |> Map.put(:seance_session_file, destination)
         |> Map.put(:seance_fork_entries, SessionManager.entry_count(session))}

      {:error, reason} ->
        {:error, "Cannot fork seance source_session: #{inspect(reason)}"}
    end
  end

  def fork(validated, _opts), do: {:ok, validated}

  @doc "Deletes a seance fork whose child never produced an assistant message."
  @spec discard_unused(map()) :: :ok
  def discard_unused(%{seance_session_file: path, seance_fork_entries: count})
      when is_binary(path) do
    ran? =
      case SessionManager.load_from_file(path) do
        {:ok, session} ->
          session
          |> SessionManager.entries()
          |> Enum.drop(count)
          |> Enum.any?(&assistant_message?/1)

        _ ->
          false
      end

    unless ran?, do: File.rm(path)
    :ok
  end

  def discard_unused(_validated), do: :ok

  defp assistant_message?(%{type: :message, message: message}) when is_map(message),
    do: (message[:role] || message["role"]) in [:assistant, "assistant"]

  defp assistant_message?(_entry), do: false

  defp journal(cwd, source) do
    sessions_dir = Path.expand(SessionManager.get_session_dir(cwd))

    path =
      if String.contains?(source, "/") or String.ends_with?(source, ".jsonl"),
        do: Path.expand(source, cwd),
        else: Path.expand(SessionManager.session_file_path(cwd, source))

    with true <- Path.dirname(path) == sessions_dir,
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, %{"id" => id}} <- read_header(path),
         true <- Path.expand(SessionManager.session_file_path(cwd, id)) == path do
      {:ok, path, id}
    else
      _ -> :error
    end
  end

  defp in_scope?(cwd, path, id, session_id, session_key, opts) do
    if id in ancestors(cwd, session_id) do
      true
    else
      not fenced?(opts) and
        case SessionManager.load_from_file(path) do
          {:ok, session} ->
            case SessionManager.execution_context(session) do
              {:ok, %LemonCore.ExecutionContext{} = execution} ->
                same_principal?(execution, Keyword.get(opts, :execution_context)) and
                  (task_descendant?(cwd, session, execution, session_id) or
                     recorded_key?(execution, session_key))

              _ ->
                false
            end

          _ ->
            false
        end
    end
  end

  defp task_descendant?(cwd, session, execution, session_id) do
    execution.provenance.origin == "task" and
      session_id in ancestors(cwd, session.header.parent_session)
  end

  defp recorded_key?(execution, session_key) do
    case RunStore.fetch(execution.run_id) do
      {:ok, record} when is_map(record) ->
        summary = field(record, :summary) || %{}
        field(summary, :session_key) == session_key

      _ ->
        false
    end
  end

  defp same_principal?(execution, %LemonCore.ExecutionContext{principal: principal}),
    do: execution.principal == principal

  defp same_principal?(_execution, _caller), do: false

  # The id and its header ancestors within this project's sessions directory.
  defp ancestors(cwd, id), do: ancestors(cwd, id, [], @max_depth)

  defp ancestors(_cwd, id, acc, depth) when not is_binary(id) or depth == 0, do: acc

  defp ancestors(cwd, id, acc, depth) do
    if id in acc do
      acc
    else
      parent =
        case read_header(SessionManager.session_file_path(cwd, id)) do
          {:ok, %{"id" => ^id} = header} -> header["parentSession"] || header["parent_session"]
          _ -> nil
        end

      ancestors(cwd, parent, [id | acc], depth - 1)
    end
  end

  # Mirrors the launch-time inheritance in `Params.build_session_opts/3`.
  defp fenced?(opts) do
    WorkspaceReads.fenced?(Map.new(opts)) or
      WorkspaceReads.fenced?(Keyword.get(opts, :session_pid))
  end

  defp read_header(path) do
    with {:ok, file} <- File.open(path, [:read, :utf8]) do
      line = IO.read(file, :line)
      File.close(file)

      case is_binary(line) && Jason.decode(line) do
        {:ok, %{"type" => "session", "id" => id} = header} when is_binary(id) -> {:ok, header}
        _ -> {:error, :invalid_session}
      end
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
