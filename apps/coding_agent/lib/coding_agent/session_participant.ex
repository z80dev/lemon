defmodule CodingAgent.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for the native sessions of a
  session key.

  Deleting a session stops its live native processes and erases its task
  records, provider pins and JSONL journals, including archived journals and
  prior crash-staged copies. A newly staged journal is renamed back if the
  canonical deletion fails; staged bytes are unlinked only after it commits.

  Reset keeps journals: the reset session starts a new native session and the
  unreferenced journal ages into maintenance archiving.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias CodingAgent.{SessionSupervisor, TaskStoreServer}
  alias CodingAgent.Session.JournalErasure
  alias LemonAgent.ModelRuntime.SessionPins
  alias LemonCore.NativeSessionOwner

  @impl true
  def snapshot(session_key, :delete) do
    with {:ok, resumed} <- resumed_native_id(session_key),
         {:ok, bindings} <- NativeSessionOwner.fetch_bindings(),
         {:ok, tasks} <- TaskStoreServer.session_snapshot(session_key),
         owners = Map.new(bindings),
         ids = owned_ids(session_key, resumed, tasks, owners),
         {:ok, %{entries: journals, foreign_ids: foreign_ids}} <-
           JournalErasure.snapshot(session_key, ids, owners) do
      journal_ids = Enum.reduce(journals, ids, &MapSet.put(&2, &1.id))
      ids = MapSet.difference(journal_ids, foreign_ids)

      {:ok,
       %{
         ids: ids,
         journals: journals,
         bindings: bindings,
         tasks: tasks,
         pins: for(id <- ids, pin = SessionPins.get(id), into: %{}, do: {id, pin})
       }}
    end
  end

  @impl true
  def delete(session_key, :delete, snapshot) do
    with :ok <- stop_live(session_key),
         :ok <- JournalErasure.stage(snapshot.journals),
         :ok <- TaskStoreServer.delete_session(session_key, snapshot.tasks) do
      Enum.each(snapshot.ids, &(:ok = SessionPins.clear(&1)))
    end
  end

  @impl true
  def verify_deleted(session_key, :delete, snapshot) do
    with [] <- live(session_key),
         {:ok, []} <- TaskStoreServer.session_snapshot(session_key),
         {:ok, bindings} <- NativeSessionOwner.fetch_bindings(),
         :ok <-
           JournalErasure.verify(session_key, snapshot.ids, Map.new(bindings), snapshot.journals),
         true <- Enum.all?(snapshot.ids, &is_nil(SessionPins.get(&1))) do
      :ok
    else
      _remaining_or_unreadable -> {:error, :native_session_remains}
    end
  end

  @impl true
  def restore(session_key, :delete, snapshot) do
    Enum.each(snapshot.pins, fn {id, pin} ->
      SessionPins.pin(id, pin.provider, pin.credential_ref, pin.model_id)
    end)

    journal_result = JournalErasure.restore(snapshot.journals)
    task_result = TaskStoreServer.restore_session(session_key, snapshot.tasks)

    with :ok <- journal_result, do: task_result
  end

  @impl true
  def commit(session_key, :delete, snapshot) do
    with :ok <- JournalErasure.commit(snapshot.journals),
         do: NativeSessionOwner.delete_bindings(session_key, snapshot.bindings)
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

  defp owned_ids(session_key, resumed, tasks, owners) do
    bound = for {{"lemon", id}, ^session_key} <- owners, do: id

    children =
      for {_task_id, %{session_id: id, parent_session_id: parent}, _events} <- tasks,
          is_binary(id) and is_binary(parent),
          do: id

    for id <- bound ++ List.wrap(resumed) ++ children ++ Enum.map(live(session_key), &elem(&1, 0)),
        Map.get(owners, {"lemon", id}, session_key) == session_key,
        into: MapSet.new(),
        do: id
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
