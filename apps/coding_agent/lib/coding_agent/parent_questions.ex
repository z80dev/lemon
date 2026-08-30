defmodule CodingAgent.ParentQuestions do
  @moduledoc """
  Store and lifecycle helpers for subagent clarification requests sent to a
  parent session.

  The child `ask_parent` tool creates requests here and waits for a terminal
  state. The parent-facing `parent_question` tool lists and answers waiting
  requests scoped to the current session.
  """

  alias CodingAgent.ParentQuestionStoreServer
  alias LemonCore.{Bus, Event, Introspection}

  @table :coding_agent_parent_questions
  @dets_table :coding_agent_parent_questions_dets
  @default_ttl_seconds 86_400

  @type request_id :: String.t()
  @type request_record :: map()

  @spec request(map()) :: {:ok, request_record()} | {:error, term()}
  def request(attrs) when is_map(attrs) do
    ensure_table()

    child_scope_id = Map.get(attrs, :child_scope_id) || Map.get(attrs, "child_scope_id")

    cond do
      not is_binary(child_scope_id) or String.trim(child_scope_id) == "" ->
        {:error, :missing_child_scope}

      true ->
        record = new_request(attrs)

        case ParentQuestionStoreServer.create(record) do
          {:ok, created} ->
            emit_lifecycle(:parent_question_requested, created)
            {:ok, created}

          {:error, :already_waiting} = error ->
            error
        end
    end
  end

  @spec answer(request_id(), String.t(), keyword()) :: :ok | {:error, term()}
  def answer(request_id, answer_text, opts \\ [])
      when is_binary(request_id) and is_binary(answer_text) do
    meta = %{
      answered_by_session_key: Keyword.get(opts, :session_key),
      answered_by_agent_id: Keyword.get(opts, :agent_id)
    }

    updates = %{
      answer: answer_text,
      answer_meta: meta,
      answered_at: System.system_time(:second)
    }

    case ParentQuestionStoreServer.transition(
           request_id,
           :answered,
           updates,
           {:parent, Keyword.get(opts, :session_key), Keyword.get(opts, :agent_id)}
         ) do
      {:ok, updated} ->
        emit_lifecycle(:parent_question_answered, updated, %{answer: answer_text})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec timeout(request_id()) :: :ok | {:error, term()}
  def timeout(request_id) when is_binary(request_id) do
    transition_terminal(request_id, :timed_out, %{}, :parent_question_timed_out)
  end

  @spec fail(request_id(), term()) :: :ok | {:error, term()}
  def fail(request_id, reason) when is_binary(request_id) do
    error = normalize_reason(reason)

    transition_terminal(request_id, :error, %{error: error}, :parent_question_error, %{
      error: error
    })
  end

  @spec cancel(request_id(), term()) :: :ok | {:error, term()}
  def cancel(request_id, reason) when is_binary(request_id) do
    error = normalize_reason(reason)

    transition_terminal(
      request_id,
      :cancelled,
      %{error: error},
      :parent_question_cancelled,
      %{reason: error}
    )
  end

  @spec open_request_for_child_scope(String.t()) :: {:ok, request_record()} | {:error, :not_found}
  def open_request_for_child_scope(child_scope_id) when is_binary(child_scope_id) do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.find_value({:error, :not_found}, fn
      {_id, %{child_scope_id: ^child_scope_id, status: :waiting} = record, _events} ->
        {:ok, record}

      _ ->
        false
    end)
  end

  @spec list(keyword()) :: [{request_id(), request_record()}]
  def list(opts \\ []) do
    ensure_table()

    status = Keyword.get(opts, :status, :all)
    parent_session_key = Keyword.get(opts, :parent_session_key)
    parent_agent_id = Keyword.get(opts, :parent_agent_id)

    :ets.foldl(
      fn {request_id, record, _events}, acc ->
        if matches_filters?(record, status, parent_session_key, parent_agent_id) do
          [{request_id, record} | acc]
        else
          acc
        end
      end,
      [],
      @table
    )
    |> Enum.sort_by(fn {_request_id, record} -> Map.get(record, :inserted_at, 0) end)
  end

  @doc "List waiting requests authorized for one exact parent session and agent."
  @spec list_for_parent(String.t() | nil, String.t() | nil) ::
          [{request_id(), request_record()}]
  def list_for_parent(parent_session_key, parent_agent_id) do
    if non_empty_binary?(parent_session_key) and non_empty_binary?(parent_agent_id) do
      list(
        status: :waiting,
        parent_session_key: parent_session_key,
        parent_agent_id: parent_agent_id
      )
    else
      []
    end
  end

  @doc "Return the first open question raised by any of the joined task ids."
  @spec waiting_for_task_ids([String.t()]) :: {:ok, request_record()} | {:error, :not_found}
  def waiting_for_task_ids(task_ids) when is_list(task_ids) do
    task_ids = MapSet.new(task_ids)

    list(status: :waiting)
    |> Enum.find_value({:error, :not_found}, fn {_request_id, record} ->
      if MapSet.member?(task_ids, Map.get(record, :task_id)), do: {:ok, record}, else: false
    end)
  end

  @spec get(request_id()) :: {:ok, request_record(), [term()]} | {:error, :not_found}
  def get(request_id) when is_binary(request_id) do
    ensure_table()

    case :ets.lookup(@table, request_id) do
      [{^request_id, record, events}] -> {:ok, record, Enum.reverse(events)}
      _ -> {:error, :not_found}
    end
  end

  @spec append_event(request_id(), term()) :: :ok
  def append_event(request_id, event) when is_binary(request_id) do
    ParentQuestionStoreServer.append_event(request_id, event)
  end

  @spec clear() :: :ok
  def clear do
    ParentQuestionStoreServer.clear(CodingAgent.ParentQuestionStoreServer)
  end

  @spec cleanup(non_neg_integer()) :: :ok
  def cleanup(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    {:ok, _count} =
      ParentQuestionStoreServer.cleanup(CodingAgent.ParentQuestionStoreServer, ttl_seconds)

    :ok
  end

  @spec request_topic(request_id()) :: String.t()
  def request_topic(request_id) when is_binary(request_id), do: "parent_question:#{request_id}"

  @spec dets_open?() :: boolean()
  def dets_open? do
    :dets.info(@dets_table) != :undefined
  rescue
    _ -> false
  end

  defp new_request(attrs) do
    request_id = generate_id()
    now = System.system_time(:second)

    record =
      Map.merge(
        %{
          id: request_id,
          status: :waiting,
          inserted_at: now,
          updated_at: now,
          description: nil,
          parent_run_id: nil,
          child_run_id: nil,
          child_scope_id: nil,
          task_id: nil,
          parent_session_key: nil,
          parent_agent_id: nil,
          question: nil,
          why_blocked: nil,
          options: [],
          recommended_option: nil,
          can_continue_without_answer: false,
          fallback: nil,
          timeout_ms: nil,
          answer: nil,
          answer_meta: %{},
          answered_at: nil,
          completed_at: nil,
          error: nil,
          meta: %{}
        },
        normalize_attrs(attrs)
      )

    record
  end

  defp normalize_attrs(attrs) do
    attrs
    |> Enum.into(%{}, fn {key, value} ->
      {normalize_attr_key(key), value}
    end)
    |> Map.update(:options, [], fn options -> if is_list(options), do: options, else: [] end)
    |> Map.update(:meta, %{}, fn meta -> if is_map(meta), do: meta, else: %{} end)
  end

  defp normalize_attr_key(key) when is_atom(key), do: key

  defp normalize_attr_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
  end

  defp transition_terminal(request_id, status, updates, event_type, extra \\ %{}) do
    case ParentQuestionStoreServer.transition(request_id, status, updates) do
      {:ok, updated} ->
        emit_lifecycle(event_type, updated, extra)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp emit_lifecycle(event_type, record, extra_payload \\ %{}) do
    payload =
      %{
        request_id: record.id,
        status: record.status,
        parent_run_id: record.parent_run_id,
        child_run_id: record.child_run_id,
        child_scope_id: record.child_scope_id,
        task_id: record.task_id,
        session_key: record.parent_session_key,
        agent_id: record.parent_agent_id,
        description: record.description,
        question: record.question,
        why_blocked: record.why_blocked,
        options: record.options,
        recommended_option: record.recommended_option,
        can_continue_without_answer: record.can_continue_without_answer,
        fallback: record.fallback,
        timeout_ms: record.timeout_ms,
        meta: record.meta
      }
      |> Map.merge(extra_payload)

    event =
      Event.new(event_type, payload, %{
        run_id: record.child_run_id || record.parent_run_id,
        parent_run_id: record.parent_run_id,
        session_key: record.parent_session_key,
        agent_id: record.parent_agent_id,
        request_id: record.id
      })

    append_event(record.id, %{type: event_type, ts_ms: event.ts_ms, payload: payload})
    Bus.broadcast(request_topic(record.id), event)

    if is_binary(record.child_run_id) do
      Bus.broadcast(Bus.run_topic(record.child_run_id), event)
    end

    if is_binary(record.parent_run_id) and record.parent_run_id != record.child_run_id do
      Bus.broadcast(Bus.run_topic(record.parent_run_id), event)
    end

    Introspection.record(
      event_type,
      payload,
      run_id: record.child_run_id || record.parent_run_id,
      parent_run_id: record.parent_run_id,
      session_key: record.parent_session_key,
      agent_id: record.parent_agent_id,
      provenance: :direct
    )

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp matches_filters?(record, status, parent_session_key, parent_agent_id) do
    status_matches?(record, status) and
      session_key_matches?(record, parent_session_key) and
      agent_id_matches?(record, parent_agent_id)
  end

  defp status_matches?(_record, :all), do: true
  defp status_matches?(record, status), do: Map.get(record, :status) == status

  defp session_key_matches?(_record, nil), do: true

  defp session_key_matches?(record, session_key),
    do: Map.get(record, :parent_session_key) == session_key

  defp agent_id_matches?(_record, nil), do: true
  defp agent_id_matches?(record, agent_id), do: Map.get(record, :parent_agent_id) == agent_id

  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason, limit: 80)

  defp non_empty_binary?(value), do: is_binary(value) and String.trim(value) != ""

  defp ensure_table do
    ParentQuestionStoreServer.ensure_table(CodingAgent.ParentQuestionStoreServer)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
