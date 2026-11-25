defmodule CodingAgent.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for the native sessions of a
  session key.

  The session's native sessions are the one its chat state resumes and any
  still registered for the key. Deleting the session stops those (idle,
  under the lifecycle fence) processes, deletes their JSONL journals (live
  and maintenance-archived copies) and drops their provider pins and todo
  cache. A journal is staged by an atomic rename next to it and removed only
  after the canonical deletion commits; a failure before that renames it back.

  Reset keeps journals: the reset session starts a new native session and the
  unreferenced journal ages into maintenance archiving.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias CodingAgent.{Config, SessionManager, SessionSupervisor}
  alias CodingAgent.Session.Ownership
  alias CodingAgent.Tools.TodoStore
  alias LemonAgent.ModelRuntime.SessionPins

  @impl true
  def snapshot(session_key, :delete) do
    with {:ok, resumed} <- resumed_native_id(session_key),
         ids = Enum.uniq(List.wrap(resumed) ++ Enum.map(live(session_key), &elem(&1, 0))),
         {:ok, journals} <- journals(ids) do
      {:ok,
       %{
         ids: ids,
         journals: Enum.map(journals, &{&1, staged_path(&1)}),
         pins: for(id <- ids, pin = SessionPins.get(id), into: %{}, do: {id, pin}),
         todos: for(id <- ids, todos = TodoStore.get(id), todos != [], into: %{}, do: {id, todos})
       }}
    end
  end

  @impl true
  def delete(session_key, :delete, snapshot) do
    with :ok <- stop_live(session_key),
         :ok <- each(snapshot.journals, &stage/1) do
      Enum.each(snapshot.ids, fn id ->
        :ok = SessionPins.clear(id)
        :ok = TodoStore.delete(id)
      end)
    end
  end

  @impl true
  def verify_deleted(session_key, :delete, snapshot) do
    with [] <- live(session_key),
         {:ok, []} <- journals(snapshot.ids),
         true <-
           Enum.all?(snapshot.ids, &(is_nil(SessionPins.get(&1)) and TodoStore.get(&1) == [])) do
      :ok
    else
      _remaining_or_unreadable -> {:error, :native_session_remains}
    end
  end

  @impl true
  def restore(_session_key, :delete, snapshot) do
    Enum.each(snapshot.pins, fn {id, pin} ->
      SessionPins.pin(id, pin.provider, pin.credential_ref, pin.model_id)
    end)

    Enum.each(snapshot.todos, fn {id, todos} -> TodoStore.put(id, todos) end)
    each(snapshot.journals, &unstage/1)
  end

  @impl true
  def commit(_session_key, :delete, snapshot) do
    each(snapshot.journals, fn {_path, staged} ->
      case File.rm(staged) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, _} -> {:error, :journal_delete_failed}
      end
    end)
  end

  defp resumed_native_id(session_key) do
    case LemonCore.ChatStateStore.fetch(session_key) do
      {:ok, %{} = state} ->
        engine = Map.get(state, :last_engine) || Map.get(state, "last_engine")
        token = Map.get(state, :last_resume_token) || Map.get(state, "last_resume_token")

        if engine == "lemon" and is_binary(token) and token != "",
          do: {:ok, token},
          else: {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:error, _} ->
        {:error, :store_unavailable}
    end
  end

  # Root sessions and task children registered under the routing key.
  defp live(session_key) do
    if Process.whereis(CodingAgent.SessionRegistry) do
      Registry.select(CodingAgent.SessionRegistry, [
        {{:"$1", :"$2", %{session_key: session_key}}, [], [{{:"$1", :"$2"}}]}
      ])
    else
      []
    end
  end

  # The lifecycle fence proved the session idle; its idle processes would
  # otherwise keep (and rewrite) the journal being deleted.
  defp stop_live(session_key) do
    session_key
    |> live()
    |> each(fn {_id, pid} ->
      case SessionSupervisor.stop_session(pid) do
        :ok -> :ok
        {:error, :not_found} -> :ok
        {:error, _} -> {:error, :native_session_running}
      end
    end)
  end

  # Journals are `<sessions root>/<encoded cwd>/<id>.jsonl`, and maintenance
  # moves cold ones into that directory's `archive/`. Unreadable is an error.
  defp journals([]), do: {:ok, []}

  defp journals(ids) do
    root = Path.expand(Path.join(Config.agent_dir(), "sessions"))

    case File.ls(root) do
      {:ok, directories} ->
        names = Enum.map(ids, &Path.basename(SessionManager.session_file_path(root, &1)))

        for directory <- Enum.sort(directories),
            name <- names,
            path <- [
              Path.join([root, directory, name]),
              Path.join([root, directory, "archive", name])
            ] do
          path
        end
        |> Enum.reduce_while({:ok, []}, fn path, {:ok, found} ->
          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} -> {:cont, {:ok, [path | found]}}
            {:ok, _not_a_journal} -> {:cont, {:ok, found}}
            {:error, reason} when reason in [:enoent, :enotdir] -> {:cont, {:ok, found}}
            {:error, _} -> {:halt, {:error, :journal_unreadable}}
          end
        end)
        |> case do
          {:ok, found} -> {:ok, Enum.reverse(found)}
          error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:error, _} ->
        {:error, :journal_unreadable}
    end
  end

  defp staged_path(path),
    do: path <> ".deleting-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp stage({path, staged}) do
    Ownership.with_file(path, fn ->
      cond do
        is_pid(Ownership.owner(path)) -> {:error, :journal_in_use}
        match?({:error, :enoent}, File.lstat(path)) -> :ok
        true -> rename(path, staged)
      end
    end)
  end

  defp unstage({path, staged}) do
    Ownership.with_file(path, fn ->
      case {File.lstat(staged), File.lstat(path)} do
        {{:ok, _}, {:error, :enoent}} -> rename(staged, path)
        {{:error, :enoent}, _} -> :ok
        _conflict -> {:error, :journal_restore_conflict}
      end
    end)
  end

  defp rename(from, to) do
    case File.rename(from, to) do
      :ok -> :ok
      {:error, _} -> {:error, :journal_rename_failed}
    end
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
        _other -> {:halt, {:error, :unexpected_result}}
      end
    end)
  end
end
